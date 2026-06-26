import CoreGraphics
import CoreText
import Metal
import XCTest

@testable import LabanRenderer

final class VectorGlyphScratchRasterizerTests: XCTestCase {
  func testShaderResourceCompiles() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    guard
      let url = LabanRendererResources.bundle?.url(
        forResource: "VectorGlyphShaders",
        withExtension: "metal")
    else {
      return XCTFail("VectorGlyphShaders.metal must be bundled")
    }
    let source = try String(contentsOf: url, encoding: .utf8)
    let options = MTLCompileOptions()
    if #available(macOS 15.0, *) {
      options.mathMode = .safe
    } else {
      options.fastMathEnabled = false
    }
    let library = try device.makeLibrary(source: source, options: options)
    XCTAssertNotNil(library.makeFunction(name: "vectorGlyphRasterizeScratch"))
  }

  func testScratchRasterizerMatchesCPUOracleForPrintableASCII() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    let rasterizer = try XCTUnwrap(VectorGlyphScratchRasterizer(device: device))
    let store = GlyphCurveStore()
    let font = FontAtlas(pointSize: 24, fontName: nil).font

    var checked = 0
    for value in 0x20...0x7E {
      guard let scalar = Unicode.Scalar(value) else { continue }
      guard let glyph = glyph(for: scalar, font: font) else { continue }
      guard let outline = store.outline(for: glyph, font: font) else { continue }
      let region = rasterRegion(for: glyph, font: font)
      let gpu = try XCTUnwrap(
        rasterizer.rasterize(
          outline: outline,
          width: region.width,
          height: region.height,
          origin: region.origin),
        "GPU rasterize failed for U+\(String(format: "%04X", value))")
      let cpu = cpuSingleSampleMask(
        outline: outline,
        width: region.width,
        height: region.height,
        origin: region.origin)

      XCTAssertEqual(gpu.count, cpu.count)
      var mismatchedPixels = 0
      var maxDelta = 0
      for index in cpu.indices {
        let delta = abs(Int(gpu[index]) - Int(cpu[index]))
        if delta > 3 {
          mismatchedPixels += 1
          maxDelta = max(maxDelta, delta)
        }
      }
      let allowedMismatches = max(1, Int((Double(cpu.count) * 0.01).rounded(.up)))
      XCTAssertLessThanOrEqual(
        mismatchedPixels,
        allowedMismatches,
        "U+\(String(format: "%04X", value)) edge mismatches, max delta \(maxDelta)")
      checked += 1
    }
    XCTAssertGreaterThan(checked, 80, "printable ASCII should exercise most outline glyphs")
  }

  private func glyph(for scalar: Unicode.Scalar, font: CTFont) -> CGGlyph? {
    guard scalar.value <= UInt32(UInt16.max) else { return nil }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else {
      return nil
    }
    return glyph
  }

  private func rasterRegion(
    for glyph: CGGlyph,
    font: CTFont
  ) -> (origin: CGPoint, width: Int, height: Int) {
    var glyphCopy = glyph
    let glyphBounds = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphCopy, nil, 1)
      .standardized
    var advance = CGSize.zero
    _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, &advance, 1)
    let pad: CGFloat = 4
    let fallback = CGRect(
      x: 0,
      y: -CTFontGetDescent(font),
      width: max(advance.width, 1),
      height: CTFontGetAscent(font) + CTFontGetDescent(font))
    let bounds: CGRect
    if !glyphBounds.isNull && glyphBounds.width > 0 && glyphBounds.height > 0 {
      bounds = glyphBounds
    } else {
      bounds = fallback
    }
    let minX = floor(min(bounds.minX, 0) - pad)
    let maxX = ceil(max(bounds.maxX, advance.width) + pad)
    let minY = floor(min(bounds.minY, fallback.minY) - pad)
    let maxY = ceil(max(bounds.maxY, fallback.maxY) + pad)
    return (
      CGPoint(x: minX, y: minY),
      max(1, Int(maxX - minX)),
      max(1, Int(maxY - minY))
    )
  }

  private func cpuSingleSampleMask(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint
  ) -> [UInt8] {
    GlyphCurveCPUOracle.rasterizeCoverage(
      outline: outline,
      width: width,
      height: height,
      samplesPerAxis: 1
    ) { x, row, fx, fy in
      CGPoint(
        x: Double(origin.x) + Double(x) + fx,
        y: Double(origin.y) + Double(height - 1 - row) + fy)
    }.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
  }
}
