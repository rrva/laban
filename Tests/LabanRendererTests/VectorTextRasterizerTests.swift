import CoreGraphics
import CoreText
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

final class VectorTextRasterizerTests: XCTestCase {
  private func makeRasterizer() throws -> VectorTextRasterizer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    return try XCTUnwrap(VectorTextRasterizer(device: device))
  }

  private var pillFont: CTFont {
    CTFontCreateWithName("Menlo" as CFString, 11, nil)
  }

  private func black() -> CGColor {
    CGColor(
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      components: [0, 0, 0, 1])!
  }

  func testProducesImageSizedToTextAndScale() throws {
    let rasterizer = try makeRasterizer()
    let image = try XCTUnwrap(
      rasterizer.image(for: "12/340", font: pillFont, color: black(), scale: 2),
      "a pill-shaped string must rasterize through the vector pipeline")
    XCTAssertGreaterThan(image.width, 0)
    XCTAssertGreaterThan(image.height, 0)
    // A 2x device scale must yield more device pixels than a 1x render of the
    // same string, confirming `scale` drives the raster resolution.
    let oneX = try XCTUnwrap(
      rasterizer.image(for: "12/340", font: pillFont, color: black(), scale: 1))
    XCTAssertGreaterThan(image.width, oneX.width)
    XCTAssertGreaterThan(image.height, oneX.height)
  }

  func testEmptyAndWhitespaceYieldNoImage() throws {
    let rasterizer = try makeRasterizer()
    XCTAssertNil(
      rasterizer.image(for: "", font: pillFont, color: black(), scale: 2),
      "an empty string has nothing to rasterize")
    XCTAssertNil(
      rasterizer.image(for: "   ", font: pillFont, color: black(), scale: 2),
      "whitespace has no fillable outline, so the caller can fall back")
  }

  func testImageHasInkForDrawnGlyphs() throws {
    let rasterizer = try makeRasterizer()
    let image = try XCTUnwrap(
      rasterizer.image(for: "8", font: pillFont, color: black(), scale: 2))
    XCTAssertTrue(hasOpaquePixel(image), "a rendered digit must leave visible ink")
  }

  func testRepeatedStringReusesCachedImage() throws {
    let rasterizer = try makeRasterizer()
    _ = rasterizer.image(for: "12/340", font: pillFont, color: black(), scale: 2)
    let afterFirst = rasterizer.rasterizePassCount
    XCTAssertEqual(afterFirst, 1, "the first render runs exactly one rasterization pass")
    _ = rasterizer.image(for: "12/340", font: pillFont, color: black(), scale: 2)
    XCTAssertEqual(
      rasterizer.rasterizePassCount, afterFirst,
      "re-rendering the same string must reuse the cached image, no new pass")
    // A different string is a genuine miss: exactly one more pass.
    _ = rasterizer.image(for: "13/340", font: pillFont, color: black(), scale: 2)
    XCTAssertEqual(rasterizer.rasterizePassCount, afterFirst + 1)
  }

  /// Regression: baking each glyph into its own tight box and compositing with
  /// per-glyph rounding made round digits (8, 0) anchor a pixel higher than
  /// flat-top ones, so the baseline visibly wobbled. A single-pass render over
  /// one combined outline shares one baseline grid: the bottom-most ink row of a
  /// string of mixed digits must be within one device pixel across the run.
  func testDigitsShareACommonBaseline() throws {
    let rasterizer = try makeRasterizer()
    let image = try XCTUnwrap(
      rasterizer.image(for: "1807", font: pillFont, color: black(), scale: 2))
    let bottoms = perColumnBlockBottomRows(image)
    // Sample the bottom of each digit's ink. Flat-bottom (1, 7) and round-bottom
    // (8, 0) digits sit on the same baseline, so the lowest inked row must barely
    // vary; the old per-glyph path produced multi-pixel steps here.
    let low = try XCTUnwrap(bottoms.min())
    let high = try XCTUnwrap(bottoms.max())
    XCTAssertLessThanOrEqual(
      high - low, 2,
      "digit baselines must align within a device pixel or two, not wobble")
  }

  func testTintColorChannelsAppearInOutput() throws {
    let rasterizer = try makeRasterizer()
    let red = CGColor(
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!
    let image = try XCTUnwrap(
      rasterizer.image(for: "8", font: pillFont, color: red, scale: 2))
    let sample = dominantInkColor(image)
    XCTAssertGreaterThan(sample.r, sample.g, "red tint must dominate the green channel")
    XCTAssertGreaterThan(sample.r, sample.b, "red tint must dominate the blue channel")
  }

  // MARK: - Pixel helpers

  private func rgbaBytes(_ image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return bytes
  }

  /// For a string of N evenly-spaced glyphs, split the image into N vertical
  /// bands and return the lowest inked row (largest y, top-down) in each band —
  /// i.e. each digit's visual bottom. Bands with no ink are skipped.
  private func perColumnBlockBottomRows(_ image: CGImage, bands: Int = 4) -> [Int] {
    guard let bytes = rgbaBytes(image) else { return [] }
    let width = image.width
    let height = image.height
    let bandWidth = max(1, width / bands)
    var bottoms: [Int] = []
    for band in 0..<bands {
      let xStart = band * bandWidth
      let xEnd = min(width, xStart + bandWidth)
      var bottom = -1
      for y in 0..<height {
        for x in xStart..<xEnd where bytes[(y * width + x) * 4 + 3] > 64 {
          bottom = y
          break
        }
      }
      if bottom >= 0 { bottoms.append(bottom) }
    }
    return bottoms
  }

  private func hasOpaquePixel(_ image: CGImage) -> Bool {
    guard let bytes = rgbaBytes(image) else { return false }
    for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] > 16 {
      return true
    }
    return false
  }

  private func dominantInkColor(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
    guard let bytes = rgbaBytes(image) else { return (0, 0, 0) }
    var best = (r: 0, g: 0, b: 0, a: 0)
    for index in stride(from: 0, to: bytes.count, by: 4) {
      let a = Int(bytes[index + 3])
      if a > best.a {
        best = (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), a)
      }
    }
    return (best.r, best.g, best.b)
  }
}
