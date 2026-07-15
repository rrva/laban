import XCTest

@testable import LabanRenderer

final class SlugGlyphTransparencyTests: XCTestCase {
  func testRepeatedPartialDamageErasesBeforeReplay() throws {
    let backend = try RendererTransparencyTestSupport.makeBackend(.slugGlyph)
    _ = try RendererTransparencyTestSupport.renderImage(
      backend,
      commands: RendererTransparencyTestSupport.commands(),
      damage: .full)
    var image: TestRGBAImage?
    for _ in 0..<100 {
      image = try RendererTransparencyTestSupport.renderImage(
        backend,
        commands: RendererTransparencyTestSupport.commands(),
        damage: .partial(yRanges: [DirtyYRange(y: 0, height: 8)]))
    }
    RendererTransparencyTestSupport.assertSemanticAlpha(try XCTUnwrap(image))
  }

  func testTransparentSurfaceForcesGrayscaleAndRestoresConfiguredLayout() throws {
    let renderer = try XCTUnwrap(
      try RendererTransparencyTestSupport.makeBackend(.slugGlyph) as? SlugGlyphRenderer)
    renderer.setSubpixelLayout(.rgbStripe)
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .grayscale)
    XCTAssertEqual(renderer.effectiveSubpixelFallbackReason, "transparentSurface")
    renderer.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: true))
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .rgbStripe)
    XCTAssertNil(renderer.effectiveSubpixelFallbackReason)
  }
}
