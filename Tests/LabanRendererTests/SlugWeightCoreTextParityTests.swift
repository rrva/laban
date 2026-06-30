import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// At text weight 1.0 the Slug renderer must lay down ink that matches CoreText.
/// The vector renderer is the project's CoreText-calibrated reference (its
/// `coverageExponent` doc and `VectorTextWeightTests` lock that calibration), and
/// Slug reuses the same stem-darkening exponent. This proves Slug tracks that
/// reference at weight 1.0 — and that weight 1.0 lands closer to it than the
/// un-darkened weight 0, i.e. the darkening pulls Slug toward CoreText rather
/// than away.
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
    let key = VectorTextWeightSettings.defaultsKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
      if let saved { UserDefaults.standard.set(saved, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }

    for c in cases {
      VectorTextWeightSettings.setCurrent(1.0)
      let reference = try inkVector(fg: c.fg, bg: c.bg)
      let slugWeighted = try inkSlug(fg: c.fg, bg: c.bg)
      VectorTextWeightSettings.setCurrent(0.0)
      let slugNeutral = try inkSlug(fg: c.fg, bg: c.bg)

      // Slug@1.0 ink must be within ~15% of the CoreText-matched reference.
      let ratio = slugWeighted / max(reference, 1)
      XCTAssertGreaterThan(
        ratio, 0.85,
        "\(c.name): slug@1.0 ink \(Int(slugWeighted)) far below CoreText reference "
          + "\(Int(reference)) (ratio \(ratio))")
      XCTAssertLessThan(
        ratio, 1.15,
        "\(c.name): slug@1.0 ink \(Int(slugWeighted)) far above CoreText reference "
          + "\(Int(reference)) (ratio \(ratio))")

      // Weight 1.0 must be at least as close to the reference as un-darkened
      // weight 0 — the stem-darkening pulls Slug toward CoreText, not away.
      let weightedGap = abs(slugWeighted - reference)
      let neutralGap = abs(slugNeutral - reference)
      XCTAssertLessThanOrEqual(
        weightedGap, neutralGap + 1,
        "\(c.name): weight 1.0 (gap \(Int(weightedGap))) should track CoreText at "
          + "least as well as weight 0 (gap \(Int(neutralGap)))")
    }
  }

  private func inkSlug(fg: UInt32, bg: UInt32) throws -> Double {
    let r = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 16), pixelWidth: 420, pixelHeight: 120, scale: 2))
    r.waitForFrameCompletion = true
    r.presentsToLayer = false
    r.setSubpixelLayout(.grayscale)
    r.refreshTextWeight()
    XCTAssertTrue(r.render(commands(fg: fg, bg: bg), damage: .full))
    return ink(try decodeRGBA(try XCTUnwrap(r.pngData)), bg: bg)
  }

  private func inkVector(fg: UInt32, bg: UInt32) throws -> Double {
    let r = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 16), pixelWidth: 420, pixelHeight: 120, scale: 2))
    r.waitForFrameCompletion = true
    r.setSubpixelLayout(.grayscale)
    r.refreshTextWeight()
    XCTAssertTrue(r.render(commands(fg: fg, bg: bg), damage: .full))
    return ink(try decodeRGBA(try XCTUnwrap(r.pngData)), bg: bg)
  }

  private func commands(fg: UInt32, bg: UInt32) -> [FrameCommand] {
    [
      .rect(CGRect(x: 0, y: 0, width: 210, height: 60), color: bg, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 8, y: 16), text: probe, foreground: fg, background: bg,
        attributes: [], source: .terminal),
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
