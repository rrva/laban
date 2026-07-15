import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

enum RendererTransparencyTestSupport {
  static let alpha70 = UInt8(179)
  static let canvas: UInt32 = 0x2040_60B3
  static let opaqueCell: UInt32 = 0xD020_30FF

  static func commands(
    width: CGFloat = 16,
    height: CGFloat = 16,
    canvasWidth: CGFloat? = nil
  ) -> [FrameCommand] {
    [
      .rect(
        CGRect(x: 0, y: 0, width: canvasWidth ?? width, height: height),
        color: canvas,
        source: .terminal,
        compositing: .replace),
      .rect(
        CGRect(x: 4, y: 4, width: 4, height: 4),
        color: opaqueCell,
        source: .terminal,
        compositing: .replace),
    ]
  }

  static func makeBackend(_ selection: RendererSelection) throws -> RendererBackend {
    if selection != .software, MTLCreateSystemDefaultDevice() == nil {
      throw XCTSkip("Metal-backed renderer unavailable")
    }
    let atlas = FontAtlas(pointSize: 14)
    let backend = makeRendererBackend(
      selection: selection,
      fontAtlas: atlas,
      sidebarFontAtlas: atlas,
      pixelWidth: 16,
      pixelHeight: 16,
      scale: 1,
      surfaceTransparency: RendererSurfaceTransparency(isOpaque: false))
    backend.waitForFrameCompletion = true
    if let metal = backend as? MetalRenderer {
      metal.captureMode = true
    }
    if let slug = backend as? SlugGlyphRenderer {
      slug.presentsToLayer = false
      slug.setSubpixelLayout(.grayscale)
    }
    if let vector = backend as? VectorGlyphRenderer {
      vector.setSubpixelLayout(.grayscale)
    }
    return backend
  }

  static func renderImage(
    _ backend: RendererBackend,
    commands: [FrameCommand],
    damage: RenderDamage
  ) throws -> TestRGBAImage {
    guard backend.render(commands, damage: damage) else {
      throw RendererTestSupportError("renderer rejected frame")
    }
    if let metal = backend as? MetalRenderer {
      metal.waitForLastFrame()
    }
    return try decodePNGToRGBA(
      try XCTUnwrap(backend.pngData, "renderer did not produce alpha-preserving PNG data"))
  }

  static func assertSemanticAlpha(
    _ image: TestRGBAImage,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertLessThanOrEqual(
      abs(Int(image.pixel(x: 1, y: 1).a) - Int(alpha70)),
      1,
      file: file,
      line: line)
    XCTAssertEqual(image.pixel(x: 5, y: 5).a, 255, file: file, line: line)
  }
}
