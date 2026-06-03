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

  private struct M6HeadToHeadResult {
    var timings: MetalRenderer.FrameTimings
    var counts: MetalRenderer.RenderInstanceCounts
    var processCPUMsPerFrame: Double
    var droppedFrames: Int
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

    print("\n=== M6 head-to-head renderer comparison (160x48, release) ===")
    print(
      "  workload             path       cpu p50/p95/p99 ms   processCPU/frame ms   gpu p50/p99 ms   dropped energy/wakeups"
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
    print("  energy/wakeups: unavailable in XCTest; default decision treats this as no proven win")
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
    fontAtlas: FontAtlas
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

    let initialCommands = m6Commands(
      workload: workload,
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      seed: 0,
      includedRows: Array(0..<rows))
    let initialPayload = m6Payload(
      workload: workload,
      cols: cols,
      rows: rows,
      cellW: cellW,
      cellH: cellH,
      seed: 0,
      includedRows: Array(0..<rows))
    XCTAssertTrue(
      renderAccepted(
        renderer,
        commands: initialCommands,
        payload: useGPUCell ? initialPayload : nil,
        damage: .full,
        rendererFallbackReason: workload.rendererFallbackReason))
    renderer.waitForLastFrame()
    renderer.resetFrameTimings()

    for seed in 1..<8 {
      _ = renderAccepted(
        renderer,
        commands: m6Commands(
          workload: workload,
          cols: cols,
          rows: rows,
          cellW: cellW,
          cellH: cellH,
          seed: seed,
          includedRows: measuredRows(for: workload, rows: rows)),
        payload: useGPUCell
          ? m6Payload(
            workload: workload,
            cols: cols,
            rows: rows,
            cellW: cellW,
            cellH: cellH,
            seed: seed,
            includedRows: measuredRows(for: workload, rows: rows)) : nil,
        damage: m6Damage(for: workload, rows: rows, cellH: cellH),
        rendererFallbackReason: workload.rendererFallbackReason)
    }
    renderer.waitForLastFrame()
    renderer.resetFrameTimings()

    let cpuStart = processCPUSeconds()
    var accepted = 0
    var attempts = 0
    var seed = 8
    while accepted < 40 && seed < 120 {
      attempts += 1
      if renderAccepted(
        renderer,
        commands: m6Commands(
          workload: workload,
          cols: cols,
          rows: rows,
          cellW: cellW,
          cellH: cellH,
          seed: seed,
          includedRows: measuredRows(for: workload, rows: rows)),
        payload: useGPUCell
          ? m6Payload(
            workload: workload,
            cols: cols,
            rows: rows,
            cellW: cellW,
            cellH: cellH,
            seed: seed,
            includedRows: measuredRows(for: workload, rows: rows)) : nil,
        damage: m6Damage(for: workload, rows: rows, cellH: cellH),
        rendererFallbackReason: workload.rendererFallbackReason)
      {
        accepted += 1
      }
      seed += 1
    }
    let cpuEnd = processCPUSeconds()
    XCTAssertEqual(accepted, 40, "benchmark could not get enough accepted frames")
    renderer.waitForLastFrame()
    return M6HeadToHeadResult(
      timings: renderer.recentFrameTimings(),
      counts: renderer.lastInstanceCounts,
      processCPUMsPerFrame: ((cpuEnd - cpuStart) * 1_000.0) / Double(max(1, accepted)),
      droppedFrames: attempts - accepted)
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
        format: "  %-20@ %-8@ %.3f/%.3f/%.3f        %.3f              %.3f/%.3f       %3d     n/a",
        label as NSString,
        path as NSString,
        t.cpuP50Ms,
        t.cpuP95Ms,
        t.cpuP99Ms,
        result.processCPUMsPerFrame,
        t.gpuP50Ms,
        t.gpuP99Ms,
        result.droppedFrames))
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

  private func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return timevalSeconds(usage.ru_utime) + timevalSeconds(usage.ru_stime)
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
          appendM6Glyph(
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
        for col in 0..<cols {
          appendM6Glyph(
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
  ) {
    let text = m6Text(style: workload.style, row: row, col: col, seed: seed)
    let scalars = Array(text.unicodeScalars)
    payload.glyphs.append(
      .init(
        row: row,
        col: col,
        text: text,
        scalarValue: scalars.count == 1 ? scalars[0].value : nil,
        foreground: 0xFF_FF_FF_FF,
        background: background,
        attributes: [],
        wide: m6WideFlag(for: text)))
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
    switch text {
    case "表", "界", "👩‍💻":
      return 2
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
