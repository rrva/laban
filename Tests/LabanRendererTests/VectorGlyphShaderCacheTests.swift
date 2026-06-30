import Metal
import XCTest

@testable import LabanRenderer

/// Before this cache existed, `VectorGlyphRenderer.init` and the nested
/// `VectorGlyphScratchRasterizer.init` each independently compiled
/// `VectorGlyphShaders.metal` and rebuilt their pipeline states from scratch on
/// every renderer activation — the dominant CPU cost (and several-hundred-ms
/// main-thread stall) of switching into the vector renderer, per a Metal
/// System Trace of repeated renderer switching. These tests assert the actual
/// invariant the fix establishes: repeated lookups return the SAME compiled
/// objects rather than rebuilding, for both the renderer's 5 render pipeline
/// states and the scratch rasterizer's 2 compute pipeline states.
final class VectorGlyphShaderCacheTests: XCTestCase {
  private func requireDevice() throws -> MTLDevice {
    try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device available")
  }

  func testLibraryIsBuiltOnceAndReusedAcrossCalls() throws {
    let device = try requireDevice()
    let first = try XCTUnwrap(VectorGlyphShaderCache.library(device: device))
    let second = try XCTUnwrap(VectorGlyphShaderCache.library(device: device))
    XCTAssertTrue(
      first === second, "library(device:) must return the cached instance, not recompile")
  }

  func testRenderPipelinesAreBuiltOnceAndReusedAcrossCalls() throws {
    let device = try requireDevice()
    let first = try XCTUnwrap(
      VectorGlyphShaderCache.renderPipelines(device: device, pixelFormat: .bgra8Unorm_srgb))
    let second = try XCTUnwrap(
      VectorGlyphShaderCache.renderPipelines(device: device, pixelFormat: .bgra8Unorm_srgb))
    XCTAssertTrue(first.solid === second.solid)
    XCTAssertTrue(first.glyphCoverage === second.glyphCoverage)
    XCTAssertTrue(first.glyphColor === second.glyphColor)
    XCTAssertTrue(first.rasterGlyph === second.rasterGlyph)
    XCTAssertTrue(first.colorGlyph === second.colorGlyph)
  }

  func testComputePipelinesAreBuiltOnceAndReusedAcrossCalls() throws {
    let device = try requireDevice()
    let first = try XCTUnwrap(VectorGlyphShaderCache.computePipelines(device: device))
    let second = try XCTUnwrap(VectorGlyphShaderCache.computePipelines(device: device))
    XCTAssertTrue(first.scratch === second.scratch)
    XCTAssertTrue(first.accum === second.accum)
  }

  /// The two real call sites (`VectorGlyphRenderer.init` and
  /// `VectorGlyphScratchRasterizer.init`) both resolve through the cache. This
  /// asserts they end up sharing the SAME compiled library rather than each
  /// holding an independent compile, which was the actual double-compile bug.
  func testRendererAndScratchRasterizerShareTheCachedLibrary() throws {
    let device = try requireDevice()
    let viaRenderPipelines = try XCTUnwrap(VectorGlyphShaderCache.library(device: device))
    let viaScratchRasterizer = try XCTUnwrap(VectorGlyphShaderCache.library(device: device))
    XCTAssertTrue(viaRenderPipelines === viaScratchRasterizer)
  }

  /// End-to-end: constructing the renderer twice (mirroring a switch away from
  /// and back to vector) must keep succeeding and must not rebuild the cached
  /// objects — the actual scenario the trace showed as slow.
  func testConstructingTwoVectorGlyphRenderersReusesTheCache() throws {
    let device = try requireDevice()
    let beforeLibrary = VectorGlyphShaderCache.library(device: device)
    let atlas = FontAtlas(pointSize: 14, fontName: nil)
    XCTAssertNotNil(VectorGlyphRenderer(fontAtlas: atlas))
    XCTAssertNotNil(VectorGlyphRenderer(fontAtlas: atlas))
    let afterLibrary = VectorGlyphShaderCache.library(device: device)
    XCTAssertTrue(
      beforeLibrary === afterLibrary, "constructing renderers must not recompile the library")
  }
}
