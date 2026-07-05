import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// M3 exploration harness for
/// `execplans/active/slug-render-loop-perf-and-aa-quality.md`: prints
/// Slug-vs-`SoftwareBackend` fidelity metrics at small point sizes (9, 11 pt),
/// where more of every stem is "edge" and `kSlugAreaAASampleCount`
/// (`VectorGlyphShaders.metal:654`) matters most. Print-only, asserts nothing:
/// the shader define is edited by hand between runs to A/B sample counts
/// 2/4/8, and results are recorded in the plan's M3 Artifacts section, not
/// pinned here as a regression gate (that happens after M3 decides).
///
/// Opt in (off in normal CI):
///   LABAN_RUN_PERF_BENCH=1 swift test --filter SlugGlyphSmallSizeAAProbeBench
final class SlugGlyphSmallSizeAAProbeBench: XCTestCase {
  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  private let themeBackground: UInt32 = 0xF6_EE_DB_FF
  private let themeForeground: UInt32 = 0x18_22_2A_FF
  private let probeLines = [
    "illili |||| HHHH WWWM",
    "0123456789 abcdef ABCDEF",
    "/\\vDN mwmW I1l |",
    "the quick brown fox jumps",
  ]

  func testSmallSizeAAFidelityAcrossSizesScalesAndModes() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    print("\n=== Slug small-size AA fidelity vs software (kSlugAreaAASampleCount, see .metal) ===")
    print(
      "  pt  scale  mode          ink%delta  gradRatio  edgeRatio%delta  edgeChroma  covSpread")
    for pointSize in [CGFloat(9), CGFloat(11)] {
      for scale in [CGFloat(1), CGFloat(2)] {
        for layout in [VectorSubpixelLayout.grayscale, .calibratedRGB] {
          try printRow(pointSize: pointSize, scale: scale, layout: layout)
        }
      }
    }
  }

  private func printRow(pointSize: CGFloat, scale: CGFloat, layout: VectorSubpixelLayout) throws {
    let pixelWidth = 900
    let pixelHeight = 140
    let crop = CGRect(x: 16, y: 8, width: 860, height: 120)
    let lineSpacing = pointSize * 1.6
    let commands = probeCommands(
      x: 10, y: 12, lineSpacing: lineSpacing, background: themeBackground,
      foreground: themeForeground)

    let software = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: pointSize),
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale)
    guard software.render(commands, damage: .full) else {
      print("  \(pointSize)  \(scale)  \(layout.name)  software render failed, skipped")
      return
    }
    let softwareImage = try decodePNGToRGBA(try XCTUnwrap(software.pngData))
    let softwareMetrics = computeTextAAMetrics(
      image: softwareImage, crop: crop, background: themeBackground, foreground: themeForeground)

    guard
      let slug = SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        scale: scale)
    else {
      throw XCTSkip("SlugGlyphRenderer unavailable")
    }
    slug.waitForFrameCompletion = true
    slug.presentsToLayer = false
    slug.setSubpixelLayout(layout)
    guard slug.render(commands, damage: .full) else {
      print("  \(pointSize)  \(scale)  \(layout.name)  slug render failed, skipped")
      return
    }
    let slugImage = try decodePNGToRGBA(try XCTUnwrap(slug.pngData))
    let slugMetrics = computeTextAAMetrics(
      image: slugImage, crop: crop, background: themeBackground, foreground: themeForeground)

    let inkDeltaPct =
      100 * abs(slugMetrics.inkMass - softwareMetrics.inkMass) / max(softwareMetrics.inkMass, 1)
    let gradRatio = slugMetrics.meanGradient / max(softwareMetrics.meanGradient, 1e-6)
    let edgeRatioDeltaPct =
      100 * (slugMetrics.edgePixelRatio - softwareMetrics.edgePixelRatio)
      / max(softwareMetrics.edgePixelRatio, 1e-6)

    print(
      String(
        format: "  %4.1f  %5.1f  %-12@  %8.2f%%  %9.3f  %13.2f%%  %10.3f  %9.4f",
        Double(pointSize),
        Double(scale),
        layout.name as NSString,
        inkDeltaPct,
        gradRatio,
        edgeRatioDeltaPct,
        slugMetrics.meanEdgeChroma,
        slugMetrics.meanCoverageSpread))
  }

  private func probeCommands(
    x: CGFloat,
    y: CGFloat,
    lineSpacing: CGFloat,
    background: UInt32,
    foreground: UInt32
  ) -> [FrameCommand] {
    var commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 2000, height: 400), color: background, source: .terminal)
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
}
