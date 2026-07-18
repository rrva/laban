import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

enum RendererTransparencyTestSupport {
  static let alpha70 = UInt8(179)
  static let canvas: UInt32 = 0x2040_60B3
  static let frostedAlpha = UInt8(204)
  static let brightFrostedCanvas: UInt32 = 0xFBF3_DBCC
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
        // A full-height stripe avoids CoreGraphics/PNG row-orientation
        // ambiguity while still leaving canvas probes on both sides.
        CGRect(x: 4, y: 0, width: 4, height: height),
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

  static func brightFrostedCommands() -> [FrameCommand] {
    [
      .rect(
        CGRect(x: 0, y: 0, width: 16, height: 16),
        color: brightFrostedCanvas,
        source: .terminal,
        compositing: .replace)
    ]
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
      // PNG rows are top-down, so y=12 samples the lower logical half covered
      // by the partial-damage range used by the idempotence suites.
      abs(Int(image.pixel(x: 1, y: 12).a) - Int(alpha70)),
      1,
      file: file,
      line: line)
    XCTAssertEqual(image.pixel(x: 5, y: 12).a, 255, file: file, line: line)
  }

  static func assertBrightFrostedCanvas(
    _ image: TestRGBAImage,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let pixel = image.pixel(x: 1, y: 12)
    let alpha = Int(frostedAlpha)
    XCTAssertEqual(Int(pixel.a), alpha, accuracy: 1, file: file, line: line)

    // PNG decode exposes encoded-sRGB premultiplied bytes. Bright channels
    // must remain <= alpha, and unpremultiplying them must recover the
    // Selenized Light canvas rather than clipped white.
    let expectedStraight = [0xFB, 0xF3, 0xDB]
    for (channel, expected) in zip([pixel.r, pixel.g, pixel.b], expectedStraight) {
      XCTAssertLessThanOrEqual(Int(channel), Int(pixel.a), file: file, line: line)
      let straight = Int((Double(channel) * 255 / Double(max(1, pixel.a))).rounded())
      XCTAssertEqual(straight, expected, accuracy: 4, file: file, line: line)
    }
  }
}
