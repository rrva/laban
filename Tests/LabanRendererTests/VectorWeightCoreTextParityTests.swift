import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

final class VectorWeightCoreTextParityTests: XCTestCase {
  private let probe = "Hglo08B/N weight"
  private let cases: [(name: String, fg: UInt32, bg: UInt32)] = [
    ("darkOnLight", 0x18_22_2A_FF, 0xF6_EE_DB_FF),
    ("lightOnDark", 0xFF_FF_FF_FF, 0x00_00_00_FF),
    ("midGray", 0x80_80_80_FF, 0x20_20_20_FF),
  ]

  func testVectorWeightOneMatchesCoreTextReference() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    try withSavedTextWeight {
      for c in cases {
        let reference = try inkSoftware(fg: c.fg, bg: c.bg)
        let vector = try inkVectorAtWeights(fg: c.fg, bg: c.bg)

        let ratio = vector.weighted / max(reference, 1)
        XCTAssertGreaterThan(
          ratio,
          0.88,
          "\(c.name): vector@1.0 ink \(Int(vector.weighted)) far below software reference "
            + "\(Int(reference)) (ratio \(ratio))")
        XCTAssertLessThan(
          ratio,
          1.12,
          "\(c.name): vector@1.0 ink \(Int(vector.weighted)) far above software reference "
            + "\(Int(reference)) (ratio \(ratio))")

        if c.name == "darkOnLight" {
          let weightedGap = abs(vector.weighted - reference)
          let neutralGap = abs(vector.neutral - reference)
          XCTAssertLessThanOrEqual(
            weightedGap,
            neutralGap + 1,
            "dark-on-light weight 1.0 should track CoreText at least as well as weight 0 "
              + "(weighted gap \(Int(weightedGap)), neutral gap \(Int(neutralGap)))")
        }
      }
    }
  }

  func testVectorTextWeightThickensRenderedInk() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    try withSavedTextWeight {
      let lightBg: UInt32 = 0xF6_EE_DB_FF
      let darkFg: UInt32 = 0x18_22_2A_FF
      let vector = try inkVectorAtWeights(fg: darkFg, bg: lightBg)
      XCTAssertGreaterThan(
        vector.weighted,
        vector.neutral * 1.05,
        "text weight 1 must lay down more ink than weight 0 "
          + "(neutral \(vector.neutral), weighted \(vector.weighted))")
    }
  }

  private func inkVectorAtWeights(fg: UInt32, bg: UInt32) throws
    -> (neutral: Double, weighted: Double)
  {
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 16),
        pixelWidth: 720,
        pixelHeight: 180,
        scale: 2))
    renderer.waitForFrameCompletion = true
    renderer.setSubpixelLayout(.grayscale)
    let commands = commands(fg: fg, bg: bg)

    Self.registerTextWeight(0)
    renderer.refreshTextWeight()
    for _ in 0..<3 {
      XCTAssertTrue(renderer.render(commands, damage: .full))
    }
    let neutral = ink(try decodeRGBA(try XCTUnwrap(renderer.pngData)), bg: bg)

    Self.registerTextWeight(1)
    renderer.refreshTextWeight()
    for _ in 0..<3 {
      XCTAssertTrue(renderer.render(commands, damage: .full))
    }
    let weighted = ink(try decodeRGBA(try XCTUnwrap(renderer.pngData)), bg: bg)
    return (neutral, weighted)
  }

  private func inkSoftware(fg: UInt32, bg: UInt32) throws -> Double {
    let renderer = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: 16),
      pixelWidth: 720,
      pixelHeight: 180,
      scale: 2)
    XCTAssertTrue(renderer.render(commands(fg: fg, bg: bg), damage: .full))
    return ink(try decodeRGBA(try XCTUnwrap(renderer.pngData)), bg: bg)
  }

  private func commands(fg: UInt32, bg: UInt32) -> [FrameCommand] {
    [
      .rect(CGRect(x: 0, y: 0, width: 360, height: 90), color: bg, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 12, y: 32),
        text: probe,
        foreground: fg,
        background: bg,
        attributes: [],
        source: .terminal),
    ]
  }

  /// Restores the production default afterwards by *registering* it rather
  /// than writing it. The renderer reads the weight from
  /// `UserDefaults.standard` itself, so it cannot be handed a private suite,
  /// but the registration domain is per-process and never reaches disk. A
  /// persisted write here is what used to leave `LabanVectorTextWeight` stuck
  /// non-default and contaminate unrelated renderer fidelity tests. See
  /// `execplans/active/test-userdefaults-isolation.md`.
  private func withSavedTextWeight(_ body: () throws -> Void) rethrows {
    defer {
      UserDefaults.standard.register(
        defaults: [VectorTextWeightSettings.defaultsKey: VectorTextWeightSettings.defaultWeight])
    }
    try body()
  }

  /// Pins the weight process-locally, the registration-domain counterpart of
  /// `VectorTextWeightSettings.setCurrent`.
  fileprivate static func registerTextWeight(_ weight: Double) {
    UserDefaults.standard.register(defaults: [VectorTextWeightSettings.defaultsKey: weight])
  }

  /// Total absolute luminance deviation from the background equals ink laid down.
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
      let offset = (y * width + x) * 4
      return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { throw XCTSkip("failed to decode renderer PNG") }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let ctx = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: info)
      else { return }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RGBAImage(width: width, height: height, bytes: bytes)
  }
}
