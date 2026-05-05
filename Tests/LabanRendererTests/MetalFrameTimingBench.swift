import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

/// Disabled in normal CI; opt in via:
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalFrameTimingBench
///
/// Drives a representative TUI workload through the Metal renderer at a
/// few grid sizes and prints `recentFrameTimings()` — including per-pass
/// GPU means — so we have ground-truth numbers for the latest renderer
/// without having to drive the AppKit shell.
final class MetalFrameTimingBench: XCTestCase {

  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  func testFrameTimingsAcrossWorkloads() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    let device = MTLCreateSystemDefaultDevice()!
    let renderSupp = device.supportsCounterSampling(.atStageBoundary)
    let blitSupp = device.supportsCounterSampling(.atBlitBoundary)
    print(
      "\n=== MetalRenderer per-pass timings (mean over 200 frames) ==="
        + "\n  device.supportsCounterSampling(.atStageBoundary) = \(renderSupp)"
        + "\n  device.supportsCounterSampling(.atBlitBoundary)  = \(blitSupp)")
    try benchAt(label: "small  80x24", cols: 80, rows: 24, fontAtlas: fontAtlas)
    try benchAt(label: "medium 160x48", cols: 160, rows: 48, fontAtlas: fontAtlas)
    try benchAt(label: "large  240x72", cols: 240, rows: 72, fontAtlas: fontAtlas)
    try benchAt(label: "xl     400x120", cols: 400, rows: 120, fontAtlas: fontAtlas)
  }

  private func benchAt(
    label: String, cols: Int, rows: Int, fontAtlas: FontAtlas
  ) throws {
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)

    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      return
    }
    renderer.resize(pixelWidth: pixelW, pixelHeight: pixelH, scale: scale)

    let asciiPrintable = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    func frame(at index: Int) -> [FrameCommand] {
      var cmds: [FrameCommand] = []
      for r in 0..<rows {
        let row = index + r
        let color: UInt32 =
          (UInt32((row * 37) & 0xFF) << 24)
          | (UInt32((row * 89) & 0xFF) << 16)
          | (UInt32((row * 167) & 0xFF) << 8) | 0xFF
        let y = CGFloat(rows - 1 - r) * cellH
        cmds.append(
          .rect(
            CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
            color: color, source: .terminal))
        let start = row % asciiPrintable.count
        let chars = String(
          (asciiPrintable + asciiPrintable).dropFirst(start).prefix(cols))
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: 0, y: y),
            text: chars,
            foreground: 0xFF_FF_FF_FF,
            background: color,
            attributes: [],
            source: .terminal))
      }
      // Add a cursor so the cursor-overlay pass actually fires.
      cmds.append(
        .cursor(
          CGRect(x: 0, y: 0, width: cellW, height: cellH),
          color: 0xAD_BC_BC_FF))
      return cmds
    }

    // Warm up — first frames pay one-time atlas allocations and JIT.
    for i in 0..<8 {
      renderer.render(frame(at: i), damage: .full)
    }

    // Measure — full damage every frame so we exercise content+present+cursor.
    for i in 8..<208 {
      renderer.render(frame(at: i), damage: .full)
    }
    // Drain the GPU so the last frames' completion handlers fire and
    // recentFrameTimings() reflects the whole batch.
    renderer.captureMode = true
    _ = renderer.pngData

    let t = renderer.recentFrameTimings()
    print(
      String(
        format: "  [%@]  n=%d  cpu p50/p99=%.3f/%.3f ms  gpu p50/p99=%.3f/%.3f ms",
        label, t.sampleCount,
        t.cpuP50Ms, t.cpuP99Ms, t.gpuP50Ms, t.gpuP99Ms))
    if t.perPassAvailable {
      // Present + readback values may report 0 on devices that don't
      // expose `.atBlitBoundary` sampling (most current Apple silicon).
      // Their cost is still inside the total GPU number above.
      print(
        String(
          format: "       per-pass mean: content=%.3f cursor=%.3f ms"
            + "  (present/readback unmeasured: blit boundary unsupported)",
          t.contentMeanMs, t.cursorOverlayMeanMs))
    } else {
      print("       per-pass GPU counters unavailable on this device")
    }
  }
}
