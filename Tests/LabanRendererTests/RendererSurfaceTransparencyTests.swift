import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

final class RendererSurfaceTransparencyTests: XCTestCase {
  func testEveryLayerBackendFlipsOpacityBeforePresentation() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal-backed renderer surfaces are unavailable")
    }

    let fontAtlas = FontAtlas(pointSize: 14)
    let backends: [(String, RendererBackend)] = [
      (
        "classic",
        try XCTUnwrap(
          MetalRenderer(fontAtlas: fontAtlas, rendererMode: .classic))),
      (
        "gpuDriven",
        try XCTUnwrap(
          MetalRenderer(fontAtlas: fontAtlas, rendererMode: .gpuDriven))),
      (
        "vectorGlyph",
        try XCTUnwrap(
          VectorGlyphRenderer(
            fontAtlas: fontAtlas, pixelWidth: 16, pixelHeight: 16))),
      (
        "slugGlyph",
        try XCTUnwrap(
          SlugGlyphRenderer(
            fontAtlas: fontAtlas, pixelWidth: 16, pixelHeight: 16))),
    ]

    for (name, backend) in backends {
      let layer = try XCTUnwrap(backend.presentationLayer, "\(name) presentation layer")
      XCTAssertTrue(layer.isOpaque, "\(name) should default to an opaque layer")

      backend.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: false))
      XCTAssertFalse(layer.isOpaque, "\(name) should become nonopaque before presentation")

      backend.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: true))
      XCTAssertTrue(layer.isOpaque, "\(name) should become opaque before presentation")
    }
  }

  func testSoftwareTransitionRebuildsBitmapAndEqualApplicationIsNoOp() {
    let backend = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: 14),
      pixelWidth: 8,
      pixelHeight: 8)
    _ = backend.render([
      .rect(
        CGRect(x: 0, y: 0, width: 8, height: 8),
        color: 0x1122_33FF,
        source: .terminal)
    ])
    XCTAssertNotNil(backend.presentationImage)

    let opaqueSurface = backend.surface
    backend.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: false))
    XCTAssertFalse(backend.surfaceTransparency.isOpaque)
    XCTAssertFalse(backend.surface === opaqueSurface)
    XCTAssertNil(backend.presentationImage)

    let nonopaqueSurface = backend.surface
    backend.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: false))
    XCTAssertTrue(backend.surface === nonopaqueSurface)

    backend.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: true))
    XCTAssertTrue(backend.surfaceTransparency.isOpaque)
    XCTAssertFalse(backend.surface === nonopaqueSurface)
    XCTAssertNil(backend.presentationImage)
  }

  func testFactoryAppliesInitialSurfaceStateBeforeExposure() throws {
    let fontAtlas = FontAtlas(pointSize: 14)
    for selection in RendererSelection.allCases {
      let backend = makeRendererBackend(
        selection: selection,
        fontAtlas: fontAtlas,
        pixelWidth: 16,
        pixelHeight: 16,
        surfaceTransparency: RendererSurfaceTransparency(isOpaque: false))

      if let layer = backend.presentationLayer {
        XCTAssertFalse(layer.isOpaque, "\(selection.rawValue) factory layer")
      } else {
        let software = try XCTUnwrap(backend as? SoftwareBackend)
        XCTAssertFalse(software.surfaceTransparency.isOpaque)
      }
    }
  }
}
