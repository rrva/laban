import CoreGraphics
import Darwin
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Quantifies the per-frame CPU cost of a continuous scroll across the three
/// renderer paths a user can pick: the classic GPU renderer (`MetalRenderer`,
/// command path) and the vector renderer in both smooth-scroll modes (fluid /
/// crisp). It drives the SAME full-screen text through each, sweeping a sub-cell
/// scroll offset every frame, and reports CPU encode time per frame (p50/p95/p99).
///
/// This is the measurement behind "GPU-driven feels smoother than vector": the
/// vector path forces full damage and re-walks every visible glyph each scroll
/// frame, so its per-frame CPU is structurally higher. The numbers say by how
/// much, and whether fluid (cached masks) closes the gap versus crisp (per-phase
/// rasterization).
///
/// Opt in (off in normal CI):
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter VectorScrollFrameTimeBench
final class VectorScrollFrameTimeBench: XCTestCase {
  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  private let cols = 160
  private let rows = 48
  private let cellW: CGFloat = 9
  private let cellH: CGFloat = 19
  private let scale: CGFloat = 2

  func testScrollFrameTimeAcrossRenderers() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let fontAtlas = FontAtlas(pointSize: 14)

    print("\n=== Scroll frame-time: GPU-driven vs vector fluid vs vector crisp ===")
    print("  grid \(cols)x\(rows) @ scale \(scale)  (\(pixelW)x\(pixelH) px), 200 timed frames")
    print("  path           cpu p50/p95/p99 ms")

    let metal = try measureMetal(fontAtlas: fontAtlas, pixelW: pixelW, pixelH: pixelH)
    printRow("gpu/classic", metal)

    let fluid = try measureVector(
      mode: .fluid, fontAtlas: fontAtlas, pixelW: pixelW, pixelH: pixelH)
    printRow("vector/fluid", fluid)

    let crisp = try measureVector(
      mode: .perPhase, fontAtlas: fontAtlas, pixelW: pixelW, pixelH: pixelH)
    printRow("vector/crisp", crisp)
  }

  // MARK: - Renderer drivers

  private func measureMetal(
    fontAtlas: FontAtlas, pixelW: Int, pixelH: Int
  ) throws -> (p50: Double, p95: Double, p99: Double) {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      throw XCTSkip("MetalRenderer unavailable")
    }
    renderer.resize(pixelWidth: pixelW, pixelHeight: pixelH, scale: scale)
    return sweep { offsetPoints in
      _ = renderer.render(commands(offsetPoints: offsetPoints), damage: .full)
    }
  }

  private func measureVector(
    mode: VectorSmoothScrollMode, fontAtlas: FontAtlas, pixelW: Int, pixelH: Int
  ) throws -> (p50: Double, p95: Double, p99: Double) {
    guard
      let renderer = VectorGlyphRenderer(
        fontAtlas: fontAtlas, sidebarFontAtlas: fontAtlas,
        pixelWidth: pixelW, pixelHeight: pixelH, scale: scale,
        smoothScrollMode: mode)
    else { throw XCTSkip("VectorGlyphRenderer unavailable") }
    return sweep { offsetPoints in
      renderer.setScrollPhaseOffset(CGPoint(x: 0, y: offsetPoints))
      _ = renderer.render(commands(offsetPoints: offsetPoints), damage: .full)
    }
  }

  // MARK: - Sweep + timing

  /// Warms up (atlas convergence), then times 200 frames while sweeping a
  /// continuous sub-cell offset (the signed remainder ∈ [-0.5, 0.5] device px,
  /// expressed in points). Returns CPU ms percentiles of the render closure.
  private func sweep(_ frame: (CGFloat) -> Void) -> (p50: Double, p95: Double, p99: Double) {
    func offset(_ i: Int) -> CGFloat {
      // Sweep through a full device pixel of phase, in points.
      let devpx = (CGFloat((i % 8)) / 8.0 - 0.5)
      return devpx / scale
    }
    for i in 0..<40 { frame(offset(i)) }  // warm up: converge masks

    var samples: [Double] = []
    samples.reserveCapacity(200)
    for i in 40..<240 {
      let start = DispatchTime.now().uptimeNanoseconds
      frame(offset(i))
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000_000.0)
    }
    samples.sort()
    return (percentile(samples, 0.50), percentile(samples, 0.95), percentile(samples, 0.99))
  }

  private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded()) - 1))
    return sorted[idx]
  }

  private func printRow(_ label: String, _ r: (p50: Double, p95: Double, p99: Double)) {
    print(String(format: "  %-14@ %.3f / %.3f / %.3f", label as NSString, r.p50, r.p95, r.p99))
  }

  // MARK: - Workload

  /// Full screen of varied ASCII text on a dark background, with each row's
  /// baseline shifted by the sub-cell scroll offset (the smooth-scroll input).
  private func commands(offsetPoints: CGFloat) -> [FrameCommand] {
    var cmds: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x10_10_10_FF, source: .terminal)
    ]
    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    for row in 0..<rows {
      let start = (row * 7) % ascii.count
      let doubled = ascii + ascii
      let from = doubled.index(doubled.startIndex, offsetBy: start)
      let line = String(doubled[from...].prefix(cols))
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH + offsetPoints),
          text: line,
          foreground: 0xEE_EE_EE_FF,
          background: 0x10_10_10_FF,
          attributes: [],
          source: .terminal))
    }
    return cmds
  }
}
