import CoreGraphics
import Darwin
import Dispatch
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
    try benchM6HeadToHeadComparison(fontAtlas: fontAtlas)
    try benchInstanceBuildComparison(fontAtlas: fontAtlas)
    try benchMetal4EncodeOverheadSpike()
  }

  func testGPUCellPayloadBuilderMicrobench() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    let cols = 160
    let rows = 48
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let surfacePxH = Int(CGFloat(rows) * cellH * scale)
    let cases: [PayloadBuilderMicroCase] = [
      .init(
        label: "plain 1 row",
        workload: .init(label: "plain 1 row", style: .ascii, dirtyRows: [rows - 1])),
      .init(
        label: "plain 5 rows",
        workload: .init(label: "plain 5 rows", style: .ascii, dirtyRows: Array(20..<25))),
      .init(
        label: "sparse full-union",
        workload: .init(label: "sparse full-union", style: .ascii, dirtyRows: [0, rows - 1])),
      .init(
        label: "dense colors",
        workload: .init(label: "dense colors", style: .denseColor, dirtyRows: Array(20..<25))),
      .init(
        label: "decorated 5 rows",
        workload: .init(label: "decorated 5 rows", style: .ascii, dirtyRows: Array(20..<25)),
        decorateEvery: 5),
      .init(
        label: "sidebar active",
        workload: .init(label: "sidebar active", style: .ascii, dirtyRows: Array(20..<25)),
        commandMix: .sidebar),
      .init(
        label: "overlay+preedit",
        workload: .init(label: "overlay+preedit", style: .ascii, dirtyRows: Array(20..<25)),
        commandMix: .overlayPreedit),
      .init(
        label: "sidebar+overlay",
        workload: .init(label: "sidebar+overlay", style: .ascii, dirtyRows: [0, 12, 23, rows - 1]),
        commandMix: .sidebarOverlayPreedit),
      .init(
        label: "full repaint",
        workload: .init(
          label: "full repaint", style: .ascii, dirtyRows: Array(0..<rows), fullDamage: true)),
      .init(
        label: "fast scroll",
        workload: .init(
          label: "fast scroll", style: .ascii, dirtyRows: Array(0..<rows), fullDamage: true,
          contentYOffset: -cellH / 2)),
    ]

    let samples =
      ProcessInfo.processInfo.environment["LABAN_BENCH_PAYLOAD_SAMPLES"].flatMap(Int.init)
      ?? 240
    print("\n=== GPU-cell payload builder microbench (160x48, release, us) ===")
    print("  case                  path       p50/p95/p99 us      cellGlyphs solids sidebar")
    for benchCase in cases {
      let build = try measureGPUCellPayloadBuilderMicroCase(
        benchCase,
        includeUpload: false,
        samples: samples,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: surfacePxH,
        fontAtlas: fontAtlas)
      let upload = try measureGPUCellPayloadBuilderMicroCase(
        benchCase,
        includeUpload: true,
        samples: samples,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: surfacePxH,
        fontAtlas: fontAtlas)
      printPayloadBuilderMicroRow(label: benchCase.label, path: "build", result: build)
      printPayloadBuilderMicroRow(label: benchCase.label, path: "+upload", result: upload)
    }
  }

  func testGPUCellRenderMicrobench() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    let cols = 160
    let rows = 48
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let reps =
      ProcessInfo.processInfo.environment["LABAN_BENCH_RENDER_REPS"].flatMap(Int.init) ?? 2
    let frames =
      ProcessInfo.processInfo.environment["LABAN_BENCH_RENDER_FRAMES"].flatMap(Int.init) ?? 40
    let workloads: [M6Workload] = [
      .init(label: "1-row append", style: .ascii, dirtyRows: [rows - 1]),
      .init(label: "5-row contiguous", style: .ascii, dirtyRows: Array(20..<25)),
      .init(label: "sparse rows", style: .ascii, dirtyRows: [0, 23, rows - 1]),
      .init(label: "full repaint", style: .ascii, dirtyRows: Array(0..<rows), fullDamage: true),
      .init(
        label: "fast scroll", style: .ascii, dirtyRows: Array(0..<rows), fullDamage: true,
        contentYOffset: -cellH / 2),
    ]

    print(
      "\n=== GPU-cell render microbench (160x48, release; median of \(reps)x\(frames)) ===")
    print(
      "  workload             path       cpu p50/p95/p99 ms   pCPU/fr  drop  taskuJ/fr wk/fr  socGPUuJ/fr socCPUuJ/fr"
    )
    for workload in workloads {
      let result = try measureM6HeadToHead(
        workload: workload,
        useGPUCell: true,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        pixelW: pixelW,
        pixelH: pixelH,
        fontAtlas: fontAtlas,
        repsOverride: reps,
        targetOverride: frames)
      printM6HeadToHeadRow(label: workload.label, path: "gpuCell", result: result)
    }
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
        format:
          "  [%@]  n=%d  cpu p50/p95/p99=%.3f/%.3f/%.3f ms  gpu p50/p95/p99=%.3f/%.3f/%.3f ms",
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
      ("rows 0,47 full-union", [0, 47]),
      ("contiguous 1 row", [12]),
      ("contiguous 5 rows", Array(20..<25)),
    ]
    // C1: a payload that also carries the full-viewport terminal-area background
    // rect. On a sparse partial the damage-union scissor spans the surface, so
    // the fix must keep `solids` equal to the no-background payload row (the
    // surface-wide rect is skipped). A regression that re-appends it inflates
    // the `payload+bg` solids count.
    let terminalBg: UInt32 = 0x10_20_30_FF

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
        includeUpload: false,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      let payloadUpload = try measureGPUCellPayloadBuild(
        includeUpload: true,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows)
      let payloadBg = try measureGPUCellPayloadBuild(
        includeUpload: false,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows,
        terminalBackground: terminalBg)
      let payloadBgUpload = try measureGPUCellPayloadBuild(
        includeUpload: true,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        surfacePxH: pixelH,
        fontAtlas: fontAtlas,
        dirtyRows: dirtyRows,
        terminalBackground: terminalBg)
      printGPUCellBuildRow(label: label, path: "full", result: full)
      printGPUCellBuildRow(label: label, path: "patch", result: patch)
      printGPUCellBuildRow(label: label, path: "payload", result: payload)
      printGPUCellBuildRow(label: label, path: "payload+upload", result: payloadUpload)
      printGPUCellBuildRow(label: label, path: "payload+bg", result: payloadBg)
      printGPUCellBuildRow(label: label, path: "pl+bg+upload", result: payloadBgUpload)
    }
  }

  private func benchMetal4EncodeOverheadSpike() throws {
    guard #available(macOS 26, *) else {
      print("\n=== Metal 4 encode spike skipped: requires macOS 26 ===")
      return
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    guard let queue = device.makeCommandQueue(),
      let mtl4Queue = device.makeMTL4CommandQueue(),
      let allocator = device.makeCommandAllocator(),
      let commandBuffer = device.makeCommandBuffer()
    else {
      throw XCTSkip("Metal 4 command model unavailable")
    }

    let pipeline = try makeEncodeSpikePipeline(device: device)
    let texture = try makeEncodeSpikeTexture(device: device)
    let argumentTable = try makeEncodeSpikeArgumentTable(device: device, texture: texture)

    let legacy = try measureLegacyEncodeSpike(
      queue: queue,
      pipeline: pipeline,
      texture: texture)
    let metal4 = try measureMetal4EncodeSpike(
      queue: mtl4Queue,
      allocator: allocator,
      commandBuffer: commandBuffer,
      pipeline: pipeline,
      texture: texture,
      argumentTable: argumentTable)
    let delta = legacy.p50Us - metal4.p50Us
    print("\n=== Metal 4 command-model encode proof spike (single render pass, us) ===")
    print("  path       p50/p95/p99 us")
    printEncodeSpikeRow(path: "legacy", result: legacy)
    printEncodeSpikeRow(path: "metal4", result: metal4)
    print(String(format: "  delta p50  %.2f us (positive means Metal 4 encoded faster)", delta))
  }

  private struct EncodeSpikeResult {
    var p50Us: Double
    var p95Us: Double
    var p99Us: Double
  }

  private func makeEncodeSpikePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
    let source = """
      #include <metal_stdlib>
      using namespace metal;
      struct VertexOut {
        float4 position [[position]];
      };
      vertex VertexOut encode_spike_vertex(uint vertexID [[vertex_id]]) {
        constexpr float2 points[3] = {
          float2(-1.0, -1.0),
          float2( 3.0, -1.0),
          float2(-1.0,  3.0)
        };
        VertexOut out;
        out.position = float4(points[vertexID], 0.0, 1.0);
        return out;
      }
      fragment float4 encode_spike_fragment() {
        return float4(0.05, 0.10, 0.15, 1.0);
      }
      """
    let library = try device.makeLibrary(source: source, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.label = "laban.encode-spike"
    desc.vertexFunction = library.makeFunction(name: "encode_spike_vertex")
    desc.fragmentFunction = library.makeFunction(name: "encode_spike_fragment")
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: desc)
  }

  private func makeEncodeSpikeTexture(device: MTLDevice) throws -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: 160 * 9 * 2,
      height: 48 * 19 * 2,
      mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    guard let texture = device.makeTexture(descriptor: desc) else {
      throw XCTSkip("could not allocate encode spike texture")
    }
    return texture
  }

  @available(macOS 26, *)
  private func makeEncodeSpikeArgumentTable(
    device: MTLDevice,
    texture: MTLTexture
  ) throws -> any MTL4ArgumentTable {
    let desc = MTL4ArgumentTableDescriptor()
    desc.maxTextureBindCount = 1
    desc.initializeBindings = true
    desc.label = "laban.encode-spike.argument-table"
    let table = try device.makeArgumentTable(descriptor: desc)
    table.setTexture(texture.gpuResourceID, index: 0)
    return table
  }

  private func measureLegacyEncodeSpike(
    queue: MTLCommandQueue,
    pipeline: MTLRenderPipelineState,
    texture: MTLTexture
  ) throws -> EncodeSpikeResult {
    var pending: MTLCommandBuffer?
    defer { pending?.waitUntilCompleted() }
    for _ in 0..<40 {
      _ = try encodeLegacySpike(
        queue: queue,
        pipeline: pipeline,
        texture: texture,
        pending: &pending)
    }
    var samples: [Double] = []
    samples.reserveCapacity(240)
    for _ in 0..<240 {
      let encodeUs = try encodeLegacySpike(
        queue: queue,
        pipeline: pipeline,
        texture: texture,
        pending: &pending)
      samples.append(encodeUs)
    }
    return EncodeSpikeResult(
      p50Us: percentile(samples, 0.50),
      p95Us: percentile(samples, 0.95),
      p99Us: percentile(samples, 0.99))
  }

  private func encodeLegacySpike(
    queue: MTLCommandQueue,
    pipeline: MTLRenderPipelineState,
    texture: MTLTexture,
    pending: inout MTLCommandBuffer?
  ) throws -> Double {
    pending?.waitUntilCompleted()
    let start = DispatchTime.now().uptimeNanoseconds
    guard let commandBuffer = queue.makeCommandBuffer() else {
      throw XCTSkip("could not allocate legacy command buffer")
    }
    let pass = MTLRenderPassDescriptor()
    let attachment = pass.colorAttachments[0]!
    attachment.texture = texture
    attachment.loadAction = .clear
    attachment.storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw XCTSkip("could not allocate legacy render encoder")
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    let end = DispatchTime.now().uptimeNanoseconds
    commandBuffer.commit()
    pending = commandBuffer
    return Double(end - start) / 1_000.0
  }

  @available(macOS 26, *)
  private func measureMetal4EncodeSpike(
    queue: any MTL4CommandQueue,
    allocator: any MTL4CommandAllocator,
    commandBuffer: any MTL4CommandBuffer,
    pipeline: MTLRenderPipelineState,
    texture: MTLTexture,
    argumentTable: any MTL4ArgumentTable
  ) throws -> EncodeSpikeResult {
    let feedbackSemaphore = DispatchSemaphore(value: 1)
    for _ in 0..<40 {
      _ = try encodeMetal4Spike(
        queue: queue,
        allocator: allocator,
        commandBuffer: commandBuffer,
        pipeline: pipeline,
        texture: texture,
        argumentTable: argumentTable,
        feedbackSemaphore: feedbackSemaphore)
    }
    var samples: [Double] = []
    samples.reserveCapacity(240)
    for _ in 0..<240 {
      let encodeUs = try encodeMetal4Spike(
        queue: queue,
        allocator: allocator,
        commandBuffer: commandBuffer,
        pipeline: pipeline,
        texture: texture,
        argumentTable: argumentTable,
        feedbackSemaphore: feedbackSemaphore)
      samples.append(encodeUs)
    }
    feedbackSemaphore.wait()
    feedbackSemaphore.signal()
    return EncodeSpikeResult(
      p50Us: percentile(samples, 0.50),
      p95Us: percentile(samples, 0.95),
      p99Us: percentile(samples, 0.99))
  }

  @available(macOS 26, *)
  private func encodeMetal4Spike(
    queue: any MTL4CommandQueue,
    allocator: any MTL4CommandAllocator,
    commandBuffer: any MTL4CommandBuffer,
    pipeline: MTLRenderPipelineState,
    texture: MTLTexture,
    argumentTable: any MTL4ArgumentTable,
    feedbackSemaphore: DispatchSemaphore
  ) throws -> Double {
    feedbackSemaphore.wait()
    allocator.reset()
    let start = DispatchTime.now().uptimeNanoseconds
    commandBuffer.beginCommandBuffer(allocator: allocator)
    let pass = MTL4RenderPassDescriptor()
    let attachment = pass.colorAttachments[0]!
    attachment.texture = texture
    attachment.loadAction = .clear
    attachment.storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass, options: []) else {
      feedbackSemaphore.signal()
      throw XCTSkip("could not allocate Metal 4 render encoder")
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setArgumentTable(argumentTable, stages: .fragment)
    encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    commandBuffer.endCommandBuffer()
    let end = DispatchTime.now().uptimeNanoseconds

    let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in
      if let error = feedback.error {
        print("Metal 4 encode spike feedback error: \(error)")
      }
      feedbackSemaphore.signal()
    }
    queue.commit([commandBuffer], options: options)
    return Double(end - start) / 1_000.0
  }

  private func printEncodeSpikeRow(path: String, result: EncodeSpikeResult) {
    print(
      String(
        format: "  %-8@ %.2f/%.2f/%.2f",
        path as NSString,
        result.p50Us,
        result.p95Us,
        result.p99Us))
  }

  private struct DamageBenchResult {
    var timings: MetalRenderer.FrameTimings
    var counts: MetalRenderer.RenderInstanceCounts
  }

  private struct M6Workload {
    enum Style {
      case ascii
      case denseColor
      case boxDrawing
      case clusters
      case atlasGrowth
    }

    var label: String
    var style: Style
    var dirtyRows: [Int]
    var fullDamage: Bool = false
    var contentYOffset: CGFloat = 0
    var rendererFallbackReason: String? = nil
  }

  private enum PayloadCommandMix {
    case none
    case sidebar
    case overlayPreedit
    case sidebarOverlayPreedit
  }

  private struct PayloadBuilderMicroCase {
    var label: String
    var workload: M6Workload
    var commandMix: PayloadCommandMix = .none
    var decorateEvery = 0
  }

  private struct M6HeadToHeadResult {
    var timings: MetalRenderer.FrameTimings
    var counts: MetalRenderer.RenderInstanceCounts
    var processCPUMsPerFrame: Double
    var droppedFrames: Int
    var energyMicrojoulesPerFrame: Double
    var wakeupsPerFrame: Double
    var socGPUEnergyMicrojoulesPerFrame: Double
    var socCPUEnergyMicrojoulesPerFrame: Double
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

  private func benchM6HeadToHeadComparison(fontAtlas: FontAtlas) throws {
    guard #available(macOS 26, *) else {
      print("\n=== M6 head-to-head comparison skipped: GPU-driven path requires macOS 26 ===")
      return
    }

    let cols = 160
    let rows = 48
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let workloads: [M6Workload] = [
      .init(label: "0-dirty cursor blink", style: .ascii, dirtyRows: []),
      .init(label: "1-row append", style: .ascii, dirtyRows: [rows - 1]),
      .init(label: "5pct contiguous", style: .ascii, dirtyRows: Array(20..<23)),
      .init(label: "25pct contiguous", style: .ascii, dirtyRows: Array(18..<30)),
      .init(label: "sparse dirty rows", style: .ascii, dirtyRows: [0, 12, 23, rows - 1]),
      .init(label: "full repaint", style: .ascii, dirtyRows: Array(0..<rows), fullDamage: true),
      .init(
        label: "fast scroll", style: .ascii, dirtyRows: Array(0..<rows), fullDamage: true,
        contentYOffset: -cellH / 2),
      .init(label: "dense colors", style: .denseColor, dirtyRows: Array(20..<23)),
      .init(label: "box drawing", style: .boxDrawing, dirtyRows: Array(20..<23)),
      .init(label: "emoji cjk zwj", style: .clusters, dirtyRows: Array(20..<23)),
      .init(
        label: "theme atlas growth", style: .atlasGrowth, dirtyRows: Array(0..<rows),
        fullDamage: true),
      .init(
        label: "remote fallback",
        style: .ascii,
        dirtyRows: Array(20..<23),
        rendererFallbackReason: "remoteSnapshotPayloadIncomplete"),
    ]

    let m6Reps = max(
      1, ProcessInfo.processInfo.environment["LABAN_BENCH_M6_REPS"].flatMap(Int.init) ?? 7)
    let m6Frames = max(
      1, ProcessInfo.processInfo.environment["LABAN_BENCH_M6_FRAMES"].flatMap(Int.init) ?? 80)
    print(
      "\n=== M6 head-to-head renderer comparison (160x48, release; "
        + "median of \(m6Reps) windows x \(m6Frames) frames) ===")
    print(
      "  workload             path       cpu p50/p95/p99 ms   pCPU/fr  drop  taskuJ/fr wk/fr  socGPUuJ/fr socCPUuJ/fr"
    )
    defer {
      MetalRenderer.useGPUCellPath = false
      MetalRenderer.useClassicDamageScoped = true
    }
    for workload in workloads {
      let classic = try measureM6HeadToHead(
        workload: workload,
        useGPUCell: false,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        pixelW: pixelW,
        pixelH: pixelH,
        fontAtlas: fontAtlas)
      let gpu = try measureM6HeadToHead(
        workload: workload,
        useGPUCell: true,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        scale: scale,
        pixelW: pixelW,
        pixelH: pixelH,
        fontAtlas: fontAtlas)
      printM6HeadToHeadRow(label: workload.label, path: "classic", result: classic)
      printM6HeadToHeadRow(label: workload.label, path: "gpuCell", result: gpu)
    }
    print(
      "  per-frame energy/CPU/wakeup columns are the MEDIAN across the repeated windows"
        + " (env: LABAN_BENCH_M6_REPS, LABAN_BENCH_M6_FRAMES).")
    print(
      "  taskuJ/fr = task_info(TASK_POWER_INFO_V2) task_energy delta / frame (per-process,"
        + " relative same-HW A/B); wk/fr = (interrupt+idle) wakeups / frame.")
    print(
      "  socGPUuJ/fr, socCPUuJ/fr = IOReport \"Energy Model\" GPU/CPU energy / frame"
        + " (sudo-less, SoC-wide incl. WindowServer; the classic-vs-gpuCell difference is"
        + (socEnergySampler == nil ? " UNAVAILABLE: IOReport init failed)." : " the signal)."))
  }

  private func measureM6HeadToHead(
    workload: M6Workload,
    useGPUCell: Bool,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    pixelW: Int,
    pixelH: Int,
    fontAtlas: FontAtlas,
    repsOverride: Int? = nil,
    targetOverride: Int? = nil
  ) throws -> M6HeadToHeadResult {
    let mode: RendererMode = useGPUCell ? .gpuDriven : .classic
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale, rendererMode: mode)
    else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: pixelW, pixelHeight: pixelH, scale: scale)
    MetalRenderer.useClassicDamageScoped = true
    MetalRenderer.useGPUCellPath = false

    let includedRows = measuredRows(for: workload, rows: rows)
    let damage = m6Damage(for: workload, rows: rows, cellH: cellH)
    func render(_ frame: (commands: [FrameCommand], payload: TerminalCellPayload?)) -> Bool {
      renderAccepted(
        renderer, commands: frame.commands, payload: frame.payload, damage: damage,
        rendererFallbackReason: workload.rendererFallbackReason)
    }

    let initialCommands = m6Commands(
      workload: workload, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
      seed: 0, includedRows: Array(0..<rows))
    let initialPayload = m6Payload(
      workload: workload, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
      seed: 0, includedRows: Array(0..<rows))
    XCTAssertTrue(
      renderAccepted(
        renderer, commands: initialCommands,
        payload: useGPUCell ? initialPayload : nil, damage: .full,
        rendererFallbackReason: workload.rendererFallbackReason))
    renderer.waitForLastFrame()

    let reps = max(
      1,
      repsOverride
        ?? ProcessInfo.processInfo.environment["LABAN_BENCH_M6_REPS"].flatMap(Int.init) ?? 7)
    let target = max(
      1,
      targetOverride
        ?? ProcessInfo.processInfo.environment["LABAN_BENCH_M6_FRAMES"].flatMap(Int.init) ?? 80)

    // Pre-build the frame inputs OUTSIDE the timing brackets. The bench's
    // per-cell payload/command construction (thousands of Glyph structs, each
    // with a String) otherwise dominates the measured CPU and masks the
    // renderer's own per-frame cost, which is the quantity under comparison. A
    // small pool cycled across the window keeps content varying frame to frame
    // so the renderer can't no-op identical frames.
    let poolSize = min(target, 24)
    var pool: [(commands: [FrameCommand], payload: TerminalCellPayload?)] = []
    pool.reserveCapacity(poolSize)
    for k in 0..<poolSize {
      let s = 8 + k
      pool.append(
        (
          commands: m6Commands(
            workload: workload, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
            seed: s, includedRows: includedRows),
          payload: useGPUCell
            ? m6Payload(
              workload: workload, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
              seed: s, includedRows: includedRows) : nil
        ))
    }

    // One unmeasured warm window so atlas, pipelines, and persistent target are
    // hot before the first measured window.
    for frame in pool { _ = render(frame) }
    renderer.waitForLastFrame()

    var procCPUSamples: [Double] = []
    var taskEnergySamples: [Double] = []
    var wakeupSamples: [Double] = []
    var socGPUSamples: [Double] = []
    var socCPUSamples: [Double] = []
    var lastTimings = renderer.recentFrameTimings()
    var lastCounts = renderer.lastInstanceCounts
    var droppedTotal = 0

    for _ in 0..<reps {
      renderer.resetFrameTimings()
      let cpuStart = processCPUSeconds()
      let energyStart = processEnergySample()
      let socStart = socEnergySampler?.sample() ?? (gpu: 0, cpu: 0)
      var accepted = 0
      var attempts = 0
      while accepted < target && attempts < target * 2 {
        let frame = pool[attempts % pool.count]
        attempts += 1
        if render(frame) { accepted += 1 }
      }
      let cpuEnd = processCPUSeconds()
      let energyEnd = processEnergySample()
      let socEnd = socEnergySampler?.sample() ?? (gpu: 0, cpu: 0)
      renderer.waitForLastFrame()

      let perFrame = Double(max(1, accepted))
      let taskEnergyDelta = energyEnd.energyNanojoules &- energyStart.energyNanojoules
      let wakeupsDelta =
        (energyEnd.interruptWakeups &- energyStart.interruptWakeups)
        + (energyEnd.idleWakeups &- energyStart.idleWakeups)
      procCPUSamples.append(((cpuEnd - cpuStart) * 1_000.0) / perFrame)
      taskEnergySamples.append(Double(taskEnergyDelta) / 1_000.0 / perFrame)
      wakeupSamples.append(Double(wakeupsDelta) / perFrame)
      socGPUSamples.append(Double(socEnd.gpu - socStart.gpu) / 1_000.0 / perFrame)
      socCPUSamples.append(Double(socEnd.cpu - socStart.cpu) / 1_000.0 / perFrame)
      droppedTotal += attempts - accepted
      lastTimings = renderer.recentFrameTimings()
      lastCounts = renderer.lastInstanceCounts
    }

    return M6HeadToHeadResult(
      timings: lastTimings,
      counts: lastCounts,
      processCPUMsPerFrame: median(procCPUSamples),
      droppedFrames: droppedTotal / reps,
      energyMicrojoulesPerFrame: median(taskEnergySamples),
      wakeupsPerFrame: median(wakeupSamples),
      socGPUEnergyMicrojoulesPerFrame: median(socGPUSamples),
      socCPUEnergyMicrojoulesPerFrame: median(socCPUSamples))
  }

  private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }

  private func renderAccepted(
    _ renderer: MetalRenderer,
    commands: [FrameCommand],
    payload: TerminalCellPayload?,
    damage: RenderDamage,
    rendererFallbackReason: String?
  ) -> Bool {
    for _ in 0..<4 {
      if renderer.render(
        commands,
        cellPayload: payload,
        damage: damage,
        rendererFallbackReason: rendererFallbackReason)
      {
        return true
      }
      renderer.waitForLastFrame()
      Thread.sleep(forTimeInterval: 0.001)
    }
    return false
  }

  private func printM6HeadToHeadRow(
    label: String,
    path: String,
    result: M6HeadToHeadResult
  ) {
    let t = result.timings
    print(
      String(
        format: "  %-20@ %-8@ %.3f/%.3f/%.3f   %.3f   %3d  %8.1f %6.2f  %9.1f %9.1f",
        label as NSString,
        path as NSString,
        t.cpuP50Ms,
        t.cpuP95Ms,
        t.cpuP99Ms,
        result.processCPUMsPerFrame,
        result.droppedFrames,
        result.energyMicrojoulesPerFrame,
        result.wakeupsPerFrame,
        result.socGPUEnergyMicrojoulesPerFrame,
        result.socCPUEnergyMicrojoulesPerFrame))
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
    includeUpload: Bool,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    surfacePxH: Int,
    fontAtlas: FontAtlas,
    dirtyRows: [Int],
    terminalBackground: UInt32? = nil
  ) throws -> InstanceBuildBenchResult {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }
    // Production appends a full-viewport terminal-area background rect alongside
    // the payload, and canSkipTerminalCommands does not remove it. Passing it
    // here exercises the C1 partial-frame path: on a sparse partial whose
    // damage-union scissor spans the surface, that rect must NOT be appended as
    // a surface-wide solid (which would overdraw and wipe clean interior rows).
    let extra: [FrameCommand] =
      terminalBackground.map {
        [
          .rect(
            CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
            color: $0, source: .terminal)
        ]
      } ?? []
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
        commands: extra,
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
      if includeUpload {
        _ = renderer.rebuildAndPrepareGPUCellPayloadInstancesForTesting(
          payload: payload,
          commands: extra,
          damage: damage,
          surfacePxH: surfacePxH)
      } else {
        _ = renderer.rebuildGPUCellPayloadInstancesForTesting(
          payload: payload,
          commands: extra,
          damage: damage,
          surfacePxH: surfacePxH)
      }
    }

    var samples: [Double] = []
    samples.reserveCapacity(240)
    var counts = MetalRenderer.RenderInstanceCounts()
    for _ in 0..<240 {
      let start = DispatchTime.now().uptimeNanoseconds
      if includeUpload {
        counts =
          renderer.rebuildAndPrepareGPUCellPayloadInstancesForTesting(
            payload: payload,
            commands: extra,
            damage: damage,
            surfacePxH: surfacePxH) ?? MetalRenderer.RenderInstanceCounts()
      } else {
        counts =
          renderer.rebuildGPUCellPayloadInstancesForTesting(
            payload: payload,
            commands: extra,
            damage: damage,
            surfacePxH: surfacePxH) ?? MetalRenderer.RenderInstanceCounts()
      }
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000.0)
    }
    return InstanceBuildBenchResult(
      p50Us: percentile(samples, 0.50),
      p95Us: percentile(samples, 0.95),
      p99Us: percentile(samples, 0.99),
      counts: counts)
  }

  private func measureGPUCellPayloadBuilderMicroCase(
    _ benchCase: PayloadBuilderMicroCase,
    includeUpload: Bool,
    samples sampleCount: Int,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    scale: CGFloat,
    surfacePxH: Int,
    fontAtlas: FontAtlas
  ) throws -> InstanceBuildBenchResult {
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      throw XCTSkip("MetalRenderer unavailable")
    }

    let initial = m6Payload(
      workload: benchCase.workload,
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
      XCTFail("GPU cell payload builder rejected initial frame")
      throw XCTSkip("GPU cell payload builder unavailable")
    }

    let includedRows =
      benchCase.workload.fullDamage ? Array(0..<rows) : benchCase.workload.dirtyRows
    let damage: RenderDamage =
      benchCase.workload.fullDamage
      ? .full
      : .partial(
        yRanges: includedRows.map { row in
          DirtyYRange(y: CGFloat(rows - 1 - row) * cellH, height: cellH)
        })

    let poolSize = min(max(1, sampleCount), 24)
    var pool: [(payload: TerminalCellPayload, commands: [FrameCommand])] = []
    pool.reserveCapacity(poolSize)
    for k in 0..<poolSize {
      let seed = 11 + k
      var payload = m6Payload(
        workload: benchCase.workload,
        cols: cols,
        rows: rows,
        cellW: cellW,
        cellH: cellH,
        seed: seed,
        includedRows: includedRows)
      applyPayloadBuilderDecoration(to: &payload, every: benchCase.decorateEvery)
      pool.append(
        (
          payload,
          payloadBuilderCommands(
            mix: benchCase.commandMix,
            cols: cols,
            rows: rows,
            cellW: cellW,
            cellH: cellH,
            seed: seed,
            dirtyRows: includedRows)
        ))
    }

    for frame in pool {
      if includeUpload {
        _ = renderer.rebuildAndPrepareGPUCellPayloadInstancesForTesting(
          payload: frame.payload,
          commands: frame.commands,
          damage: damage,
          surfacePxH: surfacePxH)
      } else {
        _ = renderer.rebuildGPUCellPayloadInstancesForTesting(
          payload: frame.payload,
          commands: frame.commands,
          damage: damage,
          surfacePxH: surfacePxH)
      }
    }

    var samples: [Double] = []
    samples.reserveCapacity(sampleCount)
    var counts = MetalRenderer.RenderInstanceCounts()
    for index in 0..<sampleCount {
      let frame = pool[index % pool.count]
      let start = DispatchTime.now().uptimeNanoseconds
      if includeUpload {
        counts =
          renderer.rebuildAndPrepareGPUCellPayloadInstancesForTesting(
            payload: frame.payload,
            commands: frame.commands,
            damage: damage,
            surfacePxH: surfacePxH) ?? MetalRenderer.RenderInstanceCounts()
      } else {
        counts =
          renderer.rebuildGPUCellPayloadInstancesForTesting(
            payload: frame.payload,
            commands: frame.commands,
            damage: damage,
            surfacePxH: surfacePxH) ?? MetalRenderer.RenderInstanceCounts()
      }
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000.0)
    }
    return InstanceBuildBenchResult(
      p50Us: percentile(samples, 0.50),
      p95Us: percentile(samples, 0.95),
      p99Us: percentile(samples, 0.99),
      counts: counts)
  }

  private func applyPayloadBuilderDecoration(
    to payload: inout TerminalCellPayload,
    every stride: Int
  ) {
    guard stride > 0 else { return }
    for index in payload.glyphs.indices where index.isMultiple(of: stride) {
      payload.glyphs[index].attributes.insert(.underline)
      payload.glyphs[index].underlineStyle = .single
      payload.glyphs[index].underlineColor = 0xFF_CC_33_FF
      payload.glyphs[index].hasHyperlink = true
    }
  }

  private func payloadBuilderCommands(
    mix: PayloadCommandMix,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    seed: Int,
    dirtyRows: [Int]
  ) -> [FrameCommand] {
    guard mix != .none else { return [] }
    var commands: [FrameCommand] = []
    let surfaceRect = CGRect(
      x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH)
    commands.append(.rect(surfaceRect, color: 0x10_20_30_FF, source: .terminal))

    let sidebarNeeded = mix == .sidebar || mix == .sidebarOverlayPreedit
    let overlayNeeded = mix == .overlayPreedit || mix == .sidebarOverlayPreedit
    if sidebarNeeded {
      let sidebarX = CGFloat(cols) * cellW
      for (offset, row) in dirtyRows.prefix(8).enumerated() {
        let y = CGFloat(rows - 1 - row) * cellH
        commands.append(
          .rect(
            CGRect(x: sidebarX, y: y, width: 144, height: cellH),
            color: 0x21_27_35_FF,
            source: .sidebar))
        commands.append(
          .glyphRun(
            origin: CGPoint(x: sidebarX + 6, y: y),
            text: "tab\(offset)-\(seed % 10)",
            foreground: 0xEE_F2_FF_FF,
            background: 0x21_27_35_FF,
            attributes: offset.isMultiple(of: 2) ? [.bold] : [],
            source: .sidebar,
            underlineStyle: offset.isMultiple(of: 3) ? .single : .none,
            underlineColor: 0x7D_BA_FF_FF))
      }
    }

    if overlayNeeded {
      for row in dirtyRows.prefix(4) {
        let y = CGFloat(rows - 1 - row) * cellH
        commands.append(
          .selection(
            CGRect(x: 12 * cellW, y: y, width: 18 * cellW, height: cellH),
            color: 0x3D_5A_80_99))
        commands.append(
          .findMatch(
            CGRect(x: 44 * cellW, y: y, width: 10 * cellW, height: cellH),
            color: 0xFF_CC_33_88))
      }
      let preeditRow = dirtyRows.last ?? max(0, rows - 1)
      let preeditY = CGFloat(rows - 1 - preeditRow) * cellH
      commands.append(
        .rect(
          CGRect(x: 3 * cellW, y: preeditY, width: 8 * cellW, height: cellH),
          color: 0x00_00_00_FF,
          source: .preedit))
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 3 * cellW, y: preeditY),
          text: "input\(seed % 10)",
          foreground: 0xFF_FF_FF_FF,
          background: 0x00_00_00_FF,
          attributes: [.underline],
          source: .preedit,
          underlineStyle: .single,
          underlineColor: 0xFF_FF_FF_FF))
    }
    return commands
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

  private func printPayloadBuilderMicroRow(
    label: String,
    path: String,
    result: InstanceBuildBenchResult
  ) {
    print(
      String(
        format: "  %-21@ %-8@ %.1f/%.1f/%.1f        %10d %5d %7d",
        label as NSString,
        path as NSString,
        result.p50Us,
        result.p95Us,
        result.p99Us,
        result.counts.cellGlyphs,
        result.counts.solids,
        result.counts.sidebarGlyphs))
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

  private func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return timevalSeconds(usage.ru_utime) + timevalSeconds(usage.ru_stime)
  }

  private struct EnergySample {
    var energyNanojoules: UInt64
    var interruptWakeups: UInt64
    var idleWakeups: UInt64
    var gpuTimeNanos: UInt64
  }

  // Per-process energy via task_info(TASK_POWER_INFO_V2). Apple Silicon only,
  // no root or entitlement. task_energy is an uncalibrated CLPC model value
  // (Apple DTS: only safe to compare runs on the same hardware), which is
  // exactly the classic-vs-gpuCell A/B here — so it is used as a relative
  // energy proxy, not absolute joules.
  private func processEnergySample() -> EnergySample {
    var info = task_power_info_v2()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
        task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), intPtr, &count)
      }
    }
    guard kr == KERN_SUCCESS else {
      return EnergySample(
        energyNanojoules: 0, interruptWakeups: 0, idleWakeups: 0, gpuTimeNanos: 0)
    }
    return EnergySample(
      energyNanojoules: info.task_energy,
      interruptWakeups: info.cpu_energy.task_interrupt_wakeups,
      idleWakeups: info.cpu_energy.task_platform_idle_wakeups,
      gpuTimeNanos: info.gpu_energy.task_gpu_utilisation)
  }

  // Lazily created once; nil on non-Apple-Silicon or if the private API is
  // unavailable, in which case the SoC energy columns read 0.
  private lazy var socEnergySampler: SoCEnergySampler? = SoCEnergySampler()

  // Sudo-less SoC energy via the IOReport "Energy Model" group
  // (/usr/lib/libIOReport.dylib, the macmon/socpowerbud approach). Reads the
  // aggregate "GPU Energy" and "CPU Energy" counters and deltas them around a
  // workload. Unlike task_info this is SoC-wide (not per-process): in a quiet
  // bench the test process is the dominant GPU client, and a constant
  // background offset cancels in the classic-vs-gpuCell difference. Values are
  // returned in nanojoules.
  final class SoCEnergySampler {
    private typealias FnCopyChannels =
      @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) ->
      Unmanaged<CFMutableDictionary>?
    private typealias FnCreateSub =
      @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
      ) -> UnsafeMutableRawPointer?
    private typealias FnCreateSamples =
      @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, CFTypeRef?) ->
      Unmanaged<CFDictionary>?
    private typealias FnChanName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias FnSimpleInt = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias FnIterate =
      @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void

    private let sub: UnsafeMutableRawPointer
    private let subbed: CFMutableDictionary
    private let createSamples: FnCreateSamples
    private let chanName: FnChanName
    private let simpleInt: FnSimpleInt
    private let iterate: FnIterate

    init?() {
      guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
      func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
      }
      guard
        let copy = sym("IOReportCopyChannelsInGroup", FnCopyChannels.self),
        let createSub = sym("IOReportCreateSubscription", FnCreateSub.self),
        let samples = sym("IOReportCreateSamples", FnCreateSamples.self),
        let name = sym("IOReportChannelGetChannelName", FnChanName.self),
        let simple = sym("IOReportSimpleGetIntegerValue", FnSimpleInt.self),
        let iter = sym("IOReportIterate", FnIterate.self)
      else { return nil }
      guard let chans = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
      else { return nil }
      var out: Unmanaged<CFMutableDictionary>?
      guard let s = createSub(nil, chans, &out, 0, nil), let got = out?.takeRetainedValue()
      else { return nil }
      sub = s
      subbed = got
      createSamples = samples
      chanName = name
      simpleInt = simple
      iterate = iter
    }

    // Accumulated (gpuNanojoules, cpuNanojoules). "GPU Energy" is reported in
    // nJ, "CPU Energy" in mJ; both normalised to nJ.
    func sample() -> (gpu: Int64, cpu: Int64) {
      guard let raw = createSamples(sub, subbed, nil)?.takeRetainedValue() else { return (0, 0) }
      var gpu: Int64 = 0
      var cpu: Int64 = 0
      iterate(raw) { ch in
        guard let nameRef = self.chanName(ch)?.takeUnretainedValue() else { return 0 }
        switch nameRef as String {
        case "GPU Energy": gpu = self.simpleInt(ch, 0)
        case "CPU Energy": cpu = self.simpleInt(ch, 0) * 1_000_000
        default: break
        }
        return 0
      }
      return (gpu, cpu)
    }
  }

  private func timevalSeconds(_ value: timeval) -> Double {
    Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000.0
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

  private func measuredRows(for workload: M6Workload, rows: Int) -> [Int] {
    workload.fullDamage ? Array(0..<rows) : workload.dirtyRows
  }

  private func m6Damage(for workload: M6Workload, rows: Int, cellH: CGFloat) -> RenderDamage {
    guard !workload.fullDamage else { return .full }
    return .partial(
      yRanges: measuredRows(for: workload, rows: rows).map { row in
        DirtyYRange(y: CGFloat(rows - 1 - row) * cellH + workload.contentYOffset, height: cellH)
      })
  }

  private func m6Commands(
    workload: M6Workload,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    seed: Int,
    includedRows: [Int]
  ) -> [FrameCommand] {
    var commands: [FrameCommand] = []
    commands.reserveCapacity(
      includedRows.count * (workload.style == .denseColor ? cols * 2 : 2) + 1)
    for row in includedRows {
      let y = CGFloat(rows - 1 - row) * cellH + workload.contentYOffset
      if workload.style == .denseColor {
        for col in 0..<cols {
          let color = m6Color(style: workload.style, row: row, col: col, seed: seed)
          let rect = CGRect(x: CGFloat(col) * cellW, y: y, width: cellW, height: cellH)
          commands.append(.rect(rect, color: color, source: .terminal))
          commands.append(
            .glyphRun(
              origin: rect.origin,
              text: m6Text(style: workload.style, row: row, col: col, seed: seed),
              foreground: 0xFF_FF_FF_FF,
              background: color,
              attributes: [],
              source: .terminal))
        }
      } else {
        let color = m6Color(style: workload.style, row: row, col: 0, seed: seed)
        commands.append(
          .rect(
            CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
            color: color,
            source: .terminal))
        let text = (0..<cols).map {
          m6Text(style: workload.style, row: row, col: $0, seed: seed)
        }.joined()
        commands.append(
          .glyphRun(
            origin: CGPoint(x: 0, y: y),
            text: text,
            foreground: 0xFF_FF_FF_FF,
            background: color,
            attributes: [],
            source: .terminal))
      }
    }
    let cursorY = max(0, workload.contentYOffset)
    commands.append(
      .cursor(
        CGRect(x: 0, y: cursorY, width: cellW, height: cellH),
        color: seed.isMultiple(of: 2) ? 0xAD_BC_BC_FF : 0xFF_FF_FF_FF))
    return commands
  }

  private func m6Payload(
    workload: M6Workload,
    cols: Int,
    rows: Int,
    cellW: CGFloat,
    cellH: CGFloat,
    seed: Int,
    includedRows: [Int]
  ) -> TerminalCellPayload {
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: workload.contentYOffset,
      defaultBackground: 0x00_00_00_FF,
      dirtyRows: includedRows)
    payload.backgroundRuns.reserveCapacity(
      workload.style == .denseColor ? includedRows.count * cols : includedRows.count)
    payload.glyphs.reserveCapacity(includedRows.count * cols)
    for row in includedRows {
      if workload.style == .denseColor {
        for col in 0..<cols {
          let color = m6Color(style: workload.style, row: row, col: col, seed: seed)
          payload.backgroundRuns.append(.init(row: row, startCol: col, colCount: 1, color: color))
          _ = appendM6Glyph(
            to: &payload,
            workload: workload,
            row: row,
            col: col,
            seed: seed,
            background: color)
        }
      } else {
        let color = m6Color(style: workload.style, row: row, col: 0, seed: seed)
        payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: color))
        var col = 0
        while col < cols {
          col += appendM6Glyph(
            to: &payload,
            workload: workload,
            row: row,
            col: col,
            seed: seed,
            background: color)
        }
      }
    }
    payload.cursorRects.append(
      .init(
        rect: CGRect(x: 0, y: max(0, workload.contentYOffset), width: cellW, height: cellH),
        color: seed.isMultiple(of: 2) ? 0xAD_BC_BC_FF : 0xFF_FF_FF_FF))
    return payload
  }

  private func appendM6Glyph(
    to payload: inout TerminalCellPayload,
    workload: M6Workload,
    row: Int,
    col: Int,
    seed: Int,
    background: UInt32
  ) -> Int {
    let text = m6Text(style: workload.style, row: row, col: col, seed: seed)
    let wide = m6WideFlag(for: text)
    payload.appendGlyph(
      row: row,
      col: col,
      cluster: text,
      foreground: 0xFF_FF_FF_FF,
      background: background,
      attributes: [],
      wide: wide)
    // Wide glyphs span the lead cell plus a trailing spacer the producer never
    // fills, so advance two columns and leave the spacer empty.
    return wide == 1 ? 2 : 1
  }

  private func m6Color(style: M6Workload.Style, row: Int, col: Int, seed: Int) -> UInt32 {
    let base = seed + row * 17 + col * (style == .denseColor ? 29 : 0)
    return
      (UInt32((base * 37) & 0xFF) << 24)
      | (UInt32((base * 89) & 0xFF) << 16)
      | (UInt32((base * 167) & 0xFF) << 8)
      | 0xFF
  }

  private func m6Text(style: M6Workload.Style, row: Int, col: Int, seed: Int) -> String {
    switch style {
    case .ascii, .denseColor:
      let scalars = Array(0x21...0x7E)
      return String(UnicodeScalar(scalars[(seed + row + col) % scalars.count])!)
    case .boxDrawing:
      let glyphs = ["┌", "─", "┐", "│", "└", "┘"]
      return glyphs[(seed + row + col) % glyphs.count]
    case .clusters:
      let glyphs = ["A", "表", "界", "👩‍💻", "ø", "ß"]
      return glyphs[(seed + row + col) % glyphs.count]
    case .atlasGrowth:
      let value = 0x2500 + ((seed * 97 + row * 31 + col) % 0x80)
      return UnicodeScalar(value).map(String.init) ?? "A"
    }
  }

  private func m6WideFlag(for text: String) -> UInt8 {
    // 1 == LABAN_CELL_WIDE_WIDE: the wide lead cell. A wide glyph's trailing
    // spacer cell (LABAN_CELL_WIDE_SPACER_TAIL == 2) carries no glyph in real
    // snapshots — FrameProducer skips it — so the payload tags only the lead as
    // wide and the builder leaves the spacer column empty. The previous value
    // (2) tagged the glyph itself as a spacer tail, which the GPU-cell payload
    // builder correctly rejects (unsupportedWideFlag), making this workload
    // spuriously unrenderable on the gpuCell path.
    switch text {
    case "表", "界", "👩‍💻":
      return 1
    default:
      return 0
    }
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
