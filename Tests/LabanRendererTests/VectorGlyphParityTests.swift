import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

final class VectorGlyphParityTests: XCTestCase {
  private let artifactRoot = URL(
    fileURLWithPath: ".build/vector-glyph-parity",
    isDirectory: true)

  /// Pins the weight in the per-process registration domain. Nothing here
  /// writes `UserDefaults.standard` any more: a persisted value is visible to
  /// every concurrently running test process and is what used to leave
  /// `LabanVectorTextWeight` stuck non-default. See
  /// `execplans/active/test-userdefaults-isolation.md`.
  fileprivate static func registerTextWeight(_ weight: Double) {
    UserDefaults.standard.register(defaults: [VectorTextWeightSettings.defaultsKey: weight])
  }

  override func setUp() {
    super.setUp()
    try? FileManager.default.removeItem(at: artifactRoot)
    Self.registerTextWeight(VectorTextWeightSettings.defaultWeight)
  }

  override func tearDown() {
    Self.registerTextWeight(VectorTextWeightSettings.defaultWeight)
    super.tearDown()
  }

  func testLargeGlyphMasksGetStableFirstResidencySampleBudget() {
    XCTAssertEqual(
      VectorGlyphRenderer.accumulationSamplesThisFrame(sampleStart: 0, maskPixels: 32 * 32),
      512)
    XCTAssertEqual(
      VectorGlyphRenderer.accumulationSamplesThisFrame(sampleStart: 0, maskPixels: 48 * 64),
      512)
    XCTAssertEqual(
      VectorGlyphRenderer.accumulationSamplesThisFrame(sampleStart: 0, maskPixels: 96 * 96),
      512)
    XCTAssertEqual(
      VectorGlyphRenderer.accumulationSamplesThisFrame(sampleStart: 128, maskPixels: 96 * 96),
      8)
  }

  func testRendererGlyphMasksMatchCPUOracleForPrintableASCII() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    Self.registerTextWeight(0)
    defer { Self.registerTextWeight(VectorTextWeightSettings.defaultWeight) }

    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 512,
        pixelHeight: 256,
        scale: 1))
    renderer.refreshTextWeight()
    let store = GlyphCurveStore()

    var checked = 0
    for value in 0x20...0x7E {
      let scalar = try XCTUnwrap(Unicode.Scalar(value))
      guard let glyph = glyph(for: scalar, font: atlas.font) else { continue }
      guard let outline = store.outline(for: glyph, font: atlas.font) else { continue }
      let actual = try XCTUnwrap(
        renderer.maskSnapshot(for: glyph, font: atlas.font),
        "renderer mask missing for U+\(String(format: "%04X", value))")
      let expected = cpuSingleSampleMask(
        outline: outline,
        width: actual.width,
        height: actual.height,
        origin: actual.origin)

      let comparison = compare(expected: expected, actual: actual.bytes)
      if comparison.mismatchedPixels > comparison.allowedMismatches {
        writeArtifacts(
          scalarValue: value,
          width: actual.width,
          height: actual.height,
          expected: expected,
          actual: actual.bytes)
      }

      XCTAssertLessThanOrEqual(
        comparison.mismatchedPixels,
        comparison.allowedMismatches,
        "U+\(String(format: "%04X", value)) edge mismatches, max delta \(comparison.maxDelta)")
      checked += 1
    }
    XCTAssertGreaterThan(checked, 80, "printable ASCII should exercise most outline glyphs")
  }

  func testSyntheticItalicMaskUsesShearedVectorOutline() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 512,
        pixelHeight: 256,
        scale: 1))
    let scalar = try XCTUnwrap(Unicode.Scalar("H"))
    let glyph = try XCTUnwrap(glyph(for: scalar, font: atlas.font))
    let regular = try XCTUnwrap(renderer.maskSnapshot(for: glyph, font: atlas.font))
    let syntheticItalic = try XCTUnwrap(
      renderer.maskSnapshot(for: glyph, font: atlas.font, syntheticItalic: true))

    let geometryDiffers =
      regular.width != syntheticItalic.width
      || regular.height != syntheticItalic.height
      || regular.origin != syntheticItalic.origin
    XCTAssertTrue(
      geometryDiffers || regular.bytes != syntheticItalic.bytes,
      "synthetic italic must not alias the regular vector mask")
  }

  func testDecorationStylesChangeVectorOutput() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let baseline = try renderDecorationProbe(attributes: [], underlineStyle: .none)
    let styles: [(TextAttributes, UnderlineStyle, UInt32?)] = [
      ([.underline], .single, nil),
      ([], .double, nil),
      ([], .dotted, nil),
      ([], .dashed, nil),
      ([], .curly, nil),
      ([.strikethrough], .none, nil),
      ([.overline], .none, nil),
      ([.underline, .strikethrough, .overline], .single, 0x33_99_FF_FF),
    ]

    for (attributes, underlineStyle, underlineColor) in styles {
      let decorated = try renderDecorationProbe(
        attributes: attributes,
        underlineStyle: underlineStyle,
        underlineColor: underlineColor)
      XCTAssertNotEqual(
        decorated,
        baseline,
        "decoration style \(underlineStyle) attributes \(attributes) must affect vector output")
    }
  }

  func testRendererHandlesLiveSizedInstanceBatches() throws {
    // Regression: Metal's setVertexBytes path aborts above 4 KB. A normal
    // terminal-sized vector frame can exceed that with either rect or glyph
    // instances, so the renderer must use buffer-backed instance uploads.
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let atlas = FontAtlas(pointSize: 14, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 1640,
        pixelHeight: 912,
        scale: 2))

    var commands: [FrameCommand] = []
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    for row in 0..<48 {
      for col in 0..<160 {
        let r = UInt32((row * 7 + col) & 0xFF)
        let g = UInt32((col * 5 + row * 3) & 0xFF)
        let b = UInt32((row * col) & 0xFF)
        let color = (r << 24) | (g << 16) | (b << 8) | 0xFF
        commands.append(
          .rect(
            CGRect(
              x: CGFloat(col) * cellW,
              y: CGFloat(row) * cellH,
              width: cellW,
              height: cellH),
            color: color,
            source: .terminal))
      }
    }

    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    let line = String(String(repeating: ascii, count: 2).prefix(160))
    for row in 0..<48 {
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: line,
          foreground: 0xEE_EE_EE_FF,
          background: 0x00_00_00_00,
          attributes: [],
          source: .terminal))
    }

    for _ in 0..<3 {
      XCTAssertTrue(renderer.render(commands, damage: .full))
      XCTAssertGreaterThan(try XCTUnwrap(renderer.pngData).count, 0)
    }
  }

  func testLargeVectorTextFirstFrameDoesNotHaveSevereSettlingArtifacts() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let scale: CGFloat = 2
    let width = 1600
    let height = 360
    let atlas = FontAtlas(pointSize: 48, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: width,
        pixelHeight: height,
        scale: scale))
    renderer.setSubpixelLayout(.grayscale)

    let commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
        color: 0x10_10_10_FF,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 18, y: 26),
        text: "What should Claude Code do next? /config",
        foreground: 0xEE_EE_EE_FF,
        background: 0x10_10_10_FF,
        attributes: [],
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 18, y: 96),
        text: "Zoomed vector masks should settle without blocks",
        foreground: 0xEE_EE_EE_FF,
        background: 0x10_10_10_FF,
        attributes: [],
        source: .terminal),
    ]

    XCTAssertTrue(renderer.render(commands, damage: .full))
    let first = try decodeRGBA(try XCTUnwrap(renderer.pngData))
    for frame in 0..<20 {
      XCTAssertTrue(renderer.render(commands, damage: .full), "settling frame \(frame) failed")
    }
    let settled = try decodeRGBA(try XCTUnwrap(renderer.pngData))

    let diff = lumaDiffMetrics(
      lhs: first,
      rhs: settled,
      crop: CGRect(x: 0, y: 0, width: width, height: height),
      threshold: 48)
    XCTAssertLessThan(diff.pixelRatioOverThreshold, 0.003)
    XCTAssertLessThan(diff.largestComponentArea, 80)
  }

  func testSmallAsymmetricGlyphsFirstFrameDoesNotHaveSevereSettlingArtifacts() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let scale: CGFloat = 2
    let width = 960
    let height = 220
    for pointSize in [CGFloat(21), CGFloat(23)] {
      let atlas = FontAtlas(pointSize: pointSize, fontName: nil)
      let commands: [FrameCommand] = [
        .rect(
          CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
          color: 0x10_10_10_FF,
          source: .terminal),
        .glyphRun(
          origin: CGPoint(x: 14, y: 26),
          text: "/ v D l U N /tmp/foo/bar //// /config",
          foreground: 0xEE_EE_EE_FF,
          background: 0x10_10_10_FF,
          attributes: [],
          source: .terminal),
        .glyphRun(
          origin: CGPoint(x: 14, y: 66),
          text: "asymmetric glyph masks must not visibly settle",
          foreground: 0xEE_EE_EE_FF,
          background: 0x10_10_10_FF,
          attributes: [],
          source: .terminal),
      ]

      for layout in [VectorSubpixelLayout.grayscale, .calibratedRGB, .rgbStripe] {
        let renderer = try XCTUnwrap(
          VectorGlyphRenderer(
            fontAtlas: atlas,
            sidebarFontAtlas: atlas,
            pixelWidth: width,
            pixelHeight: height,
            scale: scale))
        renderer.setSubpixelLayout(layout)
        XCTAssertTrue(
          renderer.render(commands, damage: .full),
          "\(layout.name) \(pointSize)pt first frame failed")
        let first = try decodeRGBA(try XCTUnwrap(renderer.pngData))
        for frame in 0..<3 {
          XCTAssertTrue(
            renderer.render(commands, damage: .full),
            "\(layout.name) \(pointSize)pt settling frame \(frame) failed")
        }
        let settled = try decodeRGBA(try XCTUnwrap(renderer.pngData))

        let diff = lumaDiffMetrics(
          lhs: first,
          rhs: settled,
          crop: CGRect(x: 0, y: 0, width: width, height: height),
          threshold: 16)
        XCTAssertLessThan(
          diff.pixelRatioOverThreshold,
          0.0001,
          "\(layout.name) \(pointSize)pt still changes after first residency")
        XCTAssertLessThan(
          diff.largestComponentArea,
          4,
          "\(layout.name) \(pointSize)pt has a severe settling block")
      }
    }
  }

  func testDefaultVectorTextFidelityStaysNearMetalOnLightBackground() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let scale: CGFloat = 2
    let width = 760
    let height = 180
    let atlas = FontAtlas(pointSize: 18, fontName: nil)
    let commands = fidelityProbeCommands()

    let vector = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: width,
        pixelHeight: height,
        scale: scale))
    vector.setSubpixelLayout(.grayscale)
    XCTAssertTrue(vector.render(commands, damage: .full))
    let vectorPNG = try XCTUnwrap(vector.pngData)
    let vectorImage = try decodeRGBA(vectorPNG)

    let reference = try XCTUnwrap(
      MetalRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        scale: scale,
        rendererMode: .classic))
    reference.captureMode = true
    reference.waitForFrameCompletion = true
    reference.resize(pixelWidth: width, pixelHeight: height, scale: scale)
    XCTAssertTrue(reference.render(commands, damage: .full))
    reference.waitForLastFrame()
    let referencePNG = try XCTUnwrap(reference.pngData)
    let referenceImage = try decodeRGBA(referencePNG)

    let crop = CGRect(x: 24, y: 26, width: 700, height: 112)
    let vectorMetrics = fidelityMetrics(
      image: vectorImage,
      crop: crop,
      background: (r: 0xF6, g: 0xEE, b: 0xDB),
      foreground: (r: 0x18, g: 0x22, b: 0x2A))
    let referenceMetrics = fidelityMetrics(
      image: referenceImage,
      crop: crop,
      background: (r: 0xF6, g: 0xEE, b: 0xDB),
      foreground: (r: 0x18, g: 0x22, b: 0x2A))

    XCTAssertGreaterThan(vectorMetrics.inkMass, 10_000, "probe must contain measurable text ink")
    XCTAssertGreaterThan(
      referenceMetrics.inkMass,
      10_000,
      "reference must contain measurable text ink")
    XCTAssertLessThan(
      abs(vectorMetrics.inkMass - referenceMetrics.inkMass) / referenceMetrics.inkMass,
      0.30,
      "vector text ink mass drifted too far from Metal reference")
    XCTAssertLessThanOrEqual(
      vectorMetrics.edgePixelRatio,
      referenceMetrics.edgePixelRatio + 0.18,
      "vector text has too much partial-edge spread, which reads as soft text")
    XCTAssertGreaterThanOrEqual(
      vectorMetrics.meanGradient,
      referenceMetrics.meanGradient * 0.50,
      "vector text edge gradients are too shallow, which reads as blurry text")
    XCTAssertLessThan(
      vectorMetrics.meanCoverageSpread,
      0.025,
      "default grayscale vector rendering should not introduce visible RGB fringing")
  }

  private func glyph(for scalar: Unicode.Scalar, font: CTFont) -> CGGlyph? {
    guard scalar.value <= UInt32(UInt16.max) else { return nil }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else {
      return nil
    }
    return glyph
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]
  }

  private struct LumaDiffMetrics {
    var pixelRatioOverThreshold: Double
    var largestComponentArea: Int
  }

  private struct FidelityMetrics {
    var inkMass: Double
    var edgePixelRatio: Double
    var meanGradient: Double
    var meanCoverageSpread: Double
  }

  private func fidelityProbeCommands() -> [FrameCommand] {
    [
      .rect(
        CGRect(x: 0, y: 0, width: 380, height: 90),
        color: 0xF6_EE_DB_FF,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 12, y: 18),
        text: "illili |||| HHHH WWWM",
        foreground: 0x18_22_2A_FF,
        background: 0xF6_EE_DB_FF,
        attributes: [],
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 12, y: 48),
        text: "warning: QuartzCore pcm missing",
        foreground: 0x18_22_2A_FF,
        background: 0xF6_EE_DB_FF,
        attributes: [],
        source: .terminal),
    ]
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw XCTSkip("failed to decode renderer PNG")
    }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: bitmapInfo)
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RGBAImage(width: width, height: height, bytes: bytes)
  }

  private func fidelityMetrics(
    image: RGBAImage,
    crop: CGRect,
    background: (r: UInt8, g: UInt8, b: UInt8),
    foreground: (r: UInt8, g: UInt8, b: UInt8)
  ) -> FidelityMetrics {
    let minX = max(0, Int(floor(crop.minX)))
    let maxX = min(image.width, Int(ceil(crop.maxX)))
    let minY = max(0, Int(floor(crop.minY)))
    let maxY = min(image.height, Int(ceil(crop.maxY)))
    let bgLum = luminance(r: background.r, g: background.g, b: background.b)

    var inkMass = 0.0
    var edgePixels = 0
    var inkPixels = 0
    var gradientTotal = 0.0
    var gradientCount = 0
    var coverageSpreadTotal = 0.0
    var coverageSpreadCount = 0

    func inkAt(x: Int, y: Int) -> Double {
      let offset = (y * image.width + x) * 4
      let lum = luminance(
        r: image.bytes[offset],
        g: image.bytes[offset + 1],
        b: image.bytes[offset + 2])
      return max(0, bgLum - lum)
    }

    for y in minY..<maxY {
      for x in minX..<maxX {
        let offset = (y * image.width + x) * 4
        let ink = inkAt(x: x, y: y)
        inkMass += ink
        if ink > 2 {
          inkPixels += 1
          let coverageR = channelCoverage(
            value: image.bytes[offset],
            background: background.r,
            foreground: foreground.r)
          let coverageG = channelCoverage(
            value: image.bytes[offset + 1],
            background: background.g,
            foreground: foreground.g)
          let coverageB = channelCoverage(
            value: image.bytes[offset + 2],
            background: background.b,
            foreground: foreground.b)
          let maximumCoverage = max(coverageR, coverageG, coverageB)
          let minimumCoverage = min(coverageR, coverageG, coverageB)
          coverageSpreadTotal += maximumCoverage - minimumCoverage
          coverageSpreadCount += 1
        }
        if ink > 2 && ink < 120 {
          edgePixels += 1
        }
        if x + 1 < maxX {
          let gradient = abs(ink - inkAt(x: x + 1, y: y))
          if gradient > 2 {
            gradientTotal += gradient
            gradientCount += 1
          }
        }
      }
    }

    return FidelityMetrics(
      inkMass: inkMass,
      edgePixelRatio: inkPixels == 0 ? 0 : Double(edgePixels) / Double(inkPixels),
      meanGradient: gradientCount == 0 ? 0 : gradientTotal / Double(gradientCount),
      meanCoverageSpread: coverageSpreadCount == 0
        ? 0 : coverageSpreadTotal / Double(coverageSpreadCount))
  }

  private func channelCoverage(value: UInt8, background: UInt8, foreground: UInt8) -> Double {
    let range = Double(background) - Double(foreground)
    guard abs(range) > 0.0001 else { return 0 }
    return max(0, min(1, (Double(background) - Double(value)) / range))
  }

  private func lumaDiffMetrics(
    lhs: RGBAImage,
    rhs: RGBAImage,
    crop: CGRect,
    threshold: UInt8
  ) -> LumaDiffMetrics {
    XCTAssertEqual(lhs.width, rhs.width)
    XCTAssertEqual(lhs.height, rhs.height)
    let minX = max(0, Int(floor(crop.minX)))
    let maxX = min(lhs.width, Int(ceil(crop.maxX)))
    let minY = max(0, Int(floor(crop.minY)))
    let maxY = min(lhs.height, Int(ceil(crop.maxY)))
    let width = max(0, maxX - minX)
    let height = max(0, maxY - minY)
    guard width > 0, height > 0 else {
      return LumaDiffMetrics(pixelRatioOverThreshold: 0, largestComponentArea: 0)
    }

    var mask = [Bool](repeating: false, count: width * height)
    var overThreshold = 0
    for y in 0..<height {
      for x in 0..<width {
        let imageX = minX + x
        let imageY = minY + y
        let offset = (imageY * lhs.width + imageX) * 4
        let lhsLuma = luminance(
          r: lhs.bytes[offset],
          g: lhs.bytes[offset + 1],
          b: lhs.bytes[offset + 2])
        let rhsLuma = luminance(
          r: rhs.bytes[offset],
          g: rhs.bytes[offset + 1],
          b: rhs.bytes[offset + 2])
        if abs(lhsLuma - rhsLuma) >= Double(threshold) {
          mask[y * width + x] = true
          overThreshold += 1
        }
      }
    }

    var visited = [Bool](repeating: false, count: mask.count)
    var largestComponent = 0
    for y in 0..<height {
      for x in 0..<width {
        let index = y * width + x
        guard mask[index], !visited[index] else { continue }
        visited[index] = true
        var stack = [(x, y)]
        var area = 0
        while let (cx, cy) = stack.popLast() {
          area += 1
          let neighbors = [
            (cx + 1, cy),
            (cx - 1, cy),
            (cx, cy + 1),
            (cx, cy - 1),
          ]
          for (nx, ny) in neighbors where nx >= 0 && nx < width && ny >= 0 && ny < height {
            let neighborIndex = ny * width + nx
            guard mask[neighborIndex], !visited[neighborIndex] else { continue }
            visited[neighborIndex] = true
            stack.append((nx, ny))
          }
        }
        largestComponent = max(largestComponent, area)
      }
    }

    return LumaDiffMetrics(
      pixelRatioOverThreshold: Double(overThreshold) / Double(width * height),
      largestComponentArea: largestComponent)
  }

  private func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
    0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
  }

  private func renderDecorationProbe(
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32? = nil
  ) throws -> Data {
    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 420,
        pixelHeight: 96,
        scale: 1))
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 420, height: 96), color: 0x10_10_10_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 24, y: 32),
        text: "Decorations",
        foreground: 0xEE_EE_EE_FF,
        background: 0x10_10_10_FF,
        attributes: attributes,
        source: .terminal,
        underlineStyle: underlineStyle,
        underlineColor: underlineColor),
    ]
    XCTAssertTrue(renderer.render(commands, damage: .full))
    return try XCTUnwrap(renderer.pngData)
  }

  private func cpuSingleSampleMask(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint
  ) -> [UInt8] {
    GlyphCurveCPUOracle.rasterizeCoverage(
      outline: outline,
      width: width,
      height: height,
      samplesPerAxis: 1
    ) { x, row, fx, fy in
      CGPoint(
        x: Double(origin.x) + Double(x) + fx,
        y: Double(origin.y) + Double(height - 1 - row) + fy)
    }.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
  }

  private struct MaskComparison {
    var mismatchedPixels: Int
    var allowedMismatches: Int
    var maxDelta: Int
  }

  private func compare(expected: [UInt8], actual: [UInt8]) -> MaskComparison {
    XCTAssertEqual(actual.count, expected.count)
    var mismatchedPixels = 0
    var maxDelta = 0
    for index in expected.indices {
      let delta = abs(Int(actual[index]) - Int(expected[index]))
      if delta > 3 {
        mismatchedPixels += 1
        maxDelta = max(maxDelta, delta)
      }
    }
    return MaskComparison(
      mismatchedPixels: mismatchedPixels,
      // Slash/backslash can land exactly on the sample line in the tighter
      // renderer mask snapshot; keep the same 5-pixel edge-tie floor recorded
      // for the M1 safe-math oracle while preserving the 1% cap for larger masks.
      allowedMismatches: max(5, Int((Double(expected.count) * 0.01).rounded(.up))),
      maxDelta: maxDelta)
  }

  private func writeArtifacts(
    scalarValue: Int,
    width: Int,
    height: Int,
    expected: [UInt8],
    actual: [UInt8]
  ) {
    try? FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
    let diff = zip(expected, actual).map { UInt8(abs(Int($0) - Int($1))) }
    let name = "U+\(String(format: "%04X", scalarValue))"
    try? grayPNG(width: width, height: height, bytes: expected)?
      .write(to: artifactRoot.appendingPathComponent("\(name).expected.png"))
    try? grayPNG(width: width, height: height, bytes: actual)?
      .write(to: artifactRoot.appendingPathComponent("\(name).actual.png"))
    try? grayPNG(width: width, height: height, bytes: diff)?
      .write(to: artifactRoot.appendingPathComponent("\(name).diff.png"))
  }

  private func grayPNG(width: Int, height: Int, bytes: [UInt8]) -> Data? {
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    guard
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }
    return PNGEncoder.encode(image)
  }
}
