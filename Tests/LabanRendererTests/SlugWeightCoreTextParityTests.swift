import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// At text weight 1.0 the Slug renderer must lay down ink that matches CoreText.
/// The software renderer (`SoftwareBackend`) renders via CoreText directly and is
/// the project's ground-truth reference. Slug reaches weight 1.0 by geometric
/// dilation of its analytic glyph coverage (stem darkening), calibrated against
/// this software reference; see
/// execplans/active/slug-text-weight-geometric-dilation.md. This proves Slug
/// tracks that reference at weight 1.0, and that weight 1.0 lands closer to it
/// than the un-dilated weight 0, i.e. the dilation pulls Slug toward CoreText
/// rather than away.
final class SlugWeightCoreTextParityTests: XCTestCase {
  private let probe = "Hglo08B/N weight"
  private let cases: [(name: String, fg: UInt32, bg: UInt32)] = [
    ("darkOnLight", 0x18_22_2A_FF, 0xF6_EE_DB_FF),
    ("lightOnDark", 0xFF_FF_FF_FF, 0x00_00_00_FF),
    ("midGray", 0x80_80_80_FF, 0x20_20_20_FF),
  ]

  func testSlugWeightOneMatchesCoreTextReference() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    // Registered, not written: the slug renderer reads this weight from
    // `UserDefaults.standard` itself, so it cannot take a private suite, but
    // the registration domain is per-process and never reaches disk. Persisting
    // it is what left `LabanVectorTextWeight` stuck non-default and
    // contaminated unrelated fidelity tests. See
    // `execplans/active/test-userdefaults-isolation.md`.
    let key = VectorTextWeightSettings.defaultsKey
    func pinWeight(_ weight: Double) {
      UserDefaults.standard.register(defaults: [key: weight])
    }
    defer { pinWeight(VectorTextWeightSettings.defaultWeight) }

    for c in cases {
      let reference = try inkSoftware(fg: c.fg, bg: c.bg)
      pinWeight(1.0)
      let slugWeighted = try inkSlug(fg: c.fg, bg: c.bg)
      pinWeight(0.0)
      let slugNeutral = try inkSlug(fg: c.fg, bg: c.bg)

      // Slug@1.0 ink must be within ~12% of the software (CoreText) reference.
      let ratio = slugWeighted / max(reference, 1)
      XCTAssertGreaterThan(
        ratio, 0.88,
        "\(c.name): slug@1.0 ink \(Int(slugWeighted)) far below software reference "
          + "\(Int(reference)) (ratio \(ratio))")
      XCTAssertLessThan(
        ratio, 1.12,
        "\(c.name): slug@1.0 ink \(Int(slugWeighted)) far above software reference "
          + "\(Int(reference)) (ratio \(ratio))")

      // Weight 1.0 must be at least as close to the reference as un-dilated
      // weight 0 (the dilation pulls Slug toward CoreText, not away).
      let weightedGap = abs(slugWeighted - reference)
      let neutralGap = abs(slugNeutral - reference)
      XCTAssertLessThanOrEqual(
        weightedGap, neutralGap + 1,
        "\(c.name): weight 1.0 (gap \(Int(weightedGap))) should track CoreText at "
          + "least as well as weight 0 (gap \(Int(neutralGap)))")
    }
  }

  /// Text weight must not depend on polarity or display density. Slug blends
  /// its coverage in gamma space on Apple GPUs (ADR 0038), which is what lets
  /// dark-on-light and light-on-dark text land on CoreText's ink at the same
  /// time; under the old linear-light blend dark text sat 15-25% light and
  /// light text up to 44% heavy at 1x. Every size/scale/polarity cell measured
  /// 0.88-1.10 when the blend landed; the band below leaves room for font and
  /// OS drift while still failing the linear-light behavior.
  func testSlugInkTracksCoreTextAcrossSizesScalesAndPolarities() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    guard device.supportsFamily(.apple1) else {
      throw XCTSkip("gamma text blend needs framebuffer fetch (Apple GPU)")
    }
    let key = VectorTextWeightSettings.defaultsKey
    UserDefaults.standard.register(defaults: [key: VectorTextWeightSettings.defaultWeight])
    let sweepCases = cases + [("blackOnWhite", 0x00_00_00_FF, 0xFF_FF_FF_FF)]
    for scale in [CGFloat(1), CGFloat(2)] {
      for pointSize in [CGFloat(9), 13, 20] {
        for c in sweepCases {
          let reference = try inkSoftware(fg: c.fg, bg: c.bg, pointSize: pointSize, scale: scale)
          let slug = try inkSlug(fg: c.fg, bg: c.bg, pointSize: pointSize, scale: scale)
          let ratio = slug / max(reference, 1)
          XCTAssertTrue(
            (0.85...1.15).contains(ratio),
            "\(c.name) \(Int(pointSize))pt@\(Int(scale))x: slug ink \(Int(slug)) vs "
              + "CoreText \(Int(reference)) (ratio \(ratio))")
        }
      }
    }
  }

  private func inkSlug(
    fg: UInt32, bg: UInt32, pointSize: CGFloat = 16, scale: CGFloat = 2
  ) throws -> Double {
    let size = surfaceSize(pointSize: pointSize, scale: scale)
    let r = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize), pixelWidth: size.width,
        pixelHeight: size.height, scale: scale))
    r.waitForFrameCompletion = true
    r.presentsToLayer = false
    r.setSubpixelLayout(.grayscale)
    r.refreshTextWeight()
    XCTAssertTrue(
      r.render(commands(fg: fg, bg: bg, pointSize: pointSize, scale: scale), damage: .full))
    return ink(try decodeRGBA(try XCTUnwrap(r.pngData)), bg: bg)
  }

  private func inkSoftware(
    fg: UInt32, bg: UInt32, pointSize: CGFloat = 16, scale: CGFloat = 2
  ) throws -> Double {
    let size = surfaceSize(pointSize: pointSize, scale: scale)
    let b = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: pointSize), pixelWidth: size.width,
      pixelHeight: size.height, scale: scale)
    XCTAssertTrue(
      b.render(commands(fg: fg, bg: bg, pointSize: pointSize, scale: scale), damage: .full))
    return ink(try decodeRGBA(try XCTUnwrap(b.pngData)), bg: bg)
  }

  /// 420x120 px at the original 16pt@2x probe; other sizes scale with it.
  private func surfaceSize(pointSize: CGFloat, scale: CGFloat) -> (width: Int, height: Int) {
    let factor = pointSize / 16 * scale / 2
    return (Int((420 * factor).rounded()), Int((120 * factor).rounded()))
  }

  private func commands(
    fg: UInt32, bg: UInt32, pointSize: CGFloat = 16, scale: CGFloat = 2
  ) -> [FrameCommand] {
    let size = surfaceSize(pointSize: pointSize, scale: scale)
    return [
      .rect(
        CGRect(
          x: 0, y: 0, width: CGFloat(size.width) / scale, height: CGFloat(size.height) / scale),
        color: bg, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 8 * pointSize / 16, y: pointSize), text: probe, foreground: fg,
        background: bg, attributes: [], source: .terminal),
    ]
  }

  /// Total absolute luminance deviation from the background = ink laid down.
  private func ink(_ image: RGBAImage, bg: UInt32) -> Double {
    let bgLuma =
      (Int((bg >> 24) & 0xFF) + Int((bg >> 16) & 0xFF) + Int((bg >> 8) & 0xFF)) / 3
    var total = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let p = image.pixel(x: x, y: y)
        let luma = (Int(p.r) + Int(p.g) + Int(p.b)) / 3
        total += abs(luma - bgLuma)
      }
    }
    return Double(total)
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]
    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
      let o = (y * width + x) * 4
      return (bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3])
    }
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { throw XCTSkip("failed to decode renderer PNG") }
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
      else { return }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return RGBAImage(width: w, height: h, bytes: bytes)
  }
}

/// ADR 0038's small-size dilation entries are calibrated for gamma-blended
/// text only; linear-light paths (Intel, translucent) keep the old clamp.
final class SlugDilationBlendScopeTests: XCTestCase {
  func testSmallSizeEntriesApplyOnlyToGammaBlendedText() {
    let linear9 = SlugGlyphRenderer.perSideDilatePx(weight: 1, ppemPx: 9, gammaBlend: false)
    let linear18 = SlugGlyphRenderer.perSideDilatePx(weight: 1, ppemPx: 18, gammaBlend: false)
    let gamma9 = SlugGlyphRenderer.perSideDilatePx(weight: 1, ppemPx: 9, gammaBlend: true)
    let gamma18 = SlugGlyphRenderer.perSideDilatePx(weight: 1, ppemPx: 18, gammaBlend: true)
    XCTAssertEqual(linear9, linear18, accuracy: 1e-6)
    XCTAssertEqual(gamma18, linear18, accuracy: 1e-6)
    XCTAssertLessThan(gamma9, linear9)
  }
}
