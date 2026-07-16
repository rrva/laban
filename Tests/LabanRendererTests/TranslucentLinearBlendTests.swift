import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

/// Vector and Slug advertise linear-light text compositing. Their presentation
/// bytes must also remain encoded-sRGB premultiplied so Core Animation can
/// composite a translucent window. These probes exercise both requirements at
/// once: an opaque white-on-black render supplies the actual grayscale glyph
/// coverage, then the same glyph is composited over a bright translucent canvas
/// and compared with the source-over equation itself.
final class TranslucentLinearBlendTests: XCTestCase {
  private let width = 900
  private let height = 200
  private let scale: CGFloat = 2
  private let probe = "Hglo08B/N"
  private let canvas: UInt32 = 0xFBF3_DB4D

  func testOpaqueCurveRendererActivationDoesNotPrepareTranslucentResources() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal-backed renderer unavailable")
    }
    let atlas = FontAtlas(pointSize: 14)
    let opaqueCommands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: 16, height: 16),
        color: 0x2040_60FF,
        source: .terminal,
        compositing: .replace)
    ]
    let translucentCommands = RendererTransparencyTestSupport.brightFrostedCommands()

    let vector = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        pixelWidth: 16,
        pixelHeight: 16,
        surfaceTransparency: RendererSurfaceTransparency(isOpaque: true)))
    vector.waitForFrameCompletion = true
    XCTAssertFalse(vector.hasTranslucentPipelinesForTesting)
    XCTAssertFalse(vector.hasTranslucentWorkingTargetForTesting)
    XCTAssertTrue(vector.render(opaqueCommands, damage: .full))
    XCTAssertFalse(vector.hasTranslucentPipelinesForTesting)
    XCTAssertFalse(vector.hasTranslucentWorkingTargetForTesting)
    vector.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: false))
    XCTAssertTrue(vector.hasTranslucentPipelinesForTesting)
    XCTAssertFalse(vector.hasTranslucentWorkingTargetForTesting)
    XCTAssertTrue(vector.render(translucentCommands, damage: .full))
    XCTAssertTrue(vector.hasTranslucentWorkingTargetForTesting)
    vector.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: true))
    XCTAssertFalse(vector.hasTranslucentWorkingTargetForTesting)
    XCTAssertTrue(vector.render(opaqueCommands, damage: .full))
    XCTAssertFalse(vector.hasTranslucentWorkingTargetForTesting)

    let slug = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: atlas,
        pixelWidth: 16,
        pixelHeight: 16,
        surfaceTransparency: RendererSurfaceTransparency(isOpaque: true)))
    slug.waitForFrameCompletion = true
    slug.presentsToLayer = false
    XCTAssertFalse(slug.hasTranslucentPipelinesForTesting)
    XCTAssertFalse(slug.hasTranslucentWorkingTargetForTesting)
    XCTAssertTrue(slug.render(opaqueCommands, damage: .full))
    XCTAssertFalse(slug.hasTranslucentPipelinesForTesting)
    XCTAssertFalse(slug.hasTranslucentWorkingTargetForTesting)
    slug.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: false))
    XCTAssertTrue(slug.hasTranslucentPipelinesForTesting)
    XCTAssertFalse(slug.hasTranslucentWorkingTargetForTesting)
    XCTAssertTrue(slug.render(translucentCommands, damage: .full))
    XCTAssertTrue(slug.hasTranslucentWorkingTargetForTesting)
    slug.setSurfaceTransparency(RendererSurfaceTransparency(isOpaque: true))
    XCTAssertFalse(slug.hasTranslucentWorkingTargetForTesting)
    XCTAssertTrue(slug.render(opaqueCommands, damage: .full))
    XCTAssertFalse(slug.hasTranslucentWorkingTargetForTesting)
  }

  func testVectorAndSlugGlyphEdgesBlendInLinearLightOverBrightTransparency() throws {
    for selection in [RendererSelection.vectorGlyph, .slugGlyph] {
      let backend = try makeBackend(selection)
      let coverage = try render(
        backend,
        canvas: 0x0000_00FF,
        foreground: 0xFFFF_FFFF)
      let actual = try render(
        backend,
        canvas: canvas,
        foreground: 0x0000_00FF)

      var partialEdges = 0
      var maxRGBError = 0
      var maxAlphaError = 0
      for y in 0..<height {
        for x in 0..<width {
          let maskPixel = coverage.pixel(x: x, y: y)
          guard maskPixel.r > 12, maskPixel.r < 243 else { continue }
          let glyphCoverage = linearize(Double(maskPixel.r) / 255)
          let expected = expectedSourceOver(
            destination: canvas,
            source: 0x0000_00FF,
            coverage: glyphCoverage)
          let pixel = actual.pixel(x: x, y: y)
          maxRGBError = max(
            maxRGBError,
            abs(Int(pixel.r) - expected.r),
            abs(Int(pixel.g) - expected.g),
            abs(Int(pixel.b) - expected.b))
          maxAlphaError = max(maxAlphaError, abs(Int(pixel.a) - expected.a))
          partialEdges += 1
        }
      }

      XCTAssertGreaterThan(
        partialEdges, 200,
        "\(selection.rawValue) probe must contain grayscale antialiased edges")
      XCTAssertLessThanOrEqual(
        maxRGBError, 4,
        "\(selection.rawValue) glyph edges violate linear-light source-over")
      XCTAssertLessThanOrEqual(
        maxAlphaError, 3,
        "\(selection.rawValue) glyph coverage must raise destination alpha")
    }
  }

  func testVectorAndSlugSemanticOverlayBlendsInLinearLightOverBrightTransparency() throws {
    let overlay: UInt32 = 0x1830_4880
    for selection in [RendererSelection.vectorGlyph, .slugGlyph] {
      let backend = try makeBackend(selection)
      let commands: [FrameCommand] = [
        .rect(
          CGRect(x: 0, y: 0, width: 450, height: 100),
          color: canvas,
          source: .terminal,
          compositing: .replace),
        .selection(CGRect(x: 20, y: 20, width: 100, height: 40), color: overlay),
      ]
      let image = try render(backend, commands: commands)
      let expected = expectedSourceOver(
        destination: canvas,
        source: overlay,
        coverage: 1)
      let pixel = image.pixel(x: 100, y: 120)
      XCTAssertEqual(
        Int(pixel.r), expected.r, accuracy: 3,
        "\(selection.rawValue) semantic red")
      XCTAssertEqual(
        Int(pixel.g), expected.g, accuracy: 3,
        "\(selection.rawValue) semantic green")
      XCTAssertEqual(
        Int(pixel.b), expected.b, accuracy: 3,
        "\(selection.rawValue) semantic blue")
      XCTAssertEqual(
        Int(pixel.a), expected.a, accuracy: 2,
        "\(selection.rawValue) semantic alpha")
    }
  }

  private func makeBackend(_ selection: RendererSelection) throws -> RendererBackend {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal-backed renderer unavailable")
    }
    let atlas = FontAtlas(pointSize: 32)
    let backend = makeRendererBackend(
      selection: selection,
      fontAtlas: atlas,
      sidebarFontAtlas: atlas,
      pixelWidth: width,
      pixelHeight: height,
      scale: scale,
      surfaceTransparency: RendererSurfaceTransparency(isOpaque: false))
    backend.waitForFrameCompletion = true
    if let vector = backend as? VectorGlyphRenderer {
      vector.setSubpixelLayout(.grayscale)
    }
    if let slug = backend as? SlugGlyphRenderer {
      slug.presentsToLayer = false
      slug.setSubpixelLayout(.grayscale)
    }
    return backend
  }

  private func render(
    _ backend: RendererBackend,
    canvas: UInt32,
    foreground: UInt32
  ) throws -> TestRGBAImage {
    try render(
      backend,
      commands: [
        .rect(
          CGRect(x: 0, y: 0, width: 450, height: 100),
          color: canvas,
          source: .terminal,
          compositing: .replace),
        .glyphRun(
          origin: CGPoint(x: 8, y: 12),
          text: probe,
          foreground: foreground,
          background: canvas,
          attributes: [],
          source: .terminal),
      ])
  }

  private func render(
    _ backend: RendererBackend,
    commands: [FrameCommand]
  ) throws -> TestRGBAImage {
    XCTAssertTrue(backend.render(commands, damage: .full))
    return try decodePNGToRGBA(
      try XCTUnwrap(backend.pngData, "renderer did not produce PNG data"))
  }

  private func expectedSourceOver(
    destination: UInt32,
    source: UInt32,
    coverage: Double
  ) -> (r: Int, g: Int, b: Int, a: Int) {
    let destinationAlpha = Double(destination & 0xFF) / 255
    let sourceAlpha = Double(source & 0xFF) / 255 * coverage
    let outputAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha)

    func channel(_ shift: UInt32) -> Int {
      let destinationSRGB = Double((destination >> shift) & 0xFF) / 255
      let sourceSRGB = Double((source >> shift) & 0xFF) / 255
      let linearPremultiplied =
        linearize(sourceSRGB) * sourceAlpha
        + linearize(destinationSRGB) * destinationAlpha * (1 - sourceAlpha)
      guard outputAlpha > 0 else { return 0 }
      let encodedPremultiplied = encode(linearPremultiplied / outputAlpha) * outputAlpha
      return Int((encodedPremultiplied * 255).rounded())
    }

    return (
      channel(24),
      channel(16),
      channel(8),
      Int((outputAlpha * 255).rounded())
    )
  }

  private func linearize(_ value: Double) -> Double {
    value <= 0.04045
      ? value / 12.92
      : pow((value + 0.055) / 1.055, 2.4)
  }

  private func encode(_ value: Double) -> Double {
    value <= 0.0031308
      ? value * 12.92
      : 1.055 * pow(value, 1 / 2.4) - 0.055
  }
}
