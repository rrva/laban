import Metal
import XCTest

@testable import LabanRenderer

/// `VectorGlyphRenderer.init` accepts an optional prebuilt raster atlas (and
/// sidebar atlas) from a background cold-launch prewarm pass and adopts it
/// when its device + cell geometry + scale match, so the renderer's first
/// frame hits warm glyph-atlas entries instead of rasterizing cold on the main
/// thread. These tests assert the adoption contract: identity reuse when
/// compatible at `init`, hold-then-adopt at `resize` when the prewarm scale
/// does not match `init`'s scale (the Retina cold-launch case), rejection when
/// the cell size is wrong, and that a prewarmed glyph resolves as a cache hit.
/// See execplans/active/vector-glyph-cold-launch-stall.md.
final class VectorGlyphRendererPrebuiltAtlasTests: XCTestCase {
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

  /// A prebuilt atlas whose scale matches `init`'s scale is adopted immediately
  /// (identity `===`), avoiding a fresh cold build.
  func testCompatiblePrebuiltAtlasIsAdoptedAtInit() throws {
    let device = try requireDevice()
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let prebuilt = try makePrewarmedAtlas(device: device, fontAtlas: fontAtlas, scale: 2)
    prebuilt.prewarmASCII(fontAtlas: fontAtlas)

    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(fontAtlas: fontAtlas, scale: 2, prebuiltRasterAtlas: prebuilt),
      "VectorGlyphRenderer must construct with Metal available")

    XCTAssertTrue(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a compatible prebuilt atlas must be adopted at init, not rebuilt")
  }

  /// A prebuilt atlas whose scale does NOT match `init`'s scale is held aside
  /// (not adopted at init, not silently dropped), then adopted at the first
  /// `resize` whose scale matches it. This is the Retina cold-launch case:
  /// `makeRendererBackend` constructs at scale 1, `preparePendingBackendSwap`
  /// resizes to the real backing scale.
  func testScaleMismatchedPrebuiltAtlasHeldThenAdoptedAtResize() throws {
    let device = try requireDevice()
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let prebuilt = try makePrewarmedAtlas(device: device, fontAtlas: fontAtlas, scale: 2)
    prebuilt.prewarmASCII(fontAtlas: fontAtlas)

    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(fontAtlas: fontAtlas, scale: 1, prebuiltRasterAtlas: prebuilt),
      "VectorGlyphRenderer must construct with Metal available")

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

  /// A prebuilt atlas built for a different cell size (different font) is never
  /// adopted, at init or at resize, so a wrongly-sized atlas cannot silently
  /// produce garbled glyphs.
  func testWrongCellSizePrebuiltAtlasIsNeverAdopted() throws {
    let device = try requireDevice()
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let otherFontAtlas = FontAtlas(pointSize: 18, fontName: nil)
    let prebuilt = try makePrewarmedAtlas(device: device, fontAtlas: otherFontAtlas, scale: 2)
    prebuilt.prewarmASCII(fontAtlas: otherFontAtlas)

    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(fontAtlas: fontAtlas, scale: 2, prebuiltRasterAtlas: prebuilt),
      "VectorGlyphRenderer must construct with Metal available")

    XCTAssertFalse(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a prebuilt atlas with the wrong cell size must not be adopted at init")

    XCTAssertTrue(renderer.resize(pixelWidth: 640, pixelHeight: 360, scale: 2))

    XCTAssertFalse(
      renderer.debugRasterAtlasForTesting === prebuilt,
      "a prebuilt atlas with the wrong cell size must not be adopted at resize either")
  }

  /// A glyph prewarmed via `prewarmASCII` resolves as a cache hit through the
  /// atlas: no new `rasterizeAndPack` (so `rasterizedGlyphCount` does not
  /// advance), while a non-ASCII glyph outside the prewarm range still
  /// rasterizes on first lookup.
  func testPrewarmedASCIIGlyphIsACacheHit() throws {
    let device = try requireDevice()
    let fontAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let atlas = try makePrewarmedAtlas(device: device, fontAtlas: fontAtlas, scale: 2)
    let before = atlas.rasterizedGlyphCount
    atlas.prewarmASCII(fontAtlas: fontAtlas)
    let afterPrewarm = atlas.rasterizedGlyphCount
    XCTAssertGreaterThan(
      afterPrewarm, before,
      "prewarmASCII must rasterize glyphs into the atlas")

    let regular = fontAtlas.styledFontVariant(bold: false, italic: false)
    // "A" (U+0041) is in the printable-ASCII prewarm range: a cache hit.
    _ = atlas.entry(
      scalar: Unicode.Scalar(0x41)!,
      font: regular.font,
      boldFallback: regular.boldFallback,
      italicFallback: regular.italicFallback)
    XCTAssertEqual(
      atlas.rasterizedGlyphCount, afterPrewarm,
      "a prewarmed ASCII glyph must resolve as a cache hit (no new rasterization)")

    // "€" (U+20AC) is outside the ASCII prewarm range: a cache miss.
    _ = atlas.entry(
      scalar: Unicode.Scalar(0x20AC)!,
      font: regular.font,
      boldFallback: regular.boldFallback,
      italicFallback: regular.italicFallback)
    XCTAssertEqual(
      atlas.rasterizedGlyphCount, afterPrewarm + 1,
      "a non-ASCII glyph outside the prewarm range must rasterize on first lookup")
  }
}
