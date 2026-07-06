import Metal
import XCTest

@testable import LabanRenderer

/// `SlugGlyphRenderer.init` mirrors `VectorGlyphRenderer`'s prebuilt-atlas
/// adoption: accept an optional prebuilt raster atlas from a background
/// cold-launch prewarm and adopt it when compatible, holding it aside for
/// `resize` when the scale does not match `init`'s. These tests mirror
/// `VectorGlyphRendererPrebuiltAtlasTests` for the slug renderer, which has a
/// single raster atlas (no sidebar atlas). See
/// execplans/active/vector-glyph-cold-launch-stall.md.
final class SlugGlyphRendererPrebuiltAtlasTests: XCTestCase {
  private func requireDevice() throws -> MTLDevice {
    try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device available")
  }

  private func makePrewarmedAtlas(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    scale: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> MetalGlyphAtlas {
    try XCTUnwrap(
      MetalGlyphAtlas(
        device: device,
        cellWidth: fontAtlas.cellSize.width,
        cellHeight: fontAtlas.cellSize.height,
        descent: fontAtlas.descent,
        scale: scale),
      "could not build a MetalGlyphAtlas for the prewarm",
      file: file,
      line: line)
  }

  func testCompatiblePrebuiltAtlasIsAdoptedAtInit() throws {
    let device = try requireDevice()
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let prebuilt = try makePrewarmedAtlas(device: device, fontAtlas: fontAtlas, scale: 2)
    prebuilt.prewarmASCII(fontAtlas: fontAtlas)

    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(fontAtlas: fontAtlas, scale: 2, prebuiltRasterAtlas: prebuilt),
      "SlugGlyphRenderer must construct with Metal available")

    XCTAssertTrue(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a compatible prebuilt atlas must be adopted at init, not rebuilt")
  }

  func testScaleMismatchedPrebuiltAtlasHeldThenAdoptedAtResize() throws {
    let device = try requireDevice()
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let prebuilt = try makePrewarmedAtlas(device: device, fontAtlas: fontAtlas, scale: 2)
    prebuilt.prewarmASCII(fontAtlas: fontAtlas)

    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(fontAtlas: fontAtlas, scale: 1, prebuiltRasterAtlas: prebuilt),
      "SlugGlyphRenderer must construct with Metal available")

    XCTAssertFalse(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a scale-mismatched prebuilt atlas must not be adopted at init")
    XCTAssertNotNil(
      renderer.debugRasterAtlasForTesting,
      "init must still build a fresh atlas for its own scale")

    XCTAssertTrue(renderer.resize(pixelWidth: 640, pixelHeight: 360, scale: 2))

    XCTAssertTrue(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a held prebuilt atlas must be adopted at the first resize whose scale matches it")
  }

  func testWrongCellSizePrebuiltAtlasIsNeverAdopted() throws {
    let device = try requireDevice()
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let otherFontAtlas = FontAtlas(pointSize: 18, fontName: nil)
    let prebuilt = try makePrewarmedAtlas(device: device, fontAtlas: otherFontAtlas, scale: 2)
    prebuilt.prewarmASCII(fontAtlas: otherFontAtlas)

    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(fontAtlas: fontAtlas, scale: 2, prebuiltRasterAtlas: prebuilt),
      "SlugGlyphRenderer must construct with Metal available")

    XCTAssertFalse(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a prebuilt atlas with the wrong cell size must not be adopted at init")

    XCTAssertTrue(renderer.resize(pixelWidth: 640, pixelHeight: 360, scale: 2))

    XCTAssertFalse(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a prebuilt atlas with the wrong cell size must not be adopted at resize either")
  }
}
