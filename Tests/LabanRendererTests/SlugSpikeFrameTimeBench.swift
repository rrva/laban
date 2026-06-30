import CoreGraphics
import CoreText
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

final class SlugSpikeCorrectness: XCTestCase {
  func testAnalyticCoverageMatchesCPUOracleForPrintableASCII() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let spike = try XCTUnwrap(SlugGlyphSpike())
    let scalars = Array("Ag%@8m?R".unicodeScalars)

    for scalar in scalars {
      let outline = try XCTUnwrap(spike.spikeReferenceOutline(for: scalar))
      let region = spikeCoverageRegion(for: outline)
      let cpu = GlyphCurveCPUOracle.rasterizeCoverage(
        outline: outline,
        width: region.width,
        height: region.height,
        samplesPerAxis: 1
      ) { x, row, fx, fy in
        CGPoint(
          x: Double(region.origin.x) + Double(x) + fx,
          y: Double(region.origin.y) + Double(region.height - 1 - row) + fy)
      }.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }

      for mode in SlugGlyphSpike.SlugSpikeMode.allCases {
        let gpu = try XCTUnwrap(
          spike.spikeCoverageMask(
            for: scalar,
            origin: region.origin,
            width: region.width,
            height: region.height,
            mode: mode),
          "Spike render failed for \(scalar) in \(mode.rawValue) mode")
        XCTAssertEqual(gpu.count, cpu.count)

        var mismatchedPixels = 0
        var maxDelta = 0
        for index in cpu.indices {
          let delta = abs(Int(gpu[index]) - Int(cpu[index]))
          if delta > 3 {
            mismatchedPixels += 1
            maxDelta = max(maxDelta, delta)
          }
        }
        let allowed = max(1, Int((Double(cpu.count) * 0.02).rounded(.up)))
        XCTAssertLessThanOrEqual(
          mismatchedPixels,
          allowed,
          "\(scalar) \(mode.rawValue) mismatched \(mismatchedPixels) px, max delta \(maxDelta)")
      }
    }
  }

  private func spikeCoverageRegion(
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
}

/// FEASIBILITY SPIKE, not production: measures a Slug-style analytic fragment
/// path over a full 160x48 terminal screen with reusable glyph curve buffers.
///
/// Opt in (off in normal CI):
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugSpikeFrameTimeBench
final class SlugSpikeFrameTimeBench: XCTestCase {
  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  private let cols = 160
  private let rows = 48
  private let cellW: CGFloat = 9
  private let cellH: CGFloat = 19
  private let scale: CGFloat = 2
  private let timedFrames = 200
  private let warmupFrames = 40

  func testSlugAnalyticFrameTimeFullScreen() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let text = SlugGlyphSpike.spikeASCIIText(cols: cols, rows: rows)
    let spike = try XCTUnwrap(SlugGlyphSpike())
    let budget = 1000.0 / 120.0

    print("\n=== Slug analytic glyph spike frame-time ===")
    print("  FEASIBILITY SPIKE, not production")
    print("  grid \(cols)x\(rows) @ scale \(scale)  (\(pixelW)x\(pixelH) px)")
    print("  \(timedFrames) timed frames, command buffer waits for GPU completion")
    print("  mode       size   glyphs  cpu p50/p95/p99 ms       wall p50/p95/p99 ms      verdict")

    for pointSize in [CGFloat(9), CGFloat(14), CGFloat(28)] {
      let frame = try XCTUnwrap(
        spike.makeSpikePreparedFrame(
          rows: text,
          pointSize: pointSize,
          cellWidth: cellW,
          cellHeight: cellH,
          scale: scale,
          pixelWidth: pixelW,
          pixelHeight: pixelH))
      let result = try timeFrames(spike: spike, frame: frame, mode: .banded)
      printRow(mode: "banded", frame: frame, result: result, budget: budget)
    }

    let baselineFrame = try XCTUnwrap(
      spike.makeSpikePreparedFrame(
        rows: text,
        pointSize: 14,
        cellWidth: cellW,
        cellHeight: cellH,
        scale: scale,
        pixelWidth: pixelW,
        pixelHeight: pixelH))
    let noBand = try timeFrames(spike: spike, frame: baselineFrame, mode: .unbanded)
    printRow(mode: "unbanded", frame: baselineFrame, result: noBand, budget: budget)
    print(String(format: "  budget @120Hz = %.2f ms (verdict uses wall p99)", budget))
  }

  private struct SlugSpikeBenchResult {
    var cpuP50: Double
    var cpuP95: Double
    var cpuP99: Double
    var wallP50: Double
    var wallP95: Double
    var wallP99: Double
  }

  private func timeFrames(
    spike: SlugGlyphSpike,
    frame: SlugGlyphSpike.SlugSpikePreparedFrame,
    mode: SlugGlyphSpike.SlugSpikeMode
  ) throws -> SlugSpikeBenchResult {
    for _ in 0..<warmupFrames {
      _ = try XCTUnwrap(spike.renderSpikeFrame(frame, mode: mode, waitUntilCompleted: true))
    }

    var cpu: [Double] = []
    var wall: [Double] = []
    cpu.reserveCapacity(timedFrames)
    wall.reserveCapacity(timedFrames)
    for _ in 0..<timedFrames {
      let sample = try XCTUnwrap(
        spike.renderSpikeFrame(frame, mode: mode, waitUntilCompleted: true))
      cpu.append(sample.spikeCPUMilliseconds)
      wall.append(sample.spikeWallMilliseconds)
    }
    cpu.sort()
    wall.sort()
    return SlugSpikeBenchResult(
      cpuP50: percentile(cpu, 0.50),
      cpuP95: percentile(cpu, 0.95),
      cpuP99: percentile(cpu, 0.99),
      wallP50: percentile(wall, 0.50),
      wallP95: percentile(wall, 0.95),
      wallP99: percentile(wall, 0.99))
  }

  private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded()) - 1))
    return sorted[idx]
  }

  private func printRow(
    mode: String,
    frame: SlugGlyphSpike.SlugSpikePreparedFrame,
    result: SlugSpikeBenchResult,
    budget: Double
  ) {
    let verdict = result.wallP99 <= budget ? "PASS" : "OVER"
    print(
      String(
        format:
          "  %-9@ %5.1f  %6d  %7.3f/%7.3f/%7.3f    %7.3f/%7.3f/%7.3f   %@",
        mode as NSString,
        Double(frame.spikePointSize),
        frame.spikeInstanceCount,
        result.cpuP50,
        result.cpuP95,
        result.cpuP99,
        result.wallP50,
        result.wallP95,
        result.wallP99,
        verdict as NSString))
  }
}
