import CoreGraphics
import LabanRenderer
import XCTest

final class RendererSelectionRoutingTests: XCTestCase {
  func testAnalyticRenderersAreSelectionsNotMetalModes() {
    XCTAssertNil(RendererSelection.software.metalMode)
    XCTAssertNil(RendererSelection.vectorGlyph.metalMode)
    XCTAssertNil(RendererSelection.slugGlyph.metalMode)
    XCTAssertEqual(RendererSelection.classic.metalMode, .classic)
    XCTAssertEqual(RendererSelection.gpuDriven.metalMode, .gpuDriven)
  }

  func testSlugGlyphSelectionRoundTrips() {
    XCTAssertEqual(RendererSelection(rawValue: "slugGlyph"), .slugGlyph)
    XCTAssertTrue(RendererSelection.slugGlyph.isAvailableOnCurrentOS)
    XCTAssertTrue(RendererSelection.allCases.contains(.slugGlyph))
  }

  func testVectorGlyphFactoryReportsRequestedRenderer() {
    let atlas = FontAtlas(pointSize: 14)
    let backend = makeRendererBackend(
      selection: .vectorGlyph,
      fontAtlas: atlas,
      sidebarFontAtlas: atlas,
      pixelWidth: 120,
      pixelHeight: 80,
      scale: 1)

    XCTAssertEqual(backend.rendererStatus.configuredRenderer, "vectorGlyph")
    XCTAssertTrue(
      ["vectorGlyph", "classic", "software"].contains(backend.rendererStatus.effectiveRenderer))
    if backend.rendererStatus.effectiveRenderer == "software" {
      XCTAssertNotNil(backend.rendererStatus.fallbackReason)
    }
  }

  func testVectorGlyphBackendRendersPlainASCIIWhenAvailable() throws {
    let atlas = FontAtlas(pointSize: 14)
    let backend = makeRendererBackend(
      selection: .vectorGlyph,
      fontAtlas: atlas,
      sidebarFontAtlas: atlas,
      pixelWidth: 320,
      pixelHeight: 120,
      scale: 1)
    guard backend.rendererStatus.effectiveRenderer == "vectorGlyph" else {
      throw XCTSkip("vector glyph renderer unavailable: \(backend.rendererStatus)")
    }

    let rendered = backend.render(
      [
        .rect(
          CGRect(x: 0, y: 0, width: 320, height: 120),
          color: 0x1010_10ff,
          source: .terminal),
        .glyphRun(
          origin: CGPoint(x: 10, y: 20),
          text: "ABC123",
          foreground: 0xffff_ffff,
          background: 0x0000_0000,
          attributes: [],
          source: .terminal),
      ],
      damage: .full)

    XCTAssertTrue(rendered)
    XCTAssertGreaterThan(backend.pngData?.count ?? 0, 0)
  }

  func testSlugGlyphFactoryReportsRequestedRenderer() {
    let atlas = FontAtlas(pointSize: 14)
    let backend = makeRendererBackend(
      selection: .slugGlyph,
      fontAtlas: atlas,
      sidebarFontAtlas: atlas,
      pixelWidth: 120,
      pixelHeight: 80,
      scale: 1)

    XCTAssertEqual(backend.rendererStatus.configuredRenderer, "slugGlyph")
    XCTAssertTrue(
      ["slugGlyph", "classic", "software"].contains(backend.rendererStatus.effectiveRenderer))
    if backend.rendererStatus.effectiveRenderer == "software" {
      XCTAssertNotNil(backend.rendererStatus.fallbackReason)
    }
  }

  func testSlugGlyphBackendRendersPlainASCIIWhenAvailable() throws {
    let atlas = FontAtlas(pointSize: 14)
    let backend = makeRendererBackend(
      selection: .slugGlyph,
      fontAtlas: atlas,
      sidebarFontAtlas: atlas,
      pixelWidth: 320,
      pixelHeight: 120,
      scale: 1)
    guard backend.rendererStatus.effectiveRenderer == "slugGlyph" else {
      throw XCTSkip("slug glyph renderer unavailable: \(backend.rendererStatus)")
    }

    let rendered = backend.render(
      [
        .rect(
          CGRect(x: 0, y: 0, width: 320, height: 120),
          color: 0x1010_10ff,
          source: .terminal),
        .glyphRun(
          origin: CGPoint(x: 10, y: 20),
          text: "ABC123",
          foreground: 0xffff_ffff,
          background: 0x0000_0000,
          attributes: [],
          source: .terminal),
      ],
      damage: .full)

    XCTAssertTrue(rendered)
    XCTAssertGreaterThan(backend.pngData?.count ?? 0, 0)
  }

  func testVectorGlyphReportsRasterFallbackGlyphsForMixedUnicodeWhenAvailable() throws {
    let atlas = FontAtlas(pointSize: 14)
    let backend = makeRendererBackend(
      selection: .vectorGlyph,
      fontAtlas: atlas,
      sidebarFontAtlas: atlas,
      pixelWidth: 420,
      pixelHeight: 140,
      scale: 1)
    guard let renderer = backend as? VectorGlyphRenderer else {
      throw XCTSkip("vector glyph renderer unavailable: \(backend.rendererStatus)")
    }

    let rendered = renderer.render(
      [
        .rect(
          CGRect(x: 0, y: 0, width: 420, height: 140),
          color: 0x1010_10ff,
          source: .terminal),
        .glyphRun(
          origin: CGPoint(x: 10, y: 30),
          text: "ASCII 漢字 🙂 👩‍💻 ┌─┐",
          foreground: 0xffff_ffff,
          background: 0x0000_0000,
          attributes: [],
          source: .terminal),
      ],
      damage: .full)

    XCTAssertTrue(rendered)
    XCTAssertGreaterThan(renderer.rendererStatus.rasterFallbackGlyphs ?? 0, 0)
    XCTAssertEqual(renderer.rendererStatus.vectorSubpixelLayout, "grayscale")
    XCTAssertGreaterThan(renderer.pngData?.count ?? 0, 0)
  }
}
