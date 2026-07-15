import XCTest

@testable import LabanRenderer

final class VectorGlyphTransparencyTests: XCTestCase {
  func testZoomMarginUsesEffectiveAlphaCanvas() throws {
    let backend = try RendererTransparencyTestSupport.makeBackend(.vectorGlyph)
    let image = try RendererTransparencyTestSupport.renderImage(
      backend,
      commands: RendererTransparencyTestSupport.commands(canvasWidth: 8),
      damage: .full)
    XCTAssertLessThanOrEqual(
      abs(Int(image.pixel(x: 15, y: 15).a) - Int(RendererTransparencyTestSupport.alpha70)),
      1)
  }

  func testTransparentSurfaceForcesGrayscaleAndRestoresConfiguredLayout() throws {
    let renderer = try XCTUnwrap(
      try RendererTransparencyTestSupport.makeBackend(.vectorGlyph) as? VectorGlyphRenderer)
    renderer.setSubpixelLayout(.rgbStripe)
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .grayscale)
    XCTAssertEqual(renderer.effectiveSubpixelFallbackReason, "transparentSurface")
    renderer.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: true))
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .rgbStripe)
    XCTAssertNil(renderer.effectiveSubpixelFallbackReason)
  }
}
