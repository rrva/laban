import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Regression test for the RGB-subpixel seam artifact on the Slug Glyph
/// renderer: two abutting glyphs that share a pixel row (stacked `│`
/// box-drawing chars, as btop draws for a vertical frame) must not show a
/// brighter, less-inked notch where they meet.
///
/// Root cause: the per-glyph "over" composite double-darkens at a seam, losing
/// c1*c2 of ink per channel. In RGB subpixel a single subpixel channel can be
/// ~fully covered, so c1*c2 reaches ~0.25 and the notch is a visible bright
/// fringe. The accumulate-then-composite-once path sums coverage across glyphs
/// first (c1 + c2 = c_full), so the seam equals the steady interior.
///
/// Reproduction: stack `│` glyphs at the Slug outline ink height (the Slug
/// renderer draws the full `│` outline, which extends past the cell) with a
/// fractional device origin (16.25 pt * scale 2 = 32.5 device px). The
/// fractional origin forces every glyph's ink edges onto fractional pixel rows,
/// so each abutment seam has vertical AA on both sides — the condition that
/// exposes the c1*c2 notch.
///
/// The Vector Glyph renderer is not tested here: it keeps box-drawing vertical
/// edges pixel-crisp (hard 0/255 edges, no vertical AA at the seam) in crisp,
/// fluid, and per-phase scroll modes, so the │ vertical-seam artifact does not
/// reproduce under unit-test conditions. See
/// `execplans/active/subpixel-seam-accumulate-once.md`.
final class SubpixelSeamAccumulateTests: XCTestCase {
  private let background: UInt32 = 0xFF_FF_FF_FF
  private let foreground: UInt32 = 0x00_00_00_FF
  private let pointSize: CGFloat = 18
  private let scale: CGFloat = 2
  private let glyphCount = 10
  private let originXPoints: CGFloat = 10
  private let originYPoints: CGFloat = 16.25
  /// The seam may not lose more than this much ink versus the steady interior.
  /// The pre-fix notch is ~25 % of the ink range (~64/255), so 24 separates
  /// "fixed" from "broken" with margin.
  private let maxSeamInkLoss: Double = 24

  private func skipIfNoMetal() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
  }

  func testSlugStackedBoxDrawingSeamIsNotBrighterThanInterior() throws {
    try skipIfNoMetal()
    let atlas = FontAtlas(pointSize: pointSize)
    let slugProbe = try XCTUnwrap(
      SlugGlyphRenderer(fontAtlas: atlas, pixelWidth: 10, pixelHeight: 10, scale: scale))
    // Slug draws the full `│` outline, which extends past the cell, so it tiles
    // at the outline ink height (not the cell height).
    let spacingPoints = try inkHeightOfVerticalBar(renderer: slugProbe)
    let cellHeightPoints = atlas.cellSize.height
    let pixelWidth = 80
    let pixelHeight = Int((CGFloat(glyphCount) * max(spacingPoints, cellHeightPoints) + 40) * scale)
    let commands = stackedBarCommands(
      spacingPoints: spacingPoints, pixelHeight: pixelHeight)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: atlas, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    renderer.setSubpixelLayout(.rgbStripe)
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let image = try decodePNGToRGBA(try XCTUnwrap(renderer.pngData))
    let analysis = analyzeStemInk(
      image: image,
      spacingDevice: spacingPoints * scale,
      glyphCount: glyphCount,
      originYDevice: originYPoints * scale)
    XCTAssertLessThanOrEqual(
      analysis.medianInteriorStemInk - analysis.minInteriorStemInk,
      maxSeamInkLoss,
      "Slug subpixel seam lost ink: median \(analysis.medianInteriorStemInk) "
        + "min \(analysis.minInteriorStemInk) (stem column \(analysis.stemX))")
  }

  /// Light-on-dark counterpart to the test above: btop draws its frames as a
  /// light `│` (grey 0x303030) on a black background, which takes the additive
  /// composite path (`dst += color`). The `│` outline ink height exceeds the
  /// cell pitch, so abutting `│` overlap and the accumulate pass sums their
  /// per-channel coverage past 1.0 at the seam. Without clamping that sum, the
  /// additive pass emits `glyphColor * summedCoverage` > `glyphColor`, so the
  /// seam reads *brighter* than the stem (grey 48 becomes ~69). The fix clamps
  /// the summed coverage to 1.0, making the seam match the stem.
  func testSlugStackedBoxDrawingSeamIsNotBrighterThanInteriorLightOnDark() throws {
    try skipIfNoMetal()
    let atlas = FontAtlas(pointSize: pointSize)
    let slugProbe = try XCTUnwrap(
      SlugGlyphRenderer(fontAtlas: atlas, pixelWidth: 10, pixelHeight: 10, scale: scale))
    let inkHeightPoints = try inkHeightOfVerticalBar(renderer: slugProbe)
    let cellHeightPoints = atlas.cellSize.height
    // The btop notch requires the `│` outline to overrun the cell so abutting
    // glyphs overlap. Skip if this font size happens to tile without overlap.
    try XCTSkipIf(inkHeightPoints <= cellHeightPoints, "no overlap at this point size")
    // Tile at the cell pitch (as the terminal grid does), not the ink height,
    // so the `│` outlines overlap at each seam. Integer origin reproduces the
    // at-rest btop condition (no fractional scroll shift needed).
    let spacingPoints = cellHeightPoints
    let pixelWidth = 80
    let pixelHeight = Int((CGFloat(glyphCount) * spacingPoints + 40) * scale)
    let lightBackground: UInt32 = 0x00_00_00_FF
    let lightForeground: UInt32 = 0x30_30_30_FF
    var commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: 4000, height: pixelHeight),
        color: lightBackground, source: .terminal)
    ]
    for index in 0..<glyphCount {
      commands.append(
        .glyphRun(
          origin: CGPoint(x: originXPoints, y: originYPoints + CGFloat(index) * spacingPoints),
          text: "│",
          foreground: lightForeground,
          background: lightBackground,
          attributes: [],
          source: .terminal))
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: atlas, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    renderer.setSubpixelLayout(.rgbStripe)
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let image = try decodePNGToRGBA(try XCTUnwrap(renderer.pngData))
    let analysis = analyzeStemInkLightOnDark(
      image: image,
      spacingDevice: spacingPoints * scale,
      glyphCount: glyphCount,
      originYDevice: originYPoints * scale)
    // For a light glyph on a dark background, a brighter seam is a *lower*-ink
    // row (ink = 255 - min channel; brighter pixel = higher RGB = lower ink).
    // The pre-fix over-coverage notch drops seam ink ~21 points below the stem
    // (stem 207 -> seam 186, i.e. the seam greys up from 48 to 69). A 15-point
    // band sits safely between the pre-fix notch and the post-fix match (0).
    let maxLightOnDarkSeamInkLoss: Double = 15
    XCTAssertGreaterThanOrEqual(
      analysis.minInteriorStemInk,
      analysis.medianInteriorStemInk - maxLightOnDarkSeamInkLoss,
      "Slug subpixel additive seam was brighter than interior: median "
        + "\(analysis.medianInteriorStemInk) min \(analysis.minInteriorStemInk) "
        + "(stem column \(analysis.stemX))")
  }

  // MARK: - Helpers

  /// Ink height of `│` (U+2502) in points at the active point size, from the
  /// reference outline. Used as the Slug tiling distance.
  private func inkHeightOfVerticalBar(renderer: SlugGlyphRenderer) throws -> CGFloat {
    let scalar = "│".unicodeScalars.first!
    let outline = try XCTUnwrap(renderer.referenceOutline(for: scalar))
    let pointScale = pointSize / SlugGlyphRenderer.referencePointSize
    return (outline.bounds.maxY - outline.bounds.minY) * pointScale
  }

  private func stackedBarCommands(
    spacingPoints: CGFloat, pixelHeight: Int
  ) -> [FrameCommand] {
    var commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: 4000, height: pixelHeight),
        color: background,
        source: .terminal)
    ]
    for index in 0..<glyphCount {
      commands.append(
        .glyphRun(
          origin: CGPoint(
            x: originXPoints,
            y: originYPoints + CGFloat(index) * spacingPoints),
          text: "│",
          foreground: foreground,
          background: background,
          attributes: [],
          source: .terminal))
    }
    return commands
  }

  private struct StemInkAnalysis {
    let stemX: Int
    let minInteriorStemInk: Double
    let medianInteriorStemInk: Double
  }

  /// Find the vertical stem column and measure per-row ink (255 - min channel)
  /// over the interior of the stack. The pre-fix seam notch shows up as a row
  /// with markedly less ink than the steady interior; the fix makes the seam
  /// match the interior.
  private func analyzeStemInk(
    image: TestRGBAImage,
    spacingDevice: CGFloat,
    glyphCount: Int,
    originYDevice: CGFloat
  ) -> StemInkAnalysis {
    // Locate the stem column: the column with the most ink (lowest mean luma)
    // over the stack's vertical extent. Background is uniform white, so the
    // stem is the global minimum.
    var bestX = 0
    var bestMeanLuma = Double.infinity
    let probeMinY = max(0, Int(originYDevice) - 4)
    let probeMaxY = min(
      image.height, Int(originYDevice) + Int(CGFloat(glyphCount) * spacingDevice) + 4)
    for x in 0..<image.width {
      var sum = 0.0
      var count = 0
      for y in probeMinY..<probeMaxY {
        let p = image.pixel(x: x, y: y)
        sum += Double(Int(p.r) + Int(p.g) + Int(p.b)) / 3.0
        count += 1
      }
      let meanLuma = count == 0 ? Double.infinity : sum / Double(count)
      if meanLuma < bestMeanLuma {
        bestMeanLuma = meanLuma
        bestX = x
      }
    }

    // Per-row stem ink across the stack.
    var stemInk: [Double] = []
    var stackRows: [Int] = []
    let cellDevice = Int(spacingDevice.rounded())
    for y in 0..<image.height {
      let p = image.pixel(x: bestX, y: y)
      let ink = 255.0 - Double(min(Int(p.r), Int(p.g), Int(p.b)))
      stemInk.append(ink)
      if ink > 8 { stackRows.append(y) }
    }
    guard let firstRow = stackRows.first, let lastRow = stackRows.last else {
      return StemInkAnalysis(stemX: bestX, minInteriorStemInk: 0, medianInteriorStemInk: 0)
    }
    // Exclude a full cell at each end to drop the endpoint fades; what remains
    // is the interior of the stack with its abutting seams.
    let interiorStart = firstRow + cellDevice
    let interiorEnd = lastRow - cellDevice
    var interior: [Double] = []
    if interiorStart < interiorEnd {
      for y in interiorStart..<interiorEnd {
        interior.append(stemInk[y])
      }
    }
    let sorted = interior.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let minInk = sorted.first ?? 0
    return StemInkAnalysis(
      stemX: bestX,
      minInteriorStemInk: minInk,
      medianInteriorStemInk: median)
  }

  /// Light-on-dark variant: the stem is the *lightest* column (highest mean
  /// luma) over the stack, and stack rows are where the stem is present (ink
  /// below the pure-background ceiling) rather than where ink exceeds a floor.
  private func analyzeStemInkLightOnDark(
    image: TestRGBAImage,
    spacingDevice: CGFloat,
    glyphCount: Int,
    originYDevice: CGFloat
  ) -> StemInkAnalysis {
    var bestX = 0
    var bestMeanLuma = -Double.infinity
    let probeMinY = max(0, Int(originYDevice) - 4)
    let probeMaxY = min(
      image.height, Int(originYDevice) + Int(CGFloat(glyphCount) * spacingDevice) + 4)
    for x in 0..<image.width {
      var sum = 0.0
      var count = 0
      for y in probeMinY..<probeMaxY {
        let p = image.pixel(x: x, y: y)
        sum += Double(Int(p.r) + Int(p.g) + Int(p.b)) / 3.0
        count += 1
      }
      let meanLuma = count == 0 ? -Double.infinity : sum / Double(count)
      if meanLuma > bestMeanLuma {
        bestMeanLuma = meanLuma
        bestX = x
      }
    }

    var stemInk: [Double] = []
    var stackRows: [Int] = []
    let cellDevice = Int(spacingDevice.rounded())
    for y in 0..<image.height {
      let p = image.pixel(x: bestX, y: y)
      let ink = 255.0 - Double(min(Int(p.r), Int(p.g), Int(p.b)))
      stemInk.append(ink)
      // Background is pure black (ink 255); the stem and its AA ramp fall below.
      if ink < 250 { stackRows.append(y) }
    }
    guard let firstRow = stackRows.first, let lastRow = stackRows.last else {
      return StemInkAnalysis(stemX: bestX, minInteriorStemInk: 0, medianInteriorStemInk: 0)
    }
    let interiorStart = firstRow + cellDevice
    let interiorEnd = lastRow - cellDevice
    var interior: [Double] = []
    if interiorStart < interiorEnd {
      for y in interiorStart..<interiorEnd {
        interior.append(stemInk[y])
      }
    }
    let sorted = interior.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let minInk = sorted.first ?? 0
    return StemInkAnalysis(
      stemX: bestX,
      minInteriorStemInk: minInk,
      medianInteriorStemInk: median)
  }
}
