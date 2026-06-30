import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// Measurement probe: compare ink across software (true CoreText), vector@1.0,
/// and slug at weights 0/1/2, for several fg/bg pairs. Tells us empirically which
/// slug weight matches the software renderer and whether the vector base is
/// under-tuned. Not an assertion test; it prints ratios for tuning.
final class SlugWeightSoftwareProbe: XCTestCase {
  private let probe = "Hglo08B/N weight"
  private let cases: [(name: String, fg: UInt32, bg: UInt32)] = [
    ("darkOnLight", 0x18_22_2A_FF, 0xF6_EE_DB_FF),
    ("lightOnDark", 0xFF_FF_FF_FF, 0x00_00_00_FF),
    ("midGray", 0x80_80_80_FF, 0x20_20_20_FF),
  ]

  func testMeasureInkVsSoftware() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let key = VectorTextWeightSettings.defaultsKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    for c in cases {
      let sw = try inkSoftware(fg: c.fg, bg: c.bg)
      let classic = try inkFactory(.classic, fg: c.fg, bg: c.bg)
      let gpu = try inkFactory(.gpuDriven, fg: c.fg, bg: c.bg)
      VectorTextWeightSettings.setCurrent(1.0)
      let vec1 = try inkVector(fg: c.fg, bg: c.bg)
      let slug0 = try inkSlug(fg: c.fg, bg: c.bg, weight: 0)
      let slug1 = try inkSlug(fg: c.fg, bg: c.bg, weight: 1)
      let slug2 = try inkSlug(fg: c.fg, bg: c.bg, weight: 2)
      let slug3 = try inkSlug(fg: c.fg, bg: c.bg, weight: 3)
      let slug4 = try inkSlug(fg: c.fg, bg: c.bg, weight: 4)
      print(
        "PROBE \(c.name): software=\(Int(sw)) "
          + "classic=\(Int(classic))[\(r(classic, sw))] "
          + "gpuDriven=\(Int(gpu))[\(r(gpu, sw))] "
          + "vector@1=\(Int(vec1))[\(r(vec1, sw))] "
          + "slug@0=\(Int(slug0))[\(r(slug0, sw))] "
          + "slug@1=\(Int(slug1))[\(r(slug1, sw))] "
          + "slug@2=\(Int(slug2))[\(r(slug2, sw))] "
          + "slug@3=\(Int(slug3))[\(r(slug3, sw))] "
          + "slug@4=\(Int(slug4))[\(r(slug4, sw))]")
    }
  }

  private func inkFactory(
    _ selection: RendererSelection, fg: UInt32, bg: UInt32
  ) throws -> Double {
    let gpuDriven = selection == .gpuDriven
    let renderer = try XCTUnwrap(
      MetalRenderer(fontAtlas: FontAtlas(pointSize: 16), scale: 2, rendererMode: .classic))
    let previous = MetalRenderer.useGPUCellPath
    MetalRenderer.useGPUCellPath = gpuDriven
    defer { MetalRenderer.useGPUCellPath = previous }
    renderer.captureMode = true
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: 420, pixelHeight: 120, scale: 2)
    XCTAssertTrue(renderer.render(commands(fg: fg, bg: bg), damage: .full))
    renderer.waitForLastFrame()
    return ink(try decodeRGBA(try XCTUnwrap(renderer.pngData)), bg: bg)
  }

  private func r(_ a: Double, _ b: Double) -> String {
    String(format: "%.3f", a / max(b, 1))
  }

  private func inkSoftware(fg: UInt32, bg: UInt32) throws -> Double {
    let b = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: 16), pixelWidth: 420, pixelHeight: 120, scale: 2)
    XCTAssertTrue(b.render(commands(fg: fg, bg: bg), damage: .full))
    return ink(try decodeRGBA(try XCTUnwrap(b.pngData)), bg: bg)
  }

  private func inkSlug(fg: UInt32, bg: UInt32, weight: Double) throws -> Double {
    VectorTextWeightSettings.setCurrent(weight)
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
