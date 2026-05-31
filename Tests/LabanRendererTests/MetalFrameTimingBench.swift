import CoreGraphics
import Foundation
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
    try benchClassicDamageComparison(fontAtlas: fontAtlas)
    try benchGPUCellComparison(fontAtlas: fontAtlas)
    try benchGPUCellPatchBuildComparison(fontAtlas: fontAtlas)
    try benchInstanceBuildComparison(fontAtlas: fontAtlas)
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
    renderer.waitForLastFrame()

    let t = renderer.recentFrameTimings()
    print(
      String(
        format: "  [%@]  n=%d  cpu p50/p95/p99=%.3f/%.3f/%.3f ms  gpu p50/p95/p99=%.3f/%.3f/%.3f ms",
        label, t.sampleCount,
        t.cpuP50Ms, t.cpuP95Ms, t.cpuP99Ms,
        t.gpuP50Ms, t.gpuP95Ms, t.gpuP99Ms))
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

  private func benchClassicDamageComparison(fontAtlas: FontAtlas) throws {
    let cols = 160
    let rows = 48
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let dirtySets: [(String, [Int])] = [
      ("row 0", [0]),
      ("row 23", [23]),
      ("rows 0,23 sparse", [0, 23]),
      ("rows 0,12,23 sparse", [0, 12, 23]),
      ("contiguous 1 row", [12]),
      ("contiguous 5 rows", Array(20..<25)),
    ]

    print("\n=== Classic full rebuild vs damage-scoped rebuild (160x48, partial damage) ===")
    print("  dirty-set                  path       n   cpu p50/p95/p99 ms   glyphs solids")
    defer { MetalRenderer.useClassicDamageScoped = true }
    for (label, dirtyRows) in dirtySets {
      let full = try measureClassicDamage(
        label: label,
        scoped: false,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        pixelW: pixelW,
        pixelH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      let scoped = try measureClassicDamage(
        label: label,
        scoped: true,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        pixelW: pixelW,
        pixelH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      printDamageRow(label: label, path: "full", result: full)
      printDamageRow(label: label, path: "scoped", result: scoped)
    }
  }

  private func benchInstanceBuildComparison(fontAtlas: FontAtlas) throws {
    let cols = 160
    let rows = 48
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let dirtySets: [(String, [Int])] = [
      ("row 0", [0]),
      ("row 23", [23]),
      ("rows 0,23 sparse", [0, 23]),
      ("rows 0,12,23 sparse", [0, 12, 23]),
      ("contiguous 1 row", [12]),
      ("contiguous 5 rows", Array(20..<25)),
    ]

    print("\n=== Instance-list rebuild only (160x48, release, microseconds) ===")
    print("  dirty-set                  path       p50/p95/p99 us      glyphs solids")
    defer { MetalRenderer.useClassicDamageScoped = true }
    for (label, dirtyRows) in dirtySets {
      let full = try measureInstanceBuild(
        scoped: false,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      let scoped = try measureInstanceBuild(
        scoped: true,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      printInstanceBuildRow(label: label, path: "full", result: full)
      printInstanceBuildRow(label: label, path: "scoped", result: scoped)
    }
  }

  private func benchGPUCellComparison(fontAtlas: FontAtlas) throws {
    guard #available(macOS 26, *) else {
      print("\n=== GPU cell path comparison skipped: requires macOS 26 ===")
      return
    }

    let cols = 160
    let rows = 48
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)

    print("\n=== Classic vs GPU-cell full-frame text path (160x48, release) ===")
    print("  path       n   cpu p50/p95/p99 ms   glyphs cellGlyphs solids")
    defer {
      MetalRenderer.useGPUCellPath = false
      MetalRenderer.useClassicDamageScoped = true
    }
    let classic = try measureFullFramePath(
      useGPUCell: false,
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      scale: scale,
      pixelW: pixelW,
      pixelH: pixelH,
      fontAtlas: fontAtlas)
    let gpuCell = try measureFullFramePath(
      useGPUCell: true,
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      scale: scale,
      pixelW: pixelW,
      pixelH: pixelH,
      fontAtlas: fontAtlas)
    printFullFrameRow(path: "classic", result: classic)
    printFullFrameRow(path: "gpuCell", result: gpuCell)
  }

  private func benchGPUCellPatchBuildComparison(fontAtlas: FontAtlas) throws {
    let cols = 160
    let rows = 48
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let dirtySets: [(String, [Int])] = [
      ("row 0", [0]),
      ("row 23", [23]),
      ("rows 0,23 sparse", [0, 23]),
      ("rows 0,12,23 sparse", [0, 12, 23]),
      ("contiguous 1 row", [12]),
      ("contiguous 5 rows", Array(20..<25)),
    ]

    print("\n=== GPU-cell build: full rebuild vs persistent dirty-row patch (160x48, us) ===")
    print("  dirty-set                  path       p50/p95/p99 us      cellGlyphs solids")
    defer { MetalRenderer.useGPUCellPath = false }
    for (label, dirtyRows) in dirtySets {
      let full = try measureGPUCellBuild(
        patchOnly: false,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      let patch = try measureGPUCellBuild(
        patchOnly: true,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      let payload = try measureGPUCellPayloadBuild(
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      printGPUCellBuildRow(label: label, path: "full", result: full)
      printGPUCellBuildRow(label: label, path: "patch", result: patch)
      printGPUCellBuildRow(label: label, path: "payload", result: payload)
    }
  }

  private struct DamageBenchResult {
    var timings: MetalRenderer.FrameTimings
    var counts: MetalRenderer.RenderInstanceCounts
  }

  private struct InstanceBuildBenchResult {
    var p50Us: Double
    var p95Us: Double
    var p99Us: Double
    var counts: MetalRenderer.RenderInstanceCounts
  }

  private func measureFullFramePath(
    useGPUCell: Bool,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    pixelW: Int,
    pixelH: Int,
    fontAtlas: FontAtlas
  ) throws -> DamageBenchResult {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: pixelW, pixelHeight: pixelH, scale: scale)
    MetalRenderer.useClassicDamageScoped = true
    MetalRenderer.useGPUCellPath = useGPUCell

    for i in 0..<12 {
      XCTAssertTrue(
        renderAccepted(
          renderer,
          commands: damageFrame(cols: cols, rows: rows, cellW: cellW, cellH: cellH, seed: i),
          damage: .full))
    }
    renderer.waitForLastFrame()
    renderer.resetFrameTimings()

    var accepted = 0
    var seed = 12
    while accepted < 120 && seed < 260 {
      if renderAccepted(
        renderer,
        commands: damageFrame(cols: cols, rows: rows, cellW: cellW, cellH: cellH, seed: seed),
        damage: .full)
      {
        accepted += 1
      }
      seed += 1
    }
    XCTAssertEqual(accepted, 120, "benchmark could not get enough accepted frames")
    renderer.waitForLastFrame()
    return DamageBenchResult(
      timings: renderer.recentFrameTimings(),
      counts: renderer.lastInstanceCounts)
  }

  private func printFullFrameRow(path: String, result: DamageBenchResult) {
    let t = result.timings
    print(
      String(
        format: "  %-8@ %3d   %.3f/%.3f/%.3f        %5d %10d %5d",
        path as NSString,
        t.sampleCount,
        t.cpuP50Ms,
        t.cpuP95Ms,
        t.cpuP99Ms,
        result.counts.glyphs + result.counts.sidebarGlyphs,
        result.counts.cellGlyphs,
        result.counts.solids))
  }

  private func measureClassicDamage(
    label _: String,
    scoped: Bool,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    pixelW: Int,
    pixelH: Int,
    fontAtlas: FontAtlas,
    dirtyRows: [Int]
  ) throws -> DamageBenchResult {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: pixelW, pixelHeight: pixelH, scale: scale)
    MetalRenderer.useClassicDamageScoped = scoped

    let initial = damageFrame(cols: cols, rows: rows, cellW: cellW, cellH: cellH, seed: 0)
    XCTAssertTrue(renderAccepted(renderer, commands: initial, damage: .full))
    renderer.waitForLastFrame()
    renderer.resetFrameTimings()

    let damage = RenderDamage.partial(
      yRanges: dirtyRows.map { row in
        DirtyYRange(y: CGFloat(rows - 1 - row) * cellH, height: cellH)
      })
    for i in 0..<12 {
      let frame = damageFrame(
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        seed: i + 1,
        changedRows: dirtyRows)
      _ = renderAccepted(renderer, commands: frame, damage: damage)
    }
    renderer.waitForLastFrame()
    renderer.resetFrameTimings()

    var accepted = 0
    var seed = 12
    while accepted < 120 && seed < 260 {
      let frame = damageFrame(
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        seed: seed + 1,
        changedRows: dirtyRows)
      if renderAccepted(renderer, commands: frame, damage: damage) {
        accepted += 1
      }
      seed += 1
    }
    XCTAssertEqual(accepted, 120, "benchmark could not get enough accepted frames")
    renderer.waitForLastFrame()
    return DamageBenchResult(
      timings: renderer.recentFrameTimings(),
      counts: renderer.lastInstanceCounts)
  }

  private func printDamageRow(label: String, path: String, result: DamageBenchResult) {
    let t = result.timings
    print(
      String(
        format: "  %-26@ %-8@ %3d   %.3f/%.3f/%.3f        %5d %5d",
        label as NSString,
        path as NSString,
        t.sampleCount,
        t.cpuP50Ms,
        t.cpuP95Ms,
        t.cpuP99Ms,
        result.counts.glyphs + result.counts.sidebarGlyphs,
        result.counts.solids))
  }

  private func measureInstanceBuild(
    scoped: Bool,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    surfacePxH: Int,
    fontAtlas: FontAtlas,
    dirtyRows: [Int]
  ) throws -> InstanceBuildBenchResult {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }
    MetalRenderer.useClassicDamageScoped = scoped
    let frame = damageFrame(
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      seed: 7,
      changedRows: dirtyRows)
    let damage = RenderDamage.partial(
      yRanges: dirtyRows.map { row in
        DirtyYRange(y: CGFloat(rows - 1 - row) * cellH, height: cellH)
      })

    // Warm atlas/cache and let the arrays settle at retained capacity.
    for _ in 0..<20 {
      _ = renderer.rebuildInstancesForTesting(
        commands: frame,
        damage: damage,
        surfacePxH: surfacePxH)
    }

    var samples: [Double] = []
    samples.reserveCapacity(240)
    var counts = MetalRenderer.RenderInstanceCounts()
    for _ in 0..<240 {
      let start = DispatchTime.now().uptimeNanoseconds
      counts = renderer.rebuildInstancesForTesting(
        commands: frame,
        damage: damage,
        surfacePxH: surfacePxH)
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000.0)
    }
    return InstanceBuildBenchResult(
      p50Us: percentile(samples, 0.50),
      p95Us: percentile(samples, 0.95),
      p99Us: percentile(samples, 0.99),
      counts: counts)
  }

  private func measureGPUCellBuild(
    patchOnly: Bool,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    surfacePxH: Int,
    fontAtlas: FontAtlas,
    dirtyRows: [Int]
  ) throws -> InstanceBuildBenchResult {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }
    MetalRenderer.useGPUCellPath = true
    let initial = damageFrame(cols: cols, rows: rows, cellW: cellW, cellH: cellH, seed: 0)
    guard
      renderer.rebuildGPUCellInstancesForTesting(
        commands: initial,
        damage: .full,
        surfacePxH: surfacePxH) != nil
    else {
      XCTFail("GPU cell builder rejected initial plain-text frame")
      throw XCTSkip("GPU cell builder unavailable")
    }

    let frame = damageFrame(
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      seed: 7,
      changedRows: dirtyRows)
    let damage = RenderDamage.partial(
      yRanges: dirtyRows.map { row in
        DirtyYRange(y: CGFloat(rows - 1 - row) * cellH, height: cellH)
      })

    for _ in 0..<20 {
      _ = renderer.rebuildGPUCellInstancesForTesting(
        commands: frame,
        damage: patchOnly ? damage : .full,
        surfacePxH: surfacePxH)
    }

    var samples: [Double] = []
    samples.reserveCapacity(240)
    var counts = MetalRenderer.RenderInstanceCounts()
    for _ in 0..<240 {
      let start = DispatchTime.now().uptimeNanoseconds
      counts =
        renderer.rebuildGPUCellInstancesForTesting(
          commands: frame,
          damage: patchOnly ? damage : .full,
          surfacePxH: surfacePxH) ?? MetalRenderer.RenderInstanceCounts()
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000.0)
    }
    return InstanceBuildBenchResult(
      p50Us: percentile(samples, 0.50),
      p95Us: percentile(samples, 0.95),
      p99Us: percentile(samples, 0.99),
      counts: counts)
  }

  private func measureGPUCellPayloadBuild(
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    surfacePxH: Int,
    fontAtlas: FontAtlas,
    dirtyRows: [Int]
  ) throws -> InstanceBuildBenchResult {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }
    let initial = damagePayload(
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      seed: 0,
      includedRows: Array(0..<rows))
    guard
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: initial,
        commands: [],
        damage: .full,
        surfacePxH: surfacePxH) != nil
    else {
      XCTFail("GPU cell payload builder rejected initial plain-text frame")
      throw XCTSkip("GPU cell payload builder unavailable")
    }

    let payload = damagePayload(
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      seed: 7,
      changedRows: dirtyRows,
      includedRows: dirtyRows)
    let damage = RenderDamage.partial(
      yRanges: dirtyRows.map { row in
        DirtyYRange(y: CGFloat(rows - 1 - row) * cellH, height: cellH)
      })

    for _ in 0..<20 {
      _ = renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: payload,
        commands: [],
        damage: damage,
        surfacePxH: surfacePxH)
    }

    var samples: [Double] = []
    samples.reserveCapacity(240)
    var counts = MetalRenderer.RenderInstanceCounts()
    for _ in 0..<240 {
      let start = DispatchTime.now().uptimeNanoseconds
      counts =
        renderer.rebuildGPUCellPayloadInstancesForTesting(
          payload: payload,
          commands: [],
          damage: damage,
          surfacePxH: surfacePxH) ?? MetalRenderer.RenderInstanceCounts()
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000.0)
    }
    return InstanceBuildBenchResult(
      p50Us: percentile(samples, 0.50),
      p95Us: percentile(samples, 0.95),
      p99Us: percentile(samples, 0.99),
      counts: counts)
  }

  private func printGPUCellBuildRow(
    label: String,
    path: String,
    result: InstanceBuildBenchResult
  ) {
    print(
      String(
        format: "  %-26@ %-8@ %.1f/%.1f/%.1f        %10d %5d",
        label as NSString,
        path as NSString,
        result.p50Us,
        result.p95Us,
        result.p99Us,
        result.counts.cellGlyphs,
        result.counts.solids))
  }

  private func printInstanceBuildRow(
    label: String,
    path: String,
    result: InstanceBuildBenchResult
  ) {
    print(
      String(
        format: "  %-26@ %-8@ %.1f/%.1f/%.1f        %5d %5d",
        label as NSString,
        path as NSString,
        result.p50Us,
        result.p95Us,
        result.p99Us,
        result.counts.glyphs + result.counts.sidebarGlyphs,
        result.counts.solids))
  }

  private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
  }

  private func renderAccepted(
    _ renderer: MetalRenderer,
    commands: [FrameCommand],
    damage: RenderDamage
  ) -> Bool {
    for _ in 0..<4 {
      if renderer.render(commands, damage: damage) {
        return true
      }
      renderer.waitForLastFrame()
      Thread.sleep(forTimeInterval: 0.001)
    }
    return false
  }

  private func damageFrame(
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    seed: Int,
    changedRows: [Int] = []
  ) -> [FrameCommand] {
    let changed = Set(changedRows)
    let asciiPrintable = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    var commands: [FrameCommand] = []
    commands.reserveCapacity(rows * 2 + 1)
    for r in 0..<rows {
      let rowSeed = seed + r + (changed.contains(r) ? seed * 13 : 0)
      let color: UInt32 =
        (UInt32((rowSeed * 37) & 0xFF) << 24)
        | (UInt32((rowSeed * 89) & 0xFF) << 16)
        | (UInt32((rowSeed * 167) & 0xFF) << 8) | 0xFF
      let y = CGFloat(rows - 1 - r) * cellH
      commands.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: color, source: .terminal))
      let start = rowSeed % asciiPrintable.count
      let chars = String((asciiPrintable + asciiPrintable).dropFirst(start).prefix(cols))
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: y),
          text: chars,
          foreground: 0xFF_FF_FF_FF,
          background: color,
          attributes: [],
          source: .terminal))
    }
    commands.append(
      .cursor(
        CGRect(x: 0, y: 0, width: cellW, height: cellH),
        color: 0xAD_BC_BC_FF))
    return commands
  }

  private func damagePayload(
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    seed: Int,
    changedRows: [Int] = [],
    includedRows: [Int]
  ) -> TerminalCellPayload {
    let changed = Set(changedRows)
    let asciiPrintable = (0x21...0x7E).map { String(UnicodeScalar($0)!) }
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: 0x00_00_00_FF,
      dirtyRows: includedRows)
    payload.backgroundRuns.reserveCapacity(includedRows.count)
    payload.glyphs.reserveCapacity(includedRows.count * cols)
    for r in includedRows {
      let rowSeed = seed + r + (changed.contains(r) ? seed * 13 : 0)
      let color: UInt32 =
        (UInt32((rowSeed * 37) & 0xFF) << 24)
        | (UInt32((rowSeed * 89) & 0xFF) << 16)
        | (UInt32((rowSeed * 167) & 0xFF) << 8) | 0xFF
      payload.backgroundRuns.append(.init(row: r, startCol: 0, colCount: cols, color: color))
      let start = rowSeed % asciiPrintable.count
      for c in 0..<cols {
        let text = asciiPrintable[(start + c) % asciiPrintable.count]
        payload.glyphs.append(
          .init(
            row: r,
            col: c,
            text: text,
            scalarValue: text.unicodeScalars.first?.value,
            foreground: 0xFF_FF_FF_FF,
            background: color,
            attributes: []))
      }
    }
    payload.cursorRects.append(
      .init(rect: CGRect(x: 0, y: 0, width: cellW, height: cellH), color: 0xAD_BC_BC_FF))
    return payload
  }
}
