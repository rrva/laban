import CoreGraphics
import Darwin
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// M3a feasibility prototype for `execplans/active/vector-zoom-smoothness.md`.
///
/// Measures the per-frame CPU cost of a *continuous fractional zoom* on the
/// vector backend at live terminal scale — the workload a Cmd+scroll / pinch
/// slide produces, where every frame is a new point size. This is the number
/// the SOTA "resolution-independent / analytic" zoom path must beat, and a
/// conservative upper bound on that path's own cost: the analytic coverage
/// evaluation is exactly the `encodeAccumulate` winding-number work this bench
/// already pays per frame; analytic merely *removes* the atlas reserve/evict/
/// touch round-trip on top, so if the current re-bake-per-frame path holds the
/// frame budget, analytic certainly does.
///
/// It also isolates the two suspected causes of the reported "super slow":
///  - throughput: re-baking the visible glyph set every frame (a new size every
///    frame misses the size-keyed mask atlas), versus
///  - the M0 synchronous-frame guarantee (`waitForFrameCompletion`), which
///    serializes CPU+GPU every gesture event. M0 turns it on for the apply
///    path; this bench measures both settings so we can see how much of "slow"
///    is the wait, not the bake.
///
/// Opt in (off in normal CI):
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter VectorZoomFrameTimeBench
final class VectorZoomFrameTimeBench: XCTestCase {
  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  private let cols = 160
  private let rows = 48
  private let cellW: CGFloat = 9
  private let cellH: CGFloat = 19
  private let scale: CGFloat = 2

  // Sweep 14 -> 28 pt over the timed frames (a realistic 2x zoom slide), then
  // back, so the sweep is monotonic per direction like a real gesture.
  private let baseSize: CGFloat = 14
  private let peakSize: CGFloat = 28

  func testZoomFrameTimeContinuousFractionalSweep() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)

    print("\n=== Continuous fractional zoom frame-time (vector backend) ===")
    print("  grid \(cols)x\(rows) @ scale \(scale)  (\(pixelW)x\(pixelH) px), 200 timed frames")
    print("  path                         cpu p50/p95/p99 ms")

    let budget = 1000.0 / 120.0

    // Why the production gesture does NOT re-bake per frame. Re-applying the font
    // (a new fractional size every frame) re-bakes the whole screen: this is the
    // cost the final compositor-scale design avoids by scaling the resident
    // surface during motion and re-baking only ONCE on gesture end.
    //   - sync (per-frame waitForFrameCompletion): the ~835 ms "super slow".
    //   - async: still ~20 ms/frame, over the 8.33 ms / 120 Hz budget.
    printRow("rebake/frame, sync", try measureRebakePerFrame(wait: true, pw: pixelW, ph: pixelH))
    printRow("rebake/frame, async", try measureRebakePerFrame(wait: false, pw: pixelW, ph: pixelH))

    // The cost the final design DOES pay: one steady cache-hit render (the single
    // settle frame on gesture end, and what a scroll frame costs at this grid).
    printRow("steady render (settle)", try measureSteadyRender(pw: pixelW, ph: pixelH))

    // The gesture-END commit cost: reconfigureFonts (atlas reset + 3 fallback
    // texture rebuilds) + one full render. This fires ONCE per pinch — fine — but
    // the Cmd+scroll path fires it PER scroll event (each is a self-contained
    // began+ended), so a fast scroll pays this dozens of times a second. If this
    // is multi-ms, that is the Cmd+scroll lock-up.
    printRow("gesture-end commit", try measureSettleCommit(pw: pixelW, ph: pixelH))

    print(String(format: "  budget @120Hz = %.2f ms", budget))
  }

  /// Time a full gesture-end commit: a fresh-size `reconfigureFonts` (atlas reset
  /// + raster/color fallback texture rebuilds) followed by a full render — the
  /// work `applyZoomMagnification`'s `.ended` branch does once per gesture (and
  /// the Cmd+scroll path does once per scroll event).
  private func measureSettleCommit(pw: Int, ph: Int) throws -> (
    p50: Double, p95: Double, p99: Double
  ) {
    let base = FontAtlas(pointSize: baseSize)
    guard
      let renderer = VectorGlyphRenderer(
        fontAtlas: base, sidebarFontAtlas: base, pixelWidth: pw, pixelHeight: ph, scale: scale)
    else { throw XCTSkip("VectorGlyphRenderer unavailable") }
    var sizes: [CGFloat] = []
    for i in 0..<80 { sizes.append(baseSize + CGFloat(i % 26) + 0.3) }
    var idx = 0
    let frame: (Int) -> Void = { _ in
      let atlas = FontAtlas(pointSize: sizes[idx % sizes.count])
      idx += 1
      renderer.reconfigureFonts(fontAtlas: atlas, sidebarFontAtlas: atlas)
      _ = renderer.render(self.commands(), damage: .full)
    }
    return timeFrames(warmup: frame, timed: frame)
  }

  /// Re-apply a new fractional size + render every frame (the rejected naive
  /// path): an upper bound that justifies the compositor-scale design.
  private func measureRebakePerFrame(wait: Bool, pw: Int, ph: Int) throws -> (
    p50: Double, p95: Double, p99: Double
  ) {
    let base = FontAtlas(pointSize: baseSize)
    guard
      let renderer = VectorGlyphRenderer(
        fontAtlas: base, sidebarFontAtlas: base, pixelWidth: pw, pixelHeight: ph, scale: scale)
    else { throw XCTSkip("VectorGlyphRenderer unavailable") }
    renderer.waitForFrameCompletion = wait

    func sizeFor(_ i: Int) -> CGFloat {
      let span = peakSize - baseSize
      let stepped = CGFloat((i % 80)) * (span / 40)
      return baseSize + (stepped <= span ? stepped : 2 * span - stepped)
    }
    func frame(_ i: Int) {
      let atlas = FontAtlas(pointSize: sizeFor(i))
      renderer.applyLiveZoomFonts(fontAtlas: atlas, sidebarFontAtlas: atlas)
      _ = renderer.render(commands(), damage: .full)
    }
    return timeFrames(warmup: frame, timed: frame)
  }

  /// Render the same size every frame (pure cache hit) — the steady-state cost
  /// the gesture pays only on its single settle frame.
  private func measureSteadyRender(pw: Int, ph: Int) throws -> (
    p50: Double, p95: Double, p99: Double
  ) {
    let atlas = FontAtlas(pointSize: (baseSize + peakSize) / 2)
    guard
      let renderer = VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas, pixelWidth: pw, pixelHeight: ph, scale: scale)
    else { throw XCTSkip("VectorGlyphRenderer unavailable") }
    let frame: (Int) -> Void = { _ in _ = renderer.render(self.commands(), damage: .full) }
    return timeFrames(warmup: frame, timed: frame)
  }

  private func timeFrames(warmup: (Int) -> Void, timed: (Int) -> Void) -> (
    p50: Double, p95: Double, p99: Double
  ) {
    for i in 0..<40 { warmup(i) }
    var samples: [Double] = []
    samples.reserveCapacity(200)
    for i in 40..<240 {
      let start = DispatchTime.now().uptimeNanoseconds
      timed(i)
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
    print(String(format: "  %-26@ %.3f / %.3f / %.3f", label as NSString, r.p50, r.p95, r.p99))
  }

  /// Full screen of varied ASCII on a dark background.
  private func commands() -> [FrameCommand] {
    var cmds: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x10_10_10_FF, source: .terminal)
    ]
    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    let doubled = ascii + ascii
    for row in 0..<rows {
      let start = (row * 7) % ascii.count
      let from = doubled.index(doubled.startIndex, offsetBy: start)
      let line = String(doubled[from...].prefix(cols))
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: line,
          foreground: 0xEE_EE_EE_FF,
          background: 0x10_10_10_FF,
          attributes: [],
          source: .terminal))
    }
    return cmds
  }
}
