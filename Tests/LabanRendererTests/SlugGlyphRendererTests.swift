import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

final class SlugGlyphCorrectnessTests: XCTestCase {
  private let gammaProbe = "Hglo08B/N"

  func testReferenceCoveragePreservesCPUOracleShapeForPrintableASCII() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(SlugGlyphRenderer(fontAtlas: FontAtlas(pointSize: 14)))
    let scalars = (0x21...0x7E).compactMap(Unicode.Scalar.init)

    for scalar in scalars {
      let outline = try XCTUnwrap(renderer.referenceOutline(for: scalar))
      let region = coverageRegion(for: outline)
      let cpu = GlyphCurveCPUOracle.rasterizeCoverage(
        outline: outline,
        width: region.width,
        height: region.height,
        samplesPerAxis: 4
      ) { x, row, fx, fy in
        CGPoint(
          x: Double(region.origin.x) + Double(x) + fx,
          y: Double(region.origin.y) + Double(region.height - 1 - row) + fy)
      }.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }

      let gpu = try XCTUnwrap(
        renderer.coverageMask(
          for: scalar,
          origin: region.origin,
          width: region.width,
          height: region.height),
        "Production Slug render failed for \(scalar)")
      XCTAssertEqual(gpu.count, cpu.count)

      var hardFalseNegatives = 0
      var hardFalsePositives = 0
      var gpuArea = 0
      var cpuArea = 0
      var gpuEdgePixels = 0
      for index in cpu.indices {
        let cpuByte = Int(cpu[index])
        let gpuByte = Int(gpu[index])
        cpuArea += cpuByte
        gpuArea += gpuByte
        if cpuByte >= 245 && gpuByte < 128 { hardFalseNegatives += 1 }
        if cpuByte <= 10 && gpuByte > 128 { hardFalsePositives += 1 }
        if gpuByte > 4 && gpuByte < 251 { gpuEdgePixels += 1 }
      }
      let allowedHard = max(1, Int((Double(cpu.count) * 0.005).rounded(.up)))
      XCTAssertLessThanOrEqual(
        hardFalseNegatives,
        allowedHard,
        "\(scalar) has \(hardFalseNegatives) solid CPU pixels missing in Slug coverage")
      XCTAssertLessThanOrEqual(
        hardFalsePositives,
        allowedHard,
        "\(scalar) has \(hardFalsePositives) exterior CPU pixels filled by Slug coverage")
      let relativeAreaDelta = abs(Double(gpuArea - cpuArea)) / max(1, Double(cpuArea))
      XCTAssertLessThan(
        relativeAreaDelta,
        0.30,
        "\(scalar) Slug coverage area drift \(relativeAreaDelta)")
      XCTAssertGreaterThan(gpuEdgePixels, 0, "\(scalar) must retain antialiased edge pixels")
    }
  }

  func testSameGlyphAtMultiplePointSizesReusesReferenceGeometry() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 9),
        pixelWidth: 240,
        pixelHeight: 120,
        scale: 1))
    renderer.waitForFrameCompletion = true

    let command = { (size: CGFloat) -> [FrameCommand] in
      [
        .rect(
          CGRect(x: 0, y: 0, width: 240, height: 120),
          color: 0x1010_10ff,
          source: .terminal),
        .glyphRun(
          origin: CGPoint(x: 20, y: 40),
          text: "A",
          foreground: 0xffff_ffff,
          background: 0x0000_0000,
          attributes: [],
          source: .terminal),
      ]
    }

    XCTAssertTrue(renderer.render(command(9), damage: .full))
    let entriesAfterFirstSize = renderer.geometryEntryBuildCount
    let uploadsAfterFirstSize = renderer.geometryBufferUploadCount
    XCTAssertEqual(entriesAfterFirstSize, 1)
    XCTAssertEqual(uploadsAfterFirstSize, 1)

    for size in [CGFloat(14), CGFloat(28)] {
      let atlas = renderer.fontAtlas.withPointSize(size)
      renderer.reconfigureFonts(fontAtlas: atlas)
      XCTAssertTrue(renderer.render(command(size), damage: .full))
      XCTAssertEqual(renderer.geometryEntryBuildCount, entriesAfterFirstSize)
      XCTAssertEqual(renderer.geometryBufferUploadCount, uploadsAfterFirstSize)
    }
  }

  func testGestureZoomScalesRenderedPixelsWithoutRebuildingGeometry() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 360,
        pixelHeight: 180,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 360, height: 180), color: 0x0000_00FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 20, y: 36),
        text: "H",
        foreground: 0xFFFF_FFFF,
        background: 0x0000_00FF,
        attributes: [],
        source: .terminal),
    ]

    XCTAssertTrue(renderer.render(commands, damage: .full))
    let unzoomedImage = try decodeRGBA(try XCTUnwrap(renderer.pngData))
    let unzoomedBounds = try XCTUnwrap(nonBackgroundBounds(unzoomedImage))
    let unzoomedDiagnostics = renderer.zoomDiagnostics
    let geometryEntries = renderer.geometryEntryBuildCount
    let geometryUploads = renderer.geometryBufferUploadCount

    renderer.setGestureZoom(1.5, anchor: .zero)
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let zoomedImage = try decodeRGBA(try XCTUnwrap(renderer.pngData))
    let zoomedBounds = try XCTUnwrap(nonBackgroundBounds(zoomedImage))
    let zoomedDiagnostics = renderer.zoomDiagnostics

    XCTAssertEqual(renderer.geometryEntryBuildCount, geometryEntries)
    XCTAssertEqual(renderer.geometryBufferUploadCount, geometryUploads)
    XCTAssertGreaterThan(zoomedBounds.height, unzoomedBounds.height * 1.35)
    XCTAssertEqual(zoomedDiagnostics.curveBufferBuildCount, geometryEntries)
    XCTAssertEqual(zoomedDiagnostics.geometryBufferUploadCount, geometryUploads)
    XCTAssertEqual(zoomedDiagnostics.glyphFontSizes, unzoomedDiagnostics.glyphFontSizes)
    XCTAssertEqual(zoomedDiagnostics.quadHeights.count, 1)
    XCTAssertEqual(unzoomedDiagnostics.quadHeights.count, 1)
    XCTAssertEqual(
      Double(zoomedDiagnostics.quadHeights[0]),
      Double(unzoomedDiagnostics.quadHeights[0]) * 1.5,
      accuracy: 1.0)
  }

  func testRenderedFrameProducesDecodablePNG() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 320,
        pixelHeight: 120,
        scale: 1))
    renderer.waitForFrameCompletion = true

    XCTAssertTrue(
      renderer.render(
        [
          .rect(
            CGRect(x: 0, y: 0, width: 320, height: 120),
            color: 0x1010_10ff,
            source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 12, y: 32),
            text: "Slug ABC123",
            foreground: 0xffff_ffff,
            background: 0x0000_0000,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    let png = try XCTUnwrap(renderer.pngData)
    let source = CGImageSourceCreateWithData(png as CFData, nil)
    let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    XCTAssertNotNil(image)
  }

  func testSlugCompositesCoverageInLinearLight() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: SlugGlyphRenderer.referencePointSize),
        pixelWidth: 360,
        pixelHeight: 120,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false

    XCTAssertTrue(
      renderer.render(
        [
          .rect(CGRect(x: 0, y: 0, width: 360, height: 120), color: 0x0000_00FF, source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 8, y: 24),
            text: gammaProbe,
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    let image = try decodeRGBA(try XCTUnwrap(renderer.pngData))

    var outputPartials: [Double] = []
    for i in stride(from: 0, to: image.bytes.count, by: 4) {
      let v = Int(image.bytes[i])
      if v > 4, v < 251 { outputPartials.append(Double(v)) }
    }
    XCTAssertGreaterThan(outputPartials.count, 80, "probe must produce AA edge pixels")

    var gammaExpected: [Double] = []
    var naiveExpected: [Double] = []
    for scalar in gammaProbe.unicodeScalars {
      let outline = try XCTUnwrap(renderer.referenceOutline(for: scalar))
      let region = coverageRegion(for: outline)
      let coverage = try XCTUnwrap(
        renderer.coverageMask(
          for: scalar,
          origin: region.origin,
          width: region.width,
          height: region.height))
      for byte in coverage where byte > 4 && byte < 251 {
        let c = Double(byte) / 255
        gammaExpected.append(srgbEncode(c) * 255)
        naiveExpected.append(c * 255)
      }
    }
    XCTAssertGreaterThan(gammaExpected.count, 80, "coverage masks must have AA edge pixels")

    let meanOutput = mean(outputPartials)
    let meanGamma = mean(gammaExpected)
    let meanNaive = mean(naiveExpected)
    XCTAssertGreaterThan(meanGamma - meanNaive, 10)
    XCTAssertGreaterThan(
      meanOutput,
      meanNaive + 0.5 * (meanGamma - meanNaive),
      "Slug edges are not on the gamma-correct side "
        + "(output \(meanOutput), naive \(meanNaive), gamma \(meanGamma))")
  }

  func testSlugClearColorMatchesTerminalBackgroundThroughSRGBTarget() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 96,
        pixelHeight: 64,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    let cream: UInt32 = 0xFBF3_DBFF

    XCTAssertTrue(
      renderer.render(
        [
          .rect(CGRect(x: 24, y: 16, width: 16, height: 16), color: cream, source: .terminal)
        ],
        damage: .full))
    let image = try decodeRGBA(try XCTUnwrap(renderer.pngData))
    let pixel = image.pixel(x: 0, y: 0)
    XCTAssertLessThanOrEqual(abs(Int(pixel.r) - 0xFB), 2)
    XCTAssertLessThanOrEqual(abs(Int(pixel.g) - 0xF3), 2)
    XCTAssertLessThanOrEqual(abs(Int(pixel.b) - 0xDB), 2)
  }

  func testSlugZoomOutMarginMatchesThemeBackground() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 300,
        pixelHeight: 300,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    let cream: UInt32 = 0xFBF3_DBFF
    let full: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 300, height: 300), color: cream, source: .terminal)
    ]

    XCTAssertTrue(renderer.render(full, damage: .full))
    let rendered = try decodeRGBA(try XCTUnwrap(renderer.pngData)).pixel(x: 0, y: 0)

    renderer.setGestureZoom(0.5, anchor: CGPoint(x: 150, y: 150))
    XCTAssertTrue(renderer.render(full, damage: .full))
    let cleared = try decodeRGBA(try XCTUnwrap(renderer.pngData)).pixel(x: 0, y: 0)

    XCTAssertEqual(Int(cleared.r), Int(rendered.r), accuracy: 4)
    XCTAssertEqual(Int(cleared.g), Int(rendered.g), accuracy: 4)
    XCTAssertEqual(Int(cleared.b), Int(rendered.b), accuracy: 4)
    XCTAssertEqual(Int(cleared.b), 0xDB, accuracy: 6)
  }

  func testSlugSelectionBackgroundSurvivesTextCellBackground() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let atlas = FontAtlas(pointSize: 18)
    let cellWidth = atlas.cellSize.width
    let cellHeight = atlas.cellSize.height
    let pixelWidth = Int(ceil(cellWidth * 3))
    let pixelHeight = Int(ceil(cellHeight))
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: atlas,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    let base: UInt32 = 0x1010_10FF
    let selection: UInt32 = 0xF080_2080

    XCTAssertTrue(
      renderer.render(
        [
          .rect(
            CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)),
            color: base,
            source: .terminal),
          .selection(CGRect(x: 0, y: 0, width: cellWidth * 2, height: cellHeight), color: selection),
          .glyphRun(
            origin: .zero,
            text: "i",
            foreground: 0xFFFF_FFFF,
            background: base,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    let image = try decodeRGBA(try XCTUnwrap(renderer.pngData))
    let selectedEmpty = image.pixel(x: Int(cellWidth * 1.5), y: pixelHeight / 2)
    let selectedTextBackground = image.pixel(x: Int(cellWidth * 0.85), y: pixelHeight / 2)
    let unselectedBackground = image.pixel(x: min(pixelWidth - 1, Int(cellWidth * 2.5)), y: pixelHeight / 2)

    XCTAssertPixel(selectedTextBackground, matches: selectedEmpty, tolerance: 4)
    XCTAssertPixel(selectedTextBackground, differsFrom: unselectedBackground, tolerance: 12)
  }

  func testSlugRendersColorEmojiFallbackPixels() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let image = try renderProbeText("🙂", width: 160, height: 120)
    let bounds = try XCTUnwrap(nonBackgroundBounds(image))
    XCTAssertGreaterThan(bounds.width * bounds.height, CGFloat(100))
    XCTAssertGreaterThan(chromaticPixelCount(image), 10)
  }

  func testSlugRendersCJKViaFallbackCascade() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let image = try renderProbeText("漢字かな한글", width: 360, height: 140)
    let bounds = try XCTUnwrap(nonBackgroundBounds(image))
    XCTAssertGreaterThan(bounds.width, 40)
    XCTAssertGreaterThan(bounds.height, 10)
  }

  func testSlugRendererReportsEffectiveSubpixelLayout() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 96,
        pixelHeight: 64,
        scale: 2))

    renderer.setSubpixelLayout(.rgbStripe)
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .rgbStripe)
    XCTAssertEqual(renderer.rendererStatus.vectorSubpixelLayout, "rgbStripe")

    XCTAssertTrue(renderer.setDisplayDownsampled(true))
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .grayscale)
    XCTAssertEqual(renderer.rendererStatus.vectorSubpixelLayout, "grayscale")

    XCTAssertFalse(renderer.setDisplayDownsampled(true))
    XCTAssertTrue(renderer.setDisplayDownsampled(false))
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .rgbStripe)

    XCTAssertTrue(renderer.resize(pixelWidth: 96, pixelHeight: 64, scale: 1.5))
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .grayscale)
  }

  func testSlugSubpixelLayoutChangesRenderedRGBCoverage() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let grayscale = try renderSubpixelProbe(layout: .grayscale)
    let rgb = try renderSubpixelProbe(layout: .rgbStripe)

    let grayscaleSpread = channelSpreadStats(grayscale)
    let rgbSpread = channelSpreadStats(rgb)
    XCTAssertGreaterThan(grayscaleSpread.edgePixels, 120, "probe must include AA edges")
    XCTAssertGreaterThan(rgbSpread.edgePixels, 120, "probe must include AA edges")
    XCTAssertLessThanOrEqual(
      grayscaleSpread.fringePixels,
      4,
      "grayscale should not introduce per-channel coverage")
    XCTAssertGreaterThan(
      rgbSpread.fringePixels,
      max(24, grayscaleSpread.fringePixels * 8),
      "rgbStripe should produce visible per-channel coverage")
    XCTAssertGreaterThan(
      rgbSpread.meanSpread,
      grayscaleSpread.meanSpread + 6,
      "rgbStripe should materially differ from grayscale channel coverage")
  }

  func testSlugSubpixelAreaWidthAffectsRenderedAA() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let centers = SIMD3<Float>(-0.15, 0, 0.15)
    let narrow = VectorSubpixelLayout(
      name: "narrowOverlap",
      areas: .horizontalOverlap(centerOffsets: centers, width: 0.36))
    let wide = VectorSubpixelLayout(
      name: "wideOverlap",
      areas: .horizontalOverlap(centerOffsets: centers, width: 0.92))

    let narrowImage = try renderSubpixelProbe(layout: narrow)
    let wideImage = try renderSubpixelProbe(layout: wide)
    let narrowSpread = channelSpreadStats(narrowImage)
    let wideSpread = channelSpreadStats(wideImage)
    let meanDiff = meanAbsoluteRGBDiff(narrowImage, wideImage)

    XCTAssertGreaterThan(
      meanDiff,
      0.01,
      "layouts with identical centers but different sample-area widths must not render identically")
    XCTAssertLessThan(
      wideSpread.meanSpread,
      narrowSpread.meanSpread,
      "wider overlapping sample areas should reduce color spread "
        + "(wide \(wideSpread.meanSpread), narrow \(narrowSpread.meanSpread))")
  }

  func testSlugTextWeightThickensRenderedInk() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let key = VectorTextWeightSettings.defaultsKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    let lightInk = try renderWeightProbeInk(weight: 0)
    let heavyInk = try renderWeightProbeInk(weight: 1)
    XCTAssertGreaterThan(
      heavyInk,
      lightInk * 1.05,
      "text weight 1 must lay down more ink than weight 0 (light \(lightInk), heavy \(heavyInk))")
  }

  /// Renders dark-on-light text at the given weight and returns total ink
  /// (how far the foreground pixels darken below the background). The weight
  /// setting drives the Slug stem-darkening exponent, so a higher weight must
  /// produce more ink.
  private func renderWeightProbeInk(weight: Double) throws -> Double {
    let lightBg: UInt32 = 0xF6_EE_DB_FF
    let darkFg: UInt32 = 0x18_22_2A_FF
    VectorTextWeightSettings.setCurrent(weight)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 16),
        pixelWidth: 360,
        pixelHeight: 120,
        scale: 2))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    renderer.refreshTextWeight()
    XCTAssertTrue(
      renderer.render(
        [
          .rect(CGRect(x: 0, y: 0, width: 180, height: 60), color: lightBg, source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 10, y: 16),
            text: "weight",
            foreground: darkFg,
            background: lightBg,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    let image = try decodeRGBA(try XCTUnwrap(renderer.pngData))
    let bgLuma = (Int(0xF6) + Int(0xEE) + Int(0xDB)) / 3
    var ink = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = image.pixel(x: x, y: y)
        let luma = (Int(pixel.r) + Int(pixel.g) + Int(pixel.b)) / 3
        ink += max(0, bgLuma - luma)
      }
    }
    return Double(ink)
  }

  func testSlugDecorationStylesChangeOutput() throws {
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
        "decoration style \(underlineStyle) attributes \(attributes) must affect Slug output")
    }
  }

  func testM2VisualSpotCheckArtifactWhenRequested() throws {
    guard let artifactRoot = ProcessInfo.processInfo.environment["LABAN_SLUG_GLYPH_ARTIFACTS"],
      !artifactRoot.isEmpty
    else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let root = URL(fileURLWithPath: artifactRoot, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 720,
        pixelHeight: 180,
        scale: 2))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    XCTAssertTrue(
      renderer.render(
        [
          .rect(CGRect(x: 0, y: 0, width: 360, height: 90), color: 0x1010_10FF, source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 12, y: 18),
            text: "Slug glyph renderer 14pt",
            foreground: 0xFFFF_FFFF,
            background: 0x0000_0000,
            attributes: [],
            source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 12, y: 46),
            text: "Analytic Slug coverage, grayscale AA",
            foreground: 0xB7D7_FFFF,
            background: 0x0000_0000,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    let png = try XCTUnwrap(renderer.pngData)
    let pngURL = root.appendingPathComponent("slug-glyph-m2-14pt.png")
    try png.write(to: pngURL)
    let manifest: [String: Any] = [
      "renderer": "slugGlyph",
      "pointSize": 14,
      "scale": 2,
      "png": pngURL.lastPathComponent,
    ]
    let manifestData = try JSONSerialization.data(
      withJSONObject: manifest,
      options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: root.appendingPathComponent("manifest.json"))
  }

  private func coverageRegion(
    for outline: GlyphCurveOutline
  ) -> (origin: CGPoint, width: Int, height: Int) {
    let pad: CGFloat = 2
    let minX = floor(outline.bounds.minX) - pad
    let maxX = ceil(outline.bounds.maxX) + pad
    let minY = floor(outline.bounds.minY) - pad
    let maxY = ceil(outline.bounds.maxY) + pad
    return (
      CGPoint(x: minX, y: minY),
      max(1, Int(maxX - minX)),
      max(1, Int(maxY - minY))
    )
  }

  private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
  }

  private func srgbEncode(_ c: Double) -> Double {
    c <= 0.003_130_8 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
  }

  private func renderProbeText(_ text: String, width: Int, height: Int) throws -> RGBAImage {
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 18),
        pixelWidth: width,
        pixelHeight: height,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    XCTAssertTrue(
      renderer.render(
        [
          .rect(
            CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            color: 0x0000_00FF,
            source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 12, y: 32),
            text: text,
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    return try decodeRGBA(try XCTUnwrap(renderer.pngData))
  }

  private func renderDecorationProbe(
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32? = nil
  ) throws -> Data {
    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 420,
        pixelHeight: 96,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
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

  private func renderSubpixelProbe(layout: VectorSubpixelLayout) throws -> RGBAImage {
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 16),
        pixelWidth: 720,
        pixelHeight: 180,
        scale: 2))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    renderer.setSubpixelLayout(layout)

    XCTAssertTrue(
      renderer.render(
        [
          .rect(CGRect(x: 0, y: 0, width: 360, height: 90), color: 0x0000_00FF, source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 10, y: 22),
            text: "HHHHmmmmWWWW1111",
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    return try decodeRGBA(try XCTUnwrap(renderer.pngData))
  }

  private func channelSpreadStats(_ image: RGBAImage) -> (
    edgePixels: Int, fringePixels: Int, meanSpread: Double
  ) {
    var edgePixels = 0
    var fringePixels = 0
    var spreadSum = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = image.pixel(x: x, y: y)
        let high = max(Int(pixel.r), Int(pixel.g), Int(pixel.b))
        let low = min(Int(pixel.r), Int(pixel.g), Int(pixel.b))
        let luminance = (Int(pixel.r) + Int(pixel.g) + Int(pixel.b)) / 3
        guard luminance > 4, luminance < 251 else { continue }
        edgePixels += 1
        let spread = high - low
        spreadSum += spread
        if spread > 8 {
          fringePixels += 1
        }
      }
    }
    return (
      edgePixels,
      fringePixels,
      edgePixels == 0 ? 0 : Double(spreadSum) / Double(edgePixels)
    )
  }

  private func meanAbsoluteRGBDiff(_ lhs: RGBAImage, _ rhs: RGBAImage) -> Double {
    guard lhs.width == rhs.width, lhs.height == rhs.height, lhs.bytes.count == rhs.bytes.count
    else { return 0 }
    var total = 0
    var samples = 0
    for i in stride(from: 0, to: lhs.bytes.count, by: 4) {
      total += abs(Int(lhs.bytes[i]) - Int(rhs.bytes[i]))
      total += abs(Int(lhs.bytes[i + 1]) - Int(rhs.bytes[i + 1]))
      total += abs(Int(lhs.bytes[i + 2]) - Int(rhs.bytes[i + 2]))
      samples += 3
    }
    return samples == 0 ? 0 : Double(total) / Double(samples)
  }

  private func nonBackgroundBounds(_ image: RGBAImage) -> CGRect? {
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = image.pixel(x: x, y: y)
        let luminance = (Int(pixel.r) + Int(pixel.g) + Int(pixel.b)) / 3
        guard luminance > 8 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(
      x: CGFloat(minX),
      y: CGFloat(minY),
      width: CGFloat(maxX - minX + 1),
      height: CGFloat(maxY - minY + 1))
  }

  private func chromaticPixelCount(_ image: RGBAImage) -> Int {
    var count = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = image.pixel(x: x, y: y)
        let high = max(Int(pixel.r), Int(pixel.g), Int(pixel.b))
        let low = min(Int(pixel.r), Int(pixel.g), Int(pixel.b))
        if high > 20, high - low > 20 {
          count += 1
        }
      }
    }
    return count
  }

  private func XCTAssertPixel(
    _ actual: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
    matches expected: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
    tolerance: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(Int(actual.r), Int(expected.r), accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(Int(actual.g), Int(expected.g), accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(Int(actual.b), Int(expected.b), accuracy: tolerance, file: file, line: line)
  }

  private func XCTAssertPixel(
    _ actual: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
    differsFrom expected: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
    tolerance: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let maxDelta = max(
      abs(Int(actual.r) - Int(expected.r)),
      abs(Int(actual.g) - Int(expected.g)),
      abs(Int(actual.b) - Int(expected.b)))
    XCTAssertGreaterThan(maxDelta, tolerance, file: file, line: line)
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
      let offset = (y * width + x) * 4
      return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw XCTSkip("failed to decode renderer PNG") }
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
}
