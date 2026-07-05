import CoreGraphics
import CoreText
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

final class SlugGlyphAAFidelityTests: XCTestCase {
  private let neutralBackground: UInt32 = 0xFF_FF_FF_FF
  private let neutralForeground: UInt32 = 0x00_00_00_FF
  private let themeBackground: UInt32 = 0xF6_EE_DB_FF
  private let themeForeground: UInt32 = 0x18_22_2A_FF
  private let vectorConvergenceFrames = 130
  private let probeLines = [
    "illili |||| HHHH WWWM",
    "0123456789 abcdef ABCDEF",
    "/\\vDN mwmW I1l |",
    "x/mcp/rpg/node_modules 501 10227",
  ]

  // MARK: - Grayscale envelope vs Software/CoreText

  func testSlugGrayscaleTracksSoftwareEnvelopeOnNeutralProbe() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 1200
    let pixelHeight = 320
    let crop = CGRect(x: 24, y: 18, width: 1152, height: 284)
    let commands = probeCommands(
      x: 12,
      y: 16,
      lineSpacing: 24,
      background: neutralBackground,
      foreground: neutralForeground)

    let software = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: pointSize),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale)
    XCTAssertTrue(software.render(commands, damage: .full))
    let softwareImage = try decodePNGToRGBA(try XCTUnwrap(software.pngData))
    let softwareMetrics = computeTextAAMetrics(
      image: softwareImage,
      crop: crop,
      background: neutralBackground,
      foreground: neutralForeground)

    let slug = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale))
    slug.waitForFrameCompletion = true
    slug.presentsToLayer = false
    slug.setSubpixelLayout(.grayscale)
    XCTAssertTrue(slug.render(commands, damage: .full))
    let slugImage = try decodePNGToRGBA(try XCTUnwrap(slug.pngData))
    let slugMetrics = computeTextAAMetrics(
      image: slugImage,
      crop: crop,
      background: neutralBackground,
      foreground: neutralForeground)

    XCTAssertGreaterThan(slugMetrics.edgePixels, 800)
    XCTAssertLessThan(
      abs(slugMetrics.inkMass - softwareMetrics.inkMass) / max(softwareMetrics.inkMass, 1),
      0.15)
    XCTAssertGreaterThanOrEqual(slugMetrics.meanGradient, softwareMetrics.meanGradient * 0.80)
    XCTAssertLessThanOrEqual(
      slugMetrics.edgePixelRatio,
      softwareMetrics.edgePixelRatio + 0.12)
    XCTAssertLessThanOrEqual(slugMetrics.meanEdgeChroma, 1.0)
  }

  func testSlugGrayscaleMatchesSoftwareCoreTextOnThemeProbe() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 920
    let pixelHeight = 228
    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)
    let commands = probeCommands(
      x: 12,
      y: 16,
      lineSpacing: 24,
      background: themeBackground,
      foreground: themeForeground)

    let software = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: pointSize),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale)
    XCTAssertTrue(software.render(commands, damage: .full))
    let softwareImage = try decodePNGToRGBA(try XCTUnwrap(software.pngData))
    let softwareMetrics = computeTextAAMetrics(
      image: softwareImage,
      crop: crop,
      background: themeBackground,
      foreground: themeForeground)

    let slug = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale))
    slug.waitForFrameCompletion = true
    slug.presentsToLayer = false
    slug.setSubpixelLayout(.grayscale)
    XCTAssertTrue(slug.render(commands, damage: .full))
    let slugImage = try decodePNGToRGBA(try XCTUnwrap(slug.pngData))
    let slugMetrics = computeTextAAMetrics(
      image: slugImage,
      crop: crop,
      background: themeBackground,
      foreground: themeForeground)

    XCTAssertGreaterThan(slugMetrics.edgePixels, 600)
    XCTAssertLessThan(
      abs(slugMetrics.inkMass - softwareMetrics.inkMass) / max(softwareMetrics.inkMass, 1),
      0.18)
    XCTAssertGreaterThanOrEqual(slugMetrics.meanGradient, softwareMetrics.meanGradient * 0.75)
    XCTAssertLessThanOrEqual(
      slugMetrics.edgePixelRatio,
      softwareMetrics.edgePixelRatio + 0.15)
    XCTAssertLessThanOrEqual(slugMetrics.meanCoverageSpread, 0.05)
  }

  // MARK: - Gamma / linear-light behavior

  func testSlugGammaBehaviorStaysOnSoftwareAndLinearLightSide() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 14
    let scale: CGFloat = 1
    let gammaProbe = "Hglo08B/N"

    // Existing analytic gamma gate: partial pixels must be on the gamma-encoded side
    // of naive linear-space blending.
    let slug = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize),
        pixelWidth: 360,
        pixelHeight: 120,
        scale: scale))
    slug.waitForFrameCompletion = true
    slug.presentsToLayer = false
    slug.setSubpixelLayout(.grayscale)
    XCTAssertTrue(
      slug.render(
        [
          .rect(
            CGRect(x: 0, y: 0, width: 360, height: 120), color: 0x00_00_00_FF, source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 8, y: 24),
            text: gammaProbe,
            foreground: 0xFF_FF_FF_FF,
            background: 0x00_00_00_FF,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    let image = try decodePNGToRGBA(try XCTUnwrap(slug.pngData))

    var outputPartials: [Double] = []
    for i in stride(from: 0, to: image.bytes.count, by: 4) {
      let v = Int(image.bytes[i])
      if v > 4, v < 251 { outputPartials.append(Double(v)) }
    }
    XCTAssertGreaterThan(outputPartials.count, 80, "probe must produce AA edge pixels")

    var gammaExpected: [Double] = []
    var naiveExpected: [Double] = []
    for scalar in gammaProbe.unicodeScalars {
      let outline = try XCTUnwrap(slug.referenceOutline(for: scalar))
      let region = coverageRegion(for: outline)
      let coverage = try XCTUnwrap(
        slug.coverageMask(
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
      "Slug edges are not on the gamma-correct side")

    // Software envelope gate: Slug must not be visually washed out relative to native text.
    let crop = CGRect(x: 8, y: 8, width: 344, height: 104)
    let software = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: pointSize),
      pixelWidth: 360,
      pixelHeight: 120,
      scale: scale)
    XCTAssertTrue(
      software.render(
        [
          .rect(
            CGRect(x: 0, y: 0, width: 360, height: 120), color: 0x00_00_00_FF, source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 8, y: 24),
            text: gammaProbe,
            foreground: 0xFF_FF_FF_FF,
            background: 0x00_00_00_FF,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    let softwareImage = try decodePNGToRGBA(try XCTUnwrap(software.pngData))
    let softwareMetrics = computeTextAAMetrics(
      image: softwareImage,
      crop: crop,
      background: 0x00_00_00_FF,
      foreground: 0xFF_FF_FF_FF)
    XCTAssertLessThan(abs(mean(outputPartials) - softwareMetrics.meanPartialLuma), 30.0)
    XCTAssertGreaterThan(mean(outputPartials), meanNaive + 0.5 * (meanGamma - meanNaive))
  }

  // MARK: - Subpixel compositing vs Vector reference

  func testSlugSubpixelCompositingTracksVectorOnColoredTheme() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 920
    let pixelHeight = 228
    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)
    let commands = probeCommands(
      x: 12,
      y: 16,
      lineSpacing: 24,
      background: themeBackground,
      foreground: themeForeground)

    let slug = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale))
    slug.waitForFrameCompletion = true
    slug.presentsToLayer = false
    slug.setSubpixelLayout(.calibratedRGB)
    XCTAssertTrue(slug.render(commands, damage: .full))
    let slugImage = try decodePNGToRGBA(try XCTUnwrap(slug.pngData))
    let slugMetrics = computeTextAAMetrics(
      image: slugImage,
      crop: crop,
      background: themeBackground,
      foreground: themeForeground)

    let vector = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize),
        sidebarFontAtlas: FontAtlas(pointSize: pointSize),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale))
    vector.setSubpixelLayout(.calibratedRGB)
    vector.waitForFrameCompletion = true
    for frame in 0..<vectorConvergenceFrames {
      XCTAssertTrue(vector.render(commands, damage: .full), "vector frame \(frame) failed")
    }
    let vectorImage = try decodePNGToRGBA(try XCTUnwrap(vector.pngData))
    let vectorMetrics = computeTextAAMetrics(
      image: vectorImage,
      crop: crop,
      background: themeBackground,
      foreground: themeForeground)

    XCTAssertLessThan(
      abs(slugMetrics.inkMass - vectorMetrics.inkMass) / max(vectorMetrics.inkMass, 1),
      0.15)
    XCTAssertLessThanOrEqual(
      slugMetrics.meanEdgeChroma,
      vectorMetrics.meanEdgeChroma * 1.20 + 2.0)
    XCTAssertLessThanOrEqual(
      slugMetrics.p95EdgeChroma,
      vectorMetrics.p95EdgeChroma * 1.25 + 4.0)
    XCTAssertGreaterThanOrEqual(slugMetrics.meanGradient, vectorMetrics.meanGradient * 0.80)
  }

  // MARK: - Slug subpixel acutance / fringing budget gates

  func testSlugCalibratedSubpixelImprovesAcutanceWithinFringingBudget() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 920
    let pixelHeight = 228
    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)
    let commands = probeCommands(
      x: 12,
      y: 16,
      lineSpacing: 24,
      background: themeBackground,
      foreground: themeForeground)

    let grayscaleMetrics = try slugMetrics(
      layout: .grayscale,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)
    let calibratedMetrics = try slugMetrics(
      layout: .calibratedRGB,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)

    XCTAssertGreaterThan(
      calibratedMetrics.meanMaxChannelGradient,
      grayscaleMetrics.meanMaxChannelGradient * 1.05,
      "calibrated subpixel must improve channel acutance over grayscale")
    XCTAssertLessThanOrEqual(
      calibratedMetrics.meanCoverageSpread,
      max(0.14, grayscaleMetrics.meanCoverageSpread * 10.0),
      "calibrated subpixel must stay within fringing budget")
  }

  func testSlugRGBStripeSubpixelImprovesAcutanceWithinFringingBudget() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 920
    let pixelHeight = 228
    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)
    let commands = probeCommands(
      x: 12,
      y: 16,
      lineSpacing: 24,
      background: themeBackground,
      foreground: themeForeground)

    let calibratedMetrics = try slugMetrics(
      layout: .calibratedRGB,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)
    let rgbStripeMetrics = try slugMetrics(
      layout: .rgbStripe,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)

    XCTAssertGreaterThan(
      rgbStripeMetrics.meanMaxChannelGradient,
      calibratedMetrics.meanMaxChannelGradient * 1.02,
      "rgbStripe subpixel must improve channel acutance over calibrated")
    XCTAssertLessThanOrEqual(
      rgbStripeMetrics.meanCoverageSpread,
      max(0.24, calibratedMetrics.meanCoverageSpread * 1.60 + 0.04),
      "rgbStripe subpixel must stay within fringing budget")
  }

  // MARK: - Native fidelity / fringing / phase regression gates

  /// Hard CI gate: slug grayscale must stay within a loose budget of the
  /// native macOS reference on a realistic terminal theme.
  func testSlugGrayscaleMeetsNativeFidelityBudget() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 920
    let pixelHeight = 228
    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)

    let software = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: pointSize),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale)
    XCTAssertTrue(
      software.render(
        probeCommands(
          x: 12,
          y: 16,
          lineSpacing: 24,
          background: themeBackground,
          foreground: themeForeground), damage: .full))
    let softwareImage = try decodePNGToRGBA(try XCTUnwrap(software.pngData))
    let softwareMetrics = computeTextAAMetrics(
      image: softwareImage,
      crop: crop,
      background: themeBackground,
      foreground: themeForeground)

    let slugMetrics = try slugMetrics(
      layout: .grayscale,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)

    let inkDelta =
      abs(slugMetrics.inkMass - softwareMetrics.inkMass)
      / max(softwareMetrics.inkMass, 1)
    XCTAssertLessThanOrEqual(inkDelta, 0.10, "ink mass delta vs native reference")
    XCTAssertGreaterThanOrEqual(
      slugMetrics.meanGradient,
      softwareMetrics.meanGradient * 0.90,
      "mean luma gradient vs native reference")
    XCTAssertGreaterThanOrEqual(
      slugMetrics.p99Gradient,
      softwareMetrics.p99Gradient * 0.85,
      "p99 luma gradient vs native reference")
    XCTAssertLessThanOrEqual(
      slugMetrics.edgePixelRatio,
      softwareMetrics.edgePixelRatio * 1.20,
      "edge pixel ratio vs native reference")
    XCTAssertLessThanOrEqual(
      slugMetrics.meanCoverageSpread,
      0.015,
      "grayscale must not introduce measurable color fringing")
  }

  /// Hard CI gate: slug calibrated subpixel must improve acutance over its own
  /// grayscale and stay inside a fringing budget. Phase-sweep ink mass must be
  /// stable because subpixel layout should not depend on fractional origin.
  func testSlugCalibratedHasLowFringingBudget() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 920
    let pixelHeight = 228
    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)

    let grayscaleMetrics = try slugMetrics(
      layout: .grayscale,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)
    let calibratedMetrics = try slugMetrics(
      layout: .calibratedRGB,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)

    XCTAssertGreaterThanOrEqual(
      calibratedMetrics.meanMaxChannelGradient,
      grayscaleMetrics.meanMaxChannelGradient * 1.05,
      "calibrated subpixel must improve channel acutance over grayscale")
    XCTAssertLessThanOrEqual(
      calibratedMetrics.meanCoverageSpread,
      0.12,
      "calibrated subpixel mean fringing budget")
    XCTAssertLessThanOrEqual(
      calibratedMetrics.p95CoverageSpread,
      0.50,
      "calibrated subpixel p95 fringing budget (loose; target 0.36)")

    var maxInkDelta = 0.0
    for shift in [0.25, 0.50, 0.75] {
      let shifted = try slugMetrics(
        layout: .calibratedRGB,
        pointSize: pointSize,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        xShiftPixels: shift,
        background: themeBackground,
        foreground: themeForeground,
        crop: crop)
      let inkDelta =
        abs(shifted.inkMass - calibratedMetrics.inkMass)
        / max(calibratedMetrics.inkMass, 1)
      maxInkDelta = max(maxInkDelta, inkDelta)
    }
    XCTAssertLessThanOrEqual(
      maxInkDelta,
      0.08,
      "calibrated subpixel ink mass must be stable across fractional phase")
  }

  /// Hard CI gate: grayscale rendering must not change shape metrics when the
  /// glyph origin is shifted by fractional pixels.
  func testSlugFractionalPhaseStability() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 18
    let scale: CGFloat = 2
    let pixelWidth = 920
    let pixelHeight = 228
    let crop = CGRect(x: 24, y: 18, width: 872, height: 188)

    let base = try slugMetrics(
      layout: .grayscale,
      pointSize: pointSize,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      background: themeBackground,
      foreground: themeForeground,
      crop: crop)

    var maxInkDelta = 0.0
    var maxMeanGradientDelta = 0.0
    var maxP99GradientDelta = 0.0
    for shift in [0.25, 0.50, 0.75] {
      let shifted = try slugMetrics(
        layout: .grayscale,
        pointSize: pointSize,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale,
        xShiftPixels: shift,
        background: themeBackground,
        foreground: themeForeground,
        crop: crop)
      maxInkDelta = max(
        maxInkDelta,
        abs(shifted.inkMass - base.inkMass) / max(base.inkMass, 1))
      maxMeanGradientDelta = max(
        maxMeanGradientDelta,
        abs(shifted.meanGradient - base.meanGradient) / max(base.meanGradient, 1))
      maxP99GradientDelta = max(
        maxP99GradientDelta,
        abs(shifted.p99Gradient - base.p99Gradient) / max(base.p99Gradient, 1))
    }
    XCTAssertLessThanOrEqual(maxInkDelta, 0.08, "ink mass stable across fractional phase")
    XCTAssertLessThanOrEqual(
      maxMeanGradientDelta,
      0.10,
      "mean gradient stable across fractional phase")
    XCTAssertLessThanOrEqual(
      maxP99GradientDelta,
      0.10,
      "p99 gradient stable across fractional phase")
  }

  /// Hard CI gate: every renderer must report its gamma/composite model so the
  /// fidelity report can normalize comparisons.
  func testSlugGammaPolicyIsReported() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(SlugGlyphRenderer(fontAtlas: FontAtlas(pointSize: 14)))
    XCTAssertEqual(
      renderer.rendererStatus.textCompositeModel,
      .linearLight,
      "slug renderer must report linear-light compositing")
  }

  // MARK: - Shape fidelity vs CPU oracle

  func testSlugCanDifferFromSoftwareWhenOutlineOracleIsBetter() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(SlugGlyphRenderer(fontAtlas: FontAtlas(pointSize: 14)))
    let strictScalars: [Unicode.Scalar] = [
      "I", "l", "1", "|", "H", "M", "W", "m", "n", "0", "8", "B",
      "/", "\\", "v", "N", "D", "O", "e", "g", "a", "s",
    ].compactMap { $0.unicodeScalars.first }

    var totalNormalizedError = 0.0
    var totalPixels = 0
    var gpuAreaSum = 0
    var cpuAreaSum = 0
    var totalFalseNegatives = 0
    var totalFalsePositives = 0
    var allowedHardTotal = 0

    for scalar in strictScalars {
      let outline = try XCTUnwrap(renderer.referenceOutline(for: scalar))
      let region = coverageRegion(for: outline)
      let cpu = GlyphCurveCPUOracle.rasterizeCoverage(
        outline: outline,
        width: region.width,
        height: region.height,
        samplesPerAxis: 8
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
          height: region.height))
      XCTAssertEqual(gpu.count, cpu.count)

      let allowedHard = max(1, Int((Double(cpu.count) * 0.005).rounded(.up)))
      allowedHardTotal += allowedHard
      var hardFalseNegatives = 0
      var hardFalsePositives = 0
      for index in cpu.indices {
        let cpuByte = Int(cpu[index])
        let gpuByte = Int(gpu[index])
        cpuAreaSum += cpuByte
        gpuAreaSum += gpuByte
        totalNormalizedError += Double(abs(gpuByte - cpuByte)) / 255.0
        totalPixels += 1
        if cpuByte >= 245 && gpuByte < 128 { hardFalseNegatives += 1 }
        if cpuByte <= 10 && gpuByte > 128 { hardFalsePositives += 1 }
      }
      totalFalseNegatives += hardFalseNegatives
      totalFalsePositives += hardFalsePositives
    }

    let normalizedMAE = totalPixels == 0 ? 0 : totalNormalizedError / Double(totalPixels)
    let relativeAreaDelta =
      cpuAreaSum == 0
      ? 0
      : abs(Double(gpuAreaSum - cpuAreaSum)) / Double(cpuAreaSum)

    XCTAssertLessThan(normalizedMAE, 0.08)
    XCTAssertLessThan(relativeAreaDelta, 0.15)
    XCTAssertLessThanOrEqual(totalFalseNegatives, allowedHardTotal)
    XCTAssertLessThanOrEqual(totalFalsePositives, allowedHardTotal)
  }

  // MARK: - Subpixel fallback policy

  func testSlugSubpixelFallbackPolicyKeepsGrayscaleOnDownsampledOrFractionalScale() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pointSize: CGFloat = 16
    let scale: CGFloat = 2
    let pixelWidth = 720
    let pixelHeight = 180
    let crop = CGRect(x: 10, y: 10, width: 700, height: 160)
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 360, height: 90), color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 10, y: 22),
        text: "HHHHmmmmWWWW1111",
        foreground: 0xFF_FF_FF_FF,
        background: 0x00_00_00_FF,
        attributes: [],
        source: .terminal),
    ]

    func metrics(atScale: CGFloat, downsampled: Bool) throws -> TestTextAAMetrics {
      let renderer = try XCTUnwrap(
        SlugGlyphRenderer(
          fontAtlas: FontAtlas(pointSize: pointSize),
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
          scale: atScale))
      renderer.waitForFrameCompletion = true
      renderer.presentsToLayer = false
      renderer.setSubpixelLayout(.rgbStripe)
      _ = renderer.setDisplayDownsampled(downsampled)
      XCTAssertEqual(renderer.effectiveSubpixelLayout, .grayscale)
      XCTAssertTrue(renderer.render(commands, damage: .full))
      let image = try decodePNGToRGBA(try XCTUnwrap(renderer.pngData))
      return computeTextAAMetrics(
        image: image,
        crop: crop,
        background: 0x00_00_00_FF,
        foreground: 0xFF_FF_FF_FF)
    }

    let downsampledMetrics = try metrics(atScale: scale, downsampled: true)
    XCTAssertLessThanOrEqual(downsampledMetrics.meanEdgeChroma, 1.0)

    let fractionalMetrics = try metrics(atScale: 1.5, downsampled: false)
    XCTAssertLessThanOrEqual(fractionalMetrics.meanEdgeChroma, 1.0)
  }

  // MARK: - Helpers

  private func slugMetrics(
    layout: VectorSubpixelLayout,
    pointSize: CGFloat,
    pixelWidth: Int,
    pixelHeight: Int,
    scale: CGFloat,
    xShiftPixels: Double = 0,
    background: UInt32,
    foreground: UInt32,
    crop: CGRect
  ) throws -> TestTextAAMetrics {
    let commands = probeCommands(
      x: 12 + CGFloat(xShiftPixels) / scale,
      y: 16,
      lineSpacing: 24,
      background: background,
      foreground: foreground)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize),
        sidebarFontAtlas: FontAtlas(pointSize: pointSize),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale))
    renderer.setSubpixelLayout(layout)
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let image = try decodePNGToRGBA(try XCTUnwrap(renderer.pngData))
    return computeTextAAMetrics(
      image: image,
      crop: crop,
      background: background,
      foreground: foreground)
  }

  private func probeCommands(
    x: CGFloat,
    y: CGFloat,
    lineSpacing: CGFloat,
    background: UInt32,
    foreground: UInt32
  ) -> [FrameCommand] {
    var commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: 2000, height: 400),
        color: background,
        source: .terminal)
    ]
    for (lineIndex, line) in probeLines.enumerated() {
      commands.append(
        .glyphRun(
          origin: CGPoint(x: x, y: y + CGFloat(lineIndex) * lineSpacing),
          text: line,
          foreground: foreground,
          background: background,
          attributes: [],
          source: .terminal))
    }
    return commands
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

  private func srgbEncode(_ c: Double) -> Double {
    c <= 0.003_130_8 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
  }
}
