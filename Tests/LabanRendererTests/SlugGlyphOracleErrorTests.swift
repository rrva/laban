import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Slug's per-pixel coverage against the 8x8 box-filter CPU oracle
/// (`GlyphCurveCPUOracle`), undilated, so it measures the anti-aliasing
/// filter alone. The aggregate fidelity tests compare against CoreText with
/// loose metrics that cannot tell AA filters apart; this pins the error.
///
/// Glyphs cover stem corners (where two-ray coverage over-estimates), curves,
/// diagonals and the shade blocks. Sizes are device pixels per em at 2x.
/// `LABAN_PRINT_AA_ERROR=1` prints the numbers.
final class SlugGlyphOracleErrorTests: XCTestCase {
  private let glyphs: [Unicode.Scalar] = [
    "D", "K", "P", "b", "h", "E", "o", "e", "s", "g", "@", "/", "x", "v", "1", "#",
  ]
  private let shades: [Unicode.Scalar] = ["\u{2591}", "\u{2592}", "\u{2593}"]

  private struct ErrorStats {
    var meanAbsoluteError: Double
    /// Pixels more than a quarter of full coverage off.
    var outliers: Int
    /// GPU ink over oracle ink, minus one.
    var inkMassError: Double
  }

  func testCoverageErrorAgainstBoxFilterOracleStaysWithinBudget() throws {
    let renderer = try makeRenderer()
    // Budgets: measured one-sample-per-pixel error (mae 0.035 / 0.023, 10 / 4
    // outliers) plus headroom. Outliers are stem corners, where the x and y
    // rays each see a different edge and their combination reads about twice
    // the true area.
    for (pointSize, maxMAE, maxOutliers) in [(9.0, 0.040, 20), (14.0, 0.026, 10)] {
      let stats = try measure(renderer: renderer, scalars: glyphs, pointSize: pointSize)
      report("glyphs \(pointSize)pt", stats)
      XCTAssertLessThanOrEqual(stats.meanAbsoluteError, maxMAE, "\(pointSize)pt mean error")
      XCTAssertLessThanOrEqual(stats.outliers, maxOutliers, "\(pointSize)pt outliers")
      XCTAssertLessThanOrEqual(abs(stats.inkMassError), 0.05, "\(pointSize)pt ink mass")
    }
  }

  /// The shade blocks are grids of small squares, all corners: their pixels
  /// err most, but the overall tone must hold (measured mae 0.084 / 0.052).
  func testShadeBlocksKeepTheirTone() throws {
    let renderer = try makeRenderer()
    for (pointSize, maxMAE) in [(9.0, 0.095), (14.0, 0.060)] {
      let stats = try measure(
        renderer: renderer, scalars: shades, pointSize: pointSize, phases: [0])
      report("shades \(pointSize)pt", stats)
      XCTAssertLessThanOrEqual(stats.meanAbsoluteError, maxMAE, "\(pointSize)pt shade error")
      XCTAssertLessThanOrEqual(abs(stats.inkMassError), 0.03, "\(pointSize)pt shade ink mass")
    }
  }

  private func makeRenderer() throws -> SlugGlyphRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device available") }
    return try XCTUnwrap(SlugGlyphRenderer(fontAtlas: FontAtlas(pointSize: 14)))
  }

  private func measure(
    renderer: SlugGlyphRenderer, scalars: [Unicode.Scalar], pointSize: Double,
    phases: [Double] = [0, 0.5]
  ) throws -> ErrorStats {
    // Reference outlines are 14 pt; at 2x a pixel is 14 / (pointSize * 2) units.
    let unitsPerPixel = 14.0 / (pointSize * 2)
    var absoluteError = 0.0
    var count = 0
    var outliers = 0
    var gpuInk = 0.0
    var oracleInk = 0.0
    for scalar in scalars {
      let outline = try XCTUnwrap(renderer.referenceOutline(for: scalar), "\(scalar)")
      for phase in phases {
        let pad = 2 * unitsPerPixel
        let originX = floor(outline.bounds.minX - pad) + phase * unitsPerPixel
        let originY = floor(outline.bounds.minY - pad) + phase * 0.5 * unitsPerPixel
        let width = Int(ceil((outline.bounds.maxX + pad - originX) / unitsPerPixel))
        let height = Int(ceil((outline.bounds.maxY + pad - originY) / unitsPerPixel))
        let oracle = GlyphCurveCPUOracle.rasterizeCoverage(
          outline: outline, width: width, height: height, samplesPerAxis: 8
        ) { x, row, fx, fy in
          CGPoint(
            x: originX + (Double(x) + fx) * unitsPerPixel,
            y: originY + (Double(height - 1 - row) + fy) * unitsPerPixel)
        }
        let gpu = try XCTUnwrap(
          renderer.coverageMask(
            for: scalar, origin: CGPoint(x: originX, y: originY), width: width, height: height,
            unitsPerPixel: unitsPerPixel))
        for index in oracle.indices {
          let value = Double(gpu[index]) / 255
          guard value > 0 || oracle[index] > 0 else { continue }
          let error = abs(value - oracle[index])
          absoluteError += error
          count += 1
          if error > 0.25 { outliers += 1 }
          gpuInk += value
          oracleInk += oracle[index]
        }
      }
    }
    return ErrorStats(
      meanAbsoluteError: absoluteError / Double(max(count, 1)),
      outliers: outliers,
      inkMassError: oracleInk > 0 ? gpuInk / oracleInk - 1 : 0)
  }

  private func report(_ label: String, _ stats: ErrorStats) {
    guard ProcessInfo.processInfo.environment["LABAN_PRINT_AA_ERROR"] == "1" else { return }
    print(
      String(
        format: "AA error %@: mae %.4f outliers %d ink %+.2f%%",
        label as NSString, stats.meanAbsoluteError, stats.outliers, stats.inkMassError * 100))
  }
}
