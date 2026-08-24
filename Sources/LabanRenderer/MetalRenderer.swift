import CoreGraphics
import CoreText
import Darwin.Mach
import Foundation
import Metal
import QuartzCore
import os

// MARK: - Per-instance GPU types
//
// Layouts MUST match the structs in Shaders.metal exactly. Sizes and pads
// are commented; tweak with care if either side changes.

private struct SolidInstance {
  var origin: SIMD2<Float>  //  8
  var size: SIMD2<Float>  //  8
  var color: SIMD4<Float>  // 16  (rgba 0..1, straight alpha)
}

private struct GlyphInstance {
  var origin: SIMD2<Float>  //  8
  var size: SIMD2<Float>  //  8
  var uvOrigin: SIMD2<Float>  //  8
  var uvSize: SIMD2<Float>  //  8
  var color: SIMD4<Float>  // 16
}

private struct CellGlyph {
  var originPx: SIMD2<Float>  //  8
  var sizePx: SIMD2<Float>  //  8
  var uvOrigin: SIMD2<Float>  //  8
  var uvSize: SIMD2<Float>  //  8
  var flags: UInt32  //  4
  var _pad0: UInt32 = 0  //  4
  var _pad1: UInt32 = 0  //  4
  var _pad2: UInt32 = 0  //  4
  var fg: SIMD4<Float>  // 16
}

struct GPUCellGlyphRecord: Equatable, Sendable {
  var originPx: SIMD2<Float>
  var sizePx: SIMD2<Float>
  var uvOrigin: SIMD2<Float>
  var uvSize: SIMD2<Float>
  var color: SIMD4<Float>
  var flags: UInt32
}

private struct Uniforms {
  var surfaceSizePixels: SIMD2<Float>
  var scale: Float
  // Trailing pad to round to 16 bytes — Metal expects naturally aligned
  // constant buffers and the simd2/float here would otherwise leave a hole.
  var _pad: Float = 0
}

private final class FrameCompletion: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var completed = false
  private let retainedObjects: [AnyObject]

  init(retainedObjects: [AnyObject] = []) {
    self.retainedObjects = retainedObjects
  }

  func signal() {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    semaphore.signal()
  }

  func wait() {
    lock.lock()
    if completed {
      lock.unlock()
      return
    }
    lock.unlock()
    semaphore.wait()
  }
}

/// GPU renderer backed by `CAMetalLayer`. One device, one queue, one library.
/// Two pipelines (solid quad + textured glyph quad). Two draw calls per
/// "scissor span" — clip changes flush, everything else batches.
public final class MetalRenderer: RendererBackend, DisplayLinkPresentingRenderer,
  RenderFailureReporting
{
  private static let maxGlyphAtlasTextureSize = 16_384

  /// A/B override for the classic damage-scoped instance rebuild. Kept
  /// process-wide so tests and microbenches can compare both paths in one
  /// binary. M1 makes the scoped rebuild the shipping classic default.
  public nonisolated(unsafe) static var useClassicDamageScoped = true

  /// A/B override reserved for the macOS-26 GPU-cell path. Until that path is
  /// implemented, enabling it resolves to the classic renderer.
  public nonisolated(unsafe) static var useGPUCellPath = false

  // MARK: - Public surface

  public let device: MTLDevice
  public let layer: CAMetalLayer
  public private(set) var fontAtlas: FontAtlas
  /// Optional smaller font for sidebar chrome. When the caller provides
  /// nil at init time, sidebar text uses the same atlas as the terminal.
  public private(set) var sidebarFontAtlas: FontAtlas
  public var configuredRendererMode: RendererMode
  public var requestedRendererMode: RendererMode {
    Self.useGPUCellPath ? .gpuDriven : configuredRendererMode
  }

  public var surfaceWidth: Int { Int(layer.drawableSize.width.rounded()) }
  public var surfaceHeight: Int { Int(layer.drawableSize.height.rounded()) }
  public var surfaceScale: CGFloat { layer.contentsScale }

  public var presentationLayer: CALayer? { layer }
  public var presentationImage: CGImage? { nil }

  /// Last-frame readback for screenshots / capture. Returns nil when
  /// `captureMode` is off (the drawable→CPU blit is skipped to keep
  /// cursor-blink frames cheap).
  public var pngData: Data? {
    lastFrameCompletion?.wait()
    return readback.pngData(waitingFor: lastCmdBuf)
  }

  public struct RenderInstanceCounts: Equatable, Sendable {
    public var solids: Int
    public var glyphs: Int
    public var sidebarGlyphs: Int
    public var cellGlyphs: Int
    public var cursors: Int

    public init(
      solids: Int = 0,
      glyphs: Int = 0,
      sidebarGlyphs: Int = 0,
      cellGlyphs: Int = 0,
      cursors: Int = 0
    ) {
      self.solids = solids
      self.glyphs = glyphs
      self.sidebarGlyphs = sidebarGlyphs
      self.cellGlyphs = cellGlyphs
      self.cursors = cursors
    }
  }

  public struct GPUCellPayloadBuildFailure: Codable, Equatable, Sendable {
    public var reason: String
    public var row: Int
    public var col: Int
    public var scalarValue: UInt32?
    public var textPreview: String?
    public var utf8RangeLowerBound: Int?
    public var utf8RangeUpperBound: Int?
    public var utf8ByteCount: Int
    public var wide: UInt8
    public var attributesRawValue: UInt16
    public var logicalWidth: Double?
    public var maxLogicalWidth: Double?

    public init(
      reason: String,
      row: Int,
      col: Int,
      scalarValue: UInt32?,
      textPreview: String?,
      utf8RangeLowerBound: Int?,
      utf8RangeUpperBound: Int?,
      utf8ByteCount: Int,
      wide: UInt8,
      attributesRawValue: UInt16,
      logicalWidth: Double? = nil,
      maxLogicalWidth: Double? = nil
    ) {
      self.reason = reason
      self.row = row
      self.col = col
      self.scalarValue = scalarValue
      self.textPreview = textPreview
      self.utf8RangeLowerBound = utf8RangeLowerBound
      self.utf8RangeUpperBound = utf8RangeUpperBound
      self.utf8ByteCount = utf8ByteCount
      self.wide = wide
      self.attributesRawValue = attributesRawValue
      self.logicalWidth = logicalWidth
      self.maxLogicalWidth = maxLogicalWidth
    }
  }

  /// Why the most recent `render(_:cellPayload:damage:rendererFallbackReason:)`
  /// returned `false`. `render` collapses several distinct conditions into one
  /// `Bool`; this disambiguates them for the render journal and blank-frame
  /// triage. Cleared to `nil` at the start of every `render` and left `nil` on a
  /// successful frame.
  public private(set) var lastRenderFailureReason: RenderFailureReason?

  /// A GPU command buffer that completed with `.error`. The completion handler
  /// runs off the main thread, so this is published under `frameSampleLock` and
  /// kept as the last-seen failure for diagnostics (not cleared on success).
  public struct CommandBufferFailure: Codable, Equatable, Sendable {
    /// `MTLCommandBufferStatus.rawValue` at completion (`.error` == 5).
    public var status: Int
    /// `MTLCommandBuffer.error?.localizedDescription`, if any.
    public var error: String?

    public init(status: Int, error: String?) {
      self.status = status
      self.error = error
    }
  }

  private static let log = Logger(subsystem: "com.rrva.laban", category: "metal-renderer")
  private static let maxNarrowGlyphLogicalWidthCells: CGFloat = 2.5

  public private(set) var lastInstanceCounts = RenderInstanceCounts()
  public private(set) var lastGPUCellPayloadBuildFailure: GPUCellPayloadBuildFailure?
  public private(set) var lastDrawableAcquireDiagnostic: MetalDrawableAcquireDiagnostic?
  /// Set off the main thread when a command buffer completes with `.error`;
  /// the next `render` consumes it to force a full repaint, recovering from a
  /// half-presented or dropped GPU frame. Guarded by `frameSampleLock`.
  private var pendingCommandBufferRecovery = false
  public private(set) var lastCommandBufferError: CommandBufferFailure?
  public private(set) var rendererStatus = RendererStatus(
    configuredRenderer: RendererMode.classic.rawValue,
    effectiveRenderer: RendererMode.classic.rawValue,
    textCompositeModel: .encodedSRGBCompatibility)
  private var rendererStatusOverride: RendererStatus?

  /// Rolling per-frame stats. p50/p99 in milliseconds. CPU = wall time spent
  /// building instances and encoding commands before `commit()`. GPU =
  /// `cmdBuf.gpuEndTime - gpuStartTime` from the
  /// completion handler. Per-pass timings (content / presentBlit /
  /// cursorOverlay / readbackBlit) come from `MTLCounterSampleBuffer`
  /// timestamp samples — they are 0 when the device doesn't support
  /// timestamp counters or when the corresponding pass didn't execute
  /// this frame (e.g., readback skipped because captureMode is off).
  public struct FrameTimings: Equatable, Sendable {
    public var sampleCount: Int
    public var cpuMeanMs: Double
    public var cpuP50Ms: Double
    public var cpuP95Ms: Double
    public var cpuP99Ms: Double
    public var gpuMeanMs: Double
    public var gpuP50Ms: Double
    public var gpuP95Ms: Double
    public var gpuP99Ms: Double
    public var contentMeanMs: Double
    public var presentBlitMeanMs: Double
    public var cursorOverlayMeanMs: Double
    public var readbackBlitMeanMs: Double
    /// True when the underlying device exposes timestamp counters, so the
    /// per-pass means are real numbers. False ⇒ they are all 0.
    public var perPassAvailable: Bool
  }

  public func recentFrameTimings() -> FrameTimings {
    frameSampleLock.lock()
    defer { frameSampleLock.unlock() }
    let cpu = frameSamples.map { $0.cpuMs }
    let gpu = frameSamples.map { $0.gpuMs }
    let content = frameSamples.compactMap { $0.contentMs > 0 ? $0.contentMs : nil }
    let present = frameSamples.compactMap { $0.presentBlitMs > 0 ? $0.presentBlitMs : nil }
    let cursor = frameSamples.compactMap { $0.cursorOverlayMs > 0 ? $0.cursorOverlayMs : nil }
    let readback = frameSamples.compactMap { $0.readbackBlitMs > 0 ? $0.readbackBlitMs : nil }
    return FrameTimings(
      sampleCount: frameSamples.count,
      cpuMeanMs: mean(cpu),
      cpuP50Ms: percentile(cpu, 0.50),
      cpuP95Ms: percentile(cpu, 0.95),
      cpuP99Ms: percentile(cpu, 0.99),
      gpuMeanMs: mean(gpu),
      gpuP50Ms: percentile(gpu, 0.50),
      gpuP95Ms: percentile(gpu, 0.95),
      gpuP99Ms: percentile(gpu, 0.99),
      contentMeanMs: mean(content),
      presentBlitMeanMs: mean(present),
      cursorOverlayMeanMs: mean(cursor),
      readbackBlitMeanMs: mean(readback),
      perPassAvailable: counterSampleBuffer != nil)
  }

  public func resetFrameTimings() {
    frameSampleLock.lock()
    frameSamples.removeAll(keepingCapacity: true)
    frameSampleLock.unlock()
  }

  /// Resolve the most recent frame's sample-buffer slots into per-pass
  /// milliseconds. Slots not used by this frame (e.g., readback when
  /// captureMode is off) are returned as 0.
  private struct PerPass { var content, present, cursor, readback: Double }
  private func resolvePerPassTimingsForFrame() -> PerPass {
    guard let cb = counterSampleBuffer else {
      return PerPass(content: 0, present: 0, cursor: 0, readback: 0)
    }
    let slots = lastFramePassSlots
    let data: Data
    do {
      data = try cb.resolveCounterRange(0..<8) ?? Data()
    } catch {
      return PerPass(content: 0, present: 0, cursor: 0, readback: 0)
    }
    guard data.count >= MemoryLayout<UInt64>.stride * 8 else {
      return PerPass(content: 0, present: 0, cursor: 0, readback: 0)
    }
    let ts: [UInt64] = data.withUnsafeBytes { raw in
      let p = raw.bindMemory(to: UInt64.self)
      return Array(p)
    }
    @inline(__always)
    func ms(_ start: UInt64, _ end: UInt64) -> Double {
      // Counters can momentarily be 0 (slot wasn't written) — treat as no
      // sample. Subtraction is unsigned-safe via &-.
      guard start != 0, end != 0, end > start else { return 0 }
      return Double(end &- start) * gpuNsPerTick / 1_000_000.0
    }
    return PerPass(
      content: slots.contentActive ? ms(ts[0], ts[1]) : 0,
      present: slots.presentActive ? ms(ts[2], ts[3]) : 0,
      cursor: slots.cursorActive ? ms(ts[4], ts[5]) : 0,
      readback: slots.readbackActive ? ms(ts[6], ts[7]) : 0)
  }

  /// Optional callback fired on the GPU completion handler each frame. The
  /// view installs one to drive end-to-end input-to-photon latency
  /// measurement (timestamp paired with a recent keystroke).
  public var onFrameCompleted: (() -> Void)?

  // MARK: - Internals

  private let queue: MTLCommandQueue
  private let solidPipeline: MTLRenderPipelineState
  private let replaceSolidPipeline: MTLRenderPipelineState
  private let glyphPipeline: MTLRenderPipelineState
  private let colorGlyphPipeline: MTLRenderPipelineState
  private let cellGlyphPipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private var glyphAtlas: MetalGlyphAtlas
  private var colorGlyphAtlas: ColorGlyphAtlas
  /// Distinct atlas for sidebar text — same when sidebarFontAtlas ===
  /// fontAtlas, otherwise a separately-rasterized R8 texture sized to
  /// the smaller font's cell metrics.
  private var sidebarGlyphAtlas: MetalGlyphAtlas

  private var solidInstances: [SolidInstance] = []
  private var replaceSolidInstances: [SolidInstance] = []
  private var glyphInstances: [GlyphInstance] = []
  private var colorGlyphInstances: [GlyphInstance] = []
  private var cellGlyphs: [CellGlyph] = []
  private var cellGlyphUploadRanges: [Range<Int>] = []
  private var cellGlyphGridGeometry: TerminalGridGeometry?
  private var payloadRowsWithFullBackgroundRun: [Bool] = []
  // Per-build direct-mapped cache in front of the glyph atlas's dictionary.
  // A full-frame rebuild looks up every cell, but a terminal row draws from a
  // tiny alphabet (spaces and a few dozen glyphs dominate), so the same
  // (scalar, attributes) pair recurs hundreds of times per frame. A stamp
  // equal to `scalarEntryCacheGeneration` marks a slot live for the current
  // build; bumping the generation each build invalidates the whole table in
  // O(1) without clearing, and a cached Entry is only reused within one build
  // (the atlas only appends within a build, never moves existing glyphs).
  private static let scalarEntryCacheSize = 1024
  private static let defaultASCIIEntryCacheSize = 128
  private var scalarEntryCacheKeys = [UInt64](
    repeating: 0, count: MetalRenderer.scalarEntryCacheSize)
  private var scalarEntryCacheEntries = [MetalGlyphAtlas.Entry?](
    repeating: nil, count: MetalRenderer.scalarEntryCacheSize)
  private var scalarEntryCacheStamp = [UInt32](
    repeating: 0, count: MetalRenderer.scalarEntryCacheSize)
  private var defaultASCIIEntryCacheEntries = [MetalGlyphAtlas.Entry?](
    repeating: nil, count: MetalRenderer.defaultASCIIEntryCacheSize)
  private var defaultASCIIEntryCacheStamp = [UInt32](
    repeating: 0, count: MetalRenderer.defaultASCIIEntryCacheSize)
  private var scalarEntryCacheGeneration: UInt32 = 0
  /// Glyphs that draw against the sidebar atlas. Kept separate so we can
  /// issue one draw call per atlas — the sidebar's R8 texture holds glyphs
  /// rasterized at a smaller pt size and isn't substitutable for the main.
  private var sidebarGlyphInstances: [GlyphInstance] = []
  // Cursor instances drawn in a separate overlay pass — they live ON TOP of
  // the persistent target, never IN it, so cursor blinks don't dirty the
  // terminal cells underneath.
  private var cursorInstances: [SolidInstance] = []
  /// Sidebar-strip pass instances, separate from the content-pass lists.
  /// The content pass damage-scopes its sidebar instances to the dirty band
  /// (or skips building them entirely on an empty-damage frame); the strip
  /// pass must always cover the whole strip, so it rebuilds from the
  /// sidebar-source commands into its own lists and buffers.
  private var stripSolidInstances: [SolidInstance] = []
  private var stripReplaceSolidInstances: [SolidInstance] = []
  private var stripGlyphInstances: [GlyphInstance] = []
  // setVertexBytes has a hard 4 KB limit, which one 80×24 frame can blow
  // past easily (one solid instance is 32 B, one glyph instance is 48 B).
  // We size MTLBuffers on demand and reuse them frame-to-frame.
  private var solidBuffer: MTLBuffer?
  private var replaceSolidBuffer: MTLBuffer?
  private var damageEraseBuffer: MTLBuffer?
  private var glyphBuffer: MTLBuffer?
  private var colorGlyphBuffer: MTLBuffer?
  private var cellGlyphBuffer: MTLBuffer?
  private var sidebarGlyphBuffer: MTLBuffer?
  private var cursorBuffer: MTLBuffer?
  private var stripSolidBuffer: MTLBuffer?
  private var stripReplaceSolidBuffer: MTLBuffer?
  private var stripGlyphBuffer: MTLBuffer?

  /// Persistent terminal-content render target. Holds the most recent fully
  /// rendered terminal cells (no cursor). Damage-driven updates write into
  /// this texture; clean rows survive untouched. Reallocated on resize, on
  /// first frame, and whenever a damage hint can't be honoured (e.g.,
  /// caller passed `.partial(empty)` but the surface size changed).
  private var targetTexture: MTLTexture?
  /// macOS 14+ fast path: an internal CAMetalDisplayLink presents completed
  /// snapshots on its own thread. The persistent `targetTexture` remains the
  /// damage-scoped content surface; these textures are full-frame presentation
  /// snapshots that also receive cursor overlay and optional readback.
  private var presentDisplayLinkStorage: AnyObject?
  @available(macOS 14.0, *)
  private var presentDisplayLink: VectorPresentDisplayLink? {
    presentDisplayLinkStorage as? VectorPresentDisplayLink
  }
  private var latestPresentedTarget: MTLTexture?
  private let presentTargetLock = NSLock()
  private var presentQueue: MTLCommandQueue?
  private var presentationTargetRing: [MTLTexture] = []
  private var presentationTargetRingCursor = 0
  private static let presentationTargetRingDepth = 3
  public private(set) var surfaceTransparency: RendererSurfaceTransparency
  private var targetNeedsFullRedraw: Bool = true
  private var lastRenderedThemeRevision: UInt64 = Theme.revision
  /// Set by the command-fed GPU-cell build when a partial update arrives after
  /// the terminal grid geometry changed (so the retained cell cache had to be
  /// fully rebuilt). The caller turns this into a full-target redraw rather than
  /// a partial scissor update — which would leave stale pre-change pixels in the
  /// clean rows — mirroring the cell-payload path's fail-closed geometry guard.
  private var gpuCellCommandRequiresFullRedraw = false
  /// Last frame's command buffer. `pngData` waits on it before reading the
  /// readback texture so capture-side callers see the actual just-rendered
  /// pixels and not whatever the previous frame happened to leave behind.
  private var lastCmdBuf: MTLCommandBuffer?
  private let drawableScheduler: MetalDrawableScheduler
  private let readback: MetalReadback

  /// Set true while a capture session needs the per-frame readback blit;
  /// false otherwise so cursor-blink frames don't pay the drawable→CPU copy
  /// (~50–100 µs of pure overhead with no consumer).
  public var captureMode: Bool {
    get { readback.captureMode }
    set { readback.captureMode = newValue }
  }

  /// Blocks `render()` until the committed command buffer has completed.
  /// Normal display-link frames leave this off; AppKit resize frames turn it
  /// on briefly so layer geometry and the just-sized drawable do not race in
  /// WindowServer presentation.
  public var waitForFrameCompletion: Bool = false

  public func waitForLastFrame() {
    lastFrameCompletion?.wait()
    lastCmdBuf?.waitUntilCompleted()
  }

  /// Rolling per-frame timing samples. CPU = wall time spent in render()
  /// itself (encoding work). GPU = cmdBuf.gpuEndTime - gpuStartTime, set in
  /// the completion handler. Per-pass GPU times come from
  /// MTLCounterSampleBuffer (when the device supports timestamp counters).
  /// Bounded ring; recentFrameTimings() reads p50/p99.
  private struct FrameSample {
    var cpuMs: Double
    var gpuMs: Double
    var contentMs: Double
    var presentBlitMs: Double
    var cursorOverlayMs: Double
    var readbackBlitMs: Double
  }
  private var frameSamples: [FrameSample] = []
  private static let frameSampleCap = 240
  private let frameSampleLock = NSLock()
  private var lastFrameCompletion: FrameCompletion?

  // MARK: - GPU timestamp counters
  //
  // Per-pass timing is sampled via MTLCounterSampleBuffer at the start and
  // end of each pass. Tick → wall-time conversion uses a CPU/GPU anchor
  // captured at init (and refreshed periodically since the GPU clock can
  // drift on long-running processes).
  //
  // Sample-buffer slot map (8 slots total; unused slots leave previous
  // values which we ignore via the wasActive flags carried in PassSlots):
  //   0/1  content pass  start/end of vertex/end of fragment
  //   2/3  present blit  start/end of encoder
  //   4/5  cursor overlay
  //   6/7  readback blit
  private struct PassSlots {
    var contentActive = false
    var presentActive = false
    var cursorActive = false
    var readbackActive = false
  }
  private var counterSampleBuffer: MTLCounterSampleBuffer?
  private var counterRenderSupported = false
  private var counterBlitSupported = false
  /// Nanoseconds per GPU timestamp tick, computed from a CPU/GPU anchor
  /// pair. ~1 on Apple silicon but read instead of assumed.
  private var gpuNsPerTick: Double = 1.0
  private var glyphCellAdvance: CGFloat
  private var glyphCellHeight: CGFloat
  private var sidebarCellAdvance: CGFloat
  private var sidebarCellHeight: CGFloat

  var glyphCellAdvanceForTesting: CGFloat { glyphCellAdvance }
  var glyphCellHeightForTesting: CGFloat { glyphCellHeight }

  var terminalGlyphAtlasTextureSizeForTesting: Int { glyphAtlas.textureSize }
  func noteCommandBufferCompletionForTesting(status: MTLCommandBufferStatus, error: Error?) {
    noteCommandBufferCompletion(status: status, error: error)
  }
  var hasPendingCommandBufferRecoveryForTesting: Bool {
    frameSampleLock.lock()
    defer { frameSampleLock.unlock() }
    return pendingCommandBufferRecovery
  }
  var cellGlyphUploadRangesForTesting: [Range<Int>] { cellGlyphUploadRanges }
  var payloadRowMarkerCapacityForTesting: Int { payloadRowsWithFullBackgroundRun.capacity }
  var activeCellGlyphIndicesForTesting: [Int] {
    cellGlyphs.indices.filter { cellGlyphs[$0].flags != 0 }
  }

  func rebuildInstancesForTesting(
    commands: [FrameCommand],
    damage: RenderDamage,
    surfacePxH: Int
  ) -> RenderInstanceCounts {
    buildInstanceLists(commands: commands, surfacePxH: surfacePxH, damage: damage)
    return lastInstanceCounts
  }

  func rebuildGPUCellInstancesForTesting(
    commands: [FrameCommand],
    damage: RenderDamage,
    surfacePxH: Int
  ) -> RenderInstanceCounts? {
    guard buildGPUCellInstanceLists(commands: commands, surfacePxH: surfacePxH, damage: damage)
    else {
      return nil
    }
    return lastInstanceCounts
  }

  func rebuildGPUCellPayloadInstancesForTesting(
    payload: TerminalCellPayload,
    commands: [FrameCommand],
    damage: RenderDamage,
    surfacePxH: Int
  ) -> RenderInstanceCounts? {
    guard
      buildGPUCellInstanceLists(
        payload: payload,
        commands: commands,
        surfacePxH: surfacePxH,
        damage: damage)
    else {
      return nil
    }
    return lastInstanceCounts
  }

  func rebuildAndPrepareGPUCellPayloadInstancesForTesting(
    payload: TerminalCellPayload,
    commands: [FrameCommand],
    damage: RenderDamage,
    surfacePxH: Int
  ) -> RenderInstanceCounts? {
    guard
      buildGPUCellInstanceLists(
        payload: payload,
        commands: commands,
        surfacePxH: surfacePxH,
        damage: damage)
    else {
      return nil
    }
    _ = prepareCellGlyphBuffer()
    return lastInstanceCounts
  }

  func classicTerminalGlyphRecordsForTesting(
    commands: [FrameCommand],
    surfacePxH: Int
  ) -> [GPUCellGlyphRecord] {
    buildInstanceLists(commands: commands, surfacePxH: surfacePxH, damage: .full)
    return glyphInstances.map(Self.record(from:)).sortedForOriginParity()
  }

  func gpuCellGlyphRecordsForTesting(
    commands: [FrameCommand],
    surfacePxH: Int
  ) -> [GPUCellGlyphRecord]? {
    guard buildGPUCellInstanceLists(commands: commands, surfacePxH: surfacePxH, damage: .full)
    else {
      return nil
    }
    return cellGlyphs.compactMap { glyph in
      guard glyph.flags != 0 else { return nil }
      return Self.record(from: glyph)
    }.sortedForOriginParity()
  }

  func gpuCellPathSupportedForTesting(
    commands: [FrameCommand],
    surfacePxH: Int
  ) -> Bool {
    buildGPUCellInstanceLists(commands: commands, surfacePxH: surfacePxH, damage: .full)
  }

  /// Drop the GPU-cell persistent cache and mark the render target stale. Called
  /// when the palette changes so partial damage cannot leave chrome coloured
  /// from the previous theme.
  public func invalidateContentForThemeChange() {
    emojiRenderingMode = EmojiRenderingSettings.current()
    targetNeedsFullRedraw = true
    cellGlyphGridGeometry = nil
    cellGlyphs.removeAll(keepingCapacity: true)
    cellGlyphUploadRanges.removeAll(keepingCapacity: true)
  }

  /// Rebuild glyph atlases after the explicit CJK cascade preference changes.
  /// Cached atlas entries are keyed by the primary font, not the resolved CJK
  /// fallback, so stale Hanzi tiles must be dropped when the preference moves.
  public func refreshCJKFontCascade() {
    let cell = fontAtlas.cellSize
    let sidebarCell = sidebarFontAtlas.cellSize
    if let fresh = MetalGlyphAtlas(
      device: device,
      cellWidth: cell.width,
      cellHeight: cell.height,
      descent: fontAtlas.descent,
      scale: layer.contentsScale,
      textureSize: glyphAtlas.textureSize)
    {
      glyphAtlas = fresh
    }
    if let fresh = ColorGlyphAtlas(
      device: device,
      cellWidth: cell.width,
      cellHeight: cell.height,
      descent: fontAtlas.descent,
      scale: layer.contentsScale,
      textureSize: colorGlyphAtlas.textureSize)
    {
      colorGlyphAtlas = fresh
    }
    if sidebarFontAtlas === fontAtlas {
      sidebarGlyphAtlas = glyphAtlas
    } else if let fresh = MetalGlyphAtlas(
      device: device,
      cellWidth: sidebarCell.width,
      cellHeight: sidebarCell.height,
      descent: sidebarFontAtlas.descent,
      scale: layer.contentsScale,
      textureSize: sidebarGlyphAtlas.textureSize)
    {
      sidebarGlyphAtlas = fresh
    }
    fontCache.removeAll(keepingCapacity: true)
    scalarEntryCacheGeneration &+= 1
    colorGlyphInstances.removeAll(keepingCapacity: true)
    cellGlyphBuffer = nil
    colorGlyphBuffer = nil
    invalidateContentForThemeChange()
  }

  var targetNeedsFullRedrawForTesting: Bool { targetNeedsFullRedraw }
  var lastRenderedThemeRevisionForTesting: UInt64 { lastRenderedThemeRevision }

  public var effectiveRendererMode: RendererMode {
    let requested = requestedRendererMode
    guard requested == .gpuDriven else { return .classic }
    if #available(macOS 26, *) {
      return .gpuDriven
    }
    return .classic
  }

  /// Initializes the renderer. Returns nil when Metal is unavailable (no
  /// device, missing default library, or pipeline compile failure).
  public init?(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil,
    scale: CGFloat = 1,
    glyphAtlasTextureSize: Int = 2048,
    rendererMode: RendererMode = .classic,
    surfaceTransparency: RendererSurfaceTransparency = RendererSurfaceTransparency(
      isOpaque: true)
  ) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    guard let queue = device.makeCommandQueue() else { return nil }
    let initialAtlasTextureSize = min(
      max(1, glyphAtlasTextureSize),
      Self.maxGlyphAtlasTextureSize)
    // Package.swift ships the shaders as .copy resources, so the bundle holds
    // the .metal source rather than a pre-compiled .metallib. We compile from
    // source on startup (~1 ms one-time cost) so the renderer ships with no
    // extra build step.
    guard
      let url = LabanRendererResources.bundle?.url(
        forResource: "Shaders", withExtension: "metal"),
      let source = try? String(contentsOf: url, encoding: .utf8),
      let library = try? device.makeLibrary(source: source, options: nil)
    else { return nil }
    guard
      let solidVS = library.makeFunction(name: "solid_vertex"),
      let solidFS = library.makeFunction(name: "solid_fragment"),
      let glyphVS = library.makeFunction(name: "glyph_vertex"),
      let cellGlyphVS = library.makeFunction(name: "cell_glyph_vertex"),
      let glyphFS = library.makeFunction(name: "glyph_fragment"),
      let colorGlyphFS = library.makeFunction(name: "color_glyph_fragment")
    else { return nil }

    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false  // need readable color for capture readback
    layer.contentsScale = scale
    layer.isOpaque = surfaceTransparency.isOpaque
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
    // Keep native-size Metal drawables pinned to the window's top-left
    // during AppKit resize. WindowServer can briefly composite a newly
    // sized drawable into the previous window image; bottom-left gravity
    // made row 0 and the sidebar tab jump downward on height-only shrink,
    // while `.resize` stretched text and shifted content on stale frames.
    layer.contentsGravity = .topLeft

    let solidDesc = MTLRenderPipelineDescriptor()
    solidDesc.label = "laban.solid-quad"
    solidDesc.vertexFunction = solidVS
    solidDesc.fragmentFunction = solidFS
    // Metal render pipeline descriptors always provide color attachment slot 0.
    let solidAttachment = solidDesc.colorAttachments[0]!
    solidAttachment.pixelFormat = layer.pixelFormat
    solidAttachment.isBlendingEnabled = true
    solidAttachment.rgbBlendOperation = .add
    solidAttachment.alphaBlendOperation = .add
    solidAttachment.sourceRGBBlendFactor = .one  // shader pre-multiplies
    solidAttachment.sourceAlphaBlendFactor = .one
    solidAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    solidAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    let replaceSolidDesc = MTLRenderPipelineDescriptor()
    replaceSolidDesc.label = "laban.solid-quad-replace"
    replaceSolidDesc.vertexFunction = solidVS
    replaceSolidDesc.fragmentFunction = solidFS
    let replaceSolidAttachment = replaceSolidDesc.colorAttachments[0]!
    replaceSolidAttachment.pixelFormat = layer.pixelFormat
    replaceSolidAttachment.isBlendingEnabled = false

    let glyphDesc = MTLRenderPipelineDescriptor()
    glyphDesc.label = "laban.glyph-quad"
    glyphDesc.vertexFunction = glyphVS
    glyphDesc.fragmentFunction = glyphFS
    // Metal render pipeline descriptors always provide color attachment slot 0.
    let glyphAttachment = glyphDesc.colorAttachments[0]!
    glyphAttachment.pixelFormat = layer.pixelFormat
    glyphAttachment.isBlendingEnabled = true
    glyphAttachment.rgbBlendOperation = .add
    glyphAttachment.alphaBlendOperation = .add
    glyphAttachment.sourceRGBBlendFactor = .one
    glyphAttachment.sourceAlphaBlendFactor = .one
    glyphAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    glyphAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    let cellGlyphDesc = MTLRenderPipelineDescriptor()
    cellGlyphDesc.label = "laban.cell-glyph-quad"
    cellGlyphDesc.vertexFunction = cellGlyphVS
    cellGlyphDesc.fragmentFunction = glyphFS
    // Metal render pipeline descriptors always provide color attachment slot 0.
    let cellGlyphAttachment = cellGlyphDesc.colorAttachments[0]!
    cellGlyphAttachment.pixelFormat = layer.pixelFormat
    cellGlyphAttachment.isBlendingEnabled = true
    cellGlyphAttachment.rgbBlendOperation = .add
    cellGlyphAttachment.alphaBlendOperation = .add
    cellGlyphAttachment.sourceRGBBlendFactor = .one
    cellGlyphAttachment.sourceAlphaBlendFactor = .one
    cellGlyphAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    cellGlyphAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    let colorGlyphDesc = MTLRenderPipelineDescriptor()
    colorGlyphDesc.label = "laban.color-glyph-quad"
    colorGlyphDesc.vertexFunction = glyphVS
    colorGlyphDesc.fragmentFunction = colorGlyphFS
    let colorGlyphAttachment = colorGlyphDesc.colorAttachments[0]!
    colorGlyphAttachment.pixelFormat = layer.pixelFormat
    colorGlyphAttachment.isBlendingEnabled = true
    colorGlyphAttachment.rgbBlendOperation = .add
    colorGlyphAttachment.alphaBlendOperation = .add
    colorGlyphAttachment.sourceRGBBlendFactor = .one
    colorGlyphAttachment.sourceAlphaBlendFactor = .one
    colorGlyphAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    colorGlyphAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    guard
      let solidPipeline = try? device.makeRenderPipelineState(descriptor: solidDesc),
      let replaceSolidPipeline = try? device.makeRenderPipelineState(
        descriptor: replaceSolidDesc),
      let glyphPipeline = try? device.makeRenderPipelineState(descriptor: glyphDesc),
      let colorGlyphPipeline = try? device.makeRenderPipelineState(descriptor: colorGlyphDesc),
      let cellGlyphPipeline = try? device.makeRenderPipelineState(descriptor: cellGlyphDesc)
    else { return nil }

    let samplerDesc = MTLSamplerDescriptor()
    samplerDesc.minFilter = .nearest
    samplerDesc.magFilter = .nearest
    samplerDesc.sAddressMode = .clampToEdge
    samplerDesc.tAddressMode = .clampToEdge
    guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
      return nil
    }

    let cell = fontAtlas.cellSize
    guard
      let atlas = MetalGlyphAtlas(
        device: device,
        cellWidth: cell.width,
        cellHeight: cell.height,
        descent: fontAtlas.descent,
        scale: scale,
        textureSize: initialAtlasTextureSize)
    else { return nil }
    guard
      let colorAtlas = ColorGlyphAtlas(
        device: device,
        cellWidth: cell.width,
        cellHeight: cell.height,
        descent: fontAtlas.descent,
        scale: scale,
        textureSize: initialAtlasTextureSize)
    else { return nil }

    let sidebarAtlas = sidebarFontAtlas ?? fontAtlas
    let sidebarCell = sidebarAtlas.cellSize
    let sidebarGlyphAtlasInstance: MetalGlyphAtlas
    if sidebarAtlas === fontAtlas {
      sidebarGlyphAtlasInstance = atlas
    } else {
      guard
        let alt = MetalGlyphAtlas(
          device: device,
          cellWidth: sidebarCell.width,
          cellHeight: sidebarCell.height,
          descent: sidebarAtlas.descent,
          scale: scale,
          textureSize: initialAtlasTextureSize)
      else { return nil }
      sidebarGlyphAtlasInstance = alt
    }

    self.device = device
    self.queue = queue
    self.layer = layer
    self.drawableScheduler = MetalDrawableScheduler(layer: layer)
    self.readback = MetalReadback(device: device, pixelFormat: layer.pixelFormat)
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarAtlas
    self.configuredRendererMode = rendererMode.isAvailableOnCurrentOS ? rendererMode : .classic
    self.surfaceTransparency = surfaceTransparency
    self.solidPipeline = solidPipeline
    self.replaceSolidPipeline = replaceSolidPipeline
    self.glyphPipeline = glyphPipeline
    self.colorGlyphPipeline = colorGlyphPipeline
    self.cellGlyphPipeline = cellGlyphPipeline
    self.sampler = sampler
    self.glyphAtlas = atlas
    self.colorGlyphAtlas = colorAtlas
    self.sidebarGlyphAtlas = sidebarGlyphAtlasInstance
    self.glyphCellAdvance = cell.width
    self.glyphCellHeight = cell.height
    self.sidebarCellAdvance = sidebarCell.width
    self.sidebarCellHeight = sidebarCell.height

    setupCounterSampling()
    rendererStatus = resolvedRendererStatus(rendererFallbackReason: nil).status

    if #available(macOS 14.0, *), Self.presentDisplayLinkEnabled,
      let presentQueue = device.makeCommandQueue()
    {
      presentQueue.label = "laban.metal.present"
      self.presentQueue = presentQueue
      let presentLink = VectorPresentDisplayLink(layer: layer)
      presentLink.onPresent = { [weak self] drawable in
        self?.presentLatestTarget(into: drawable) ?? false
      }
      presentLink.start()
      self.presentDisplayLinkStorage = presentLink
    }
  }

  /// Default true. `LabanMetalPresentDisplayLink` opts classic/gpuDriven out
  /// without changing vector/slug; if unset, `LabanVectorPresentDisplayLink`
  /// acts as the shared curve/metal presenter kill switch.
  private static var presentDisplayLinkEnabled: Bool {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "LabanMetalPresentDisplayLink") != nil {
      return defaults.bool(forKey: "LabanMetalPresentDisplayLink")
    }
    if defaults.object(forKey: "LabanVectorPresentDisplayLink") != nil {
      return defaults.bool(forKey: "LabanVectorPresentDisplayLink")
    }
    return true
  }

  deinit {
    if #available(macOS 14.0, *) {
      presentDisplayLink?.stop()
    }
  }

  public func setPresentLinkRunning(_ running: Bool) {
    if #available(macOS 14.0, *) {
      presentDisplayLink?.setRunning(running)
    }
  }

  /// Rebuild the present link after a display reconfiguration; see
  /// `VectorPresentDisplayLink.rebuild()`. No-op on the legacy path.
  public func rebuildPresentLink() {
    if #available(macOS 14.0, *) {
      presentDisplayLink?.rebuild()
    }
  }

  public func setSurfaceTransparency(_ transparency: RendererSurfaceTransparency) {
    guard transparency != surfaceTransparency else { return }
    // Do not allow a completion handler from the old policy to republish a
    // retained presentation target after the transition invalidates it.
    lastCmdBuf?.waitUntilCompleted()
    surfaceTransparency = transparency
    layer.isOpaque = transparency.isOpaque
    readback.invalidate()
    targetTexture = nil
    clearPresentationTargets()
    targetNeedsFullRedraw = true
  }

  public func presentDisplayLinkStats(reset: Bool) -> [String: Double]? {
    if #available(macOS 14.0, *) {
      return presentDisplayLink?.presentIntervalStats(reset: reset)
    }
    return nil
  }

  public func overrideRendererStatus(_ status: RendererStatus) {
    rendererStatusOverride = status
    rendererStatus = status
  }

  public func clearRendererStatusOverride() {
    rendererStatusOverride = nil
    rendererStatus = resolvedRendererStatus(rendererFallbackReason: nil).status
  }

  /// Discover the device's timestamp counter set and allocate a sample
  /// buffer big enough for the four passes per frame. Capability gates are
  /// checked separately for render and blit so we don't try to attach a
  /// sample buffer to a pass kind the device can't sample.
  private func setupCounterSampling() {
    let timestampName = MTLCommonCounterSet.timestamp.rawValue
    guard
      let counterSets = device.counterSets,
      let timestampSet = counterSets.first(where: { $0.name == timestampName })
    else { return }
    counterRenderSupported = device.supportsCounterSampling(.atStageBoundary)
    counterBlitSupported = device.supportsCounterSampling(.atBlitBoundary)
    guard counterRenderSupported || counterBlitSupported else { return }

    let desc = MTLCounterSampleBufferDescriptor()
    desc.counterSet = timestampSet
    desc.storageMode = .shared
    desc.sampleCount = 8
    desc.label = "laban.frame-timing"
    counterSampleBuffer = try? device.makeCounterSampleBuffer(descriptor: desc)

    gpuNsPerTick = calibrateGpuNanosecondsPerTick()
  }

  private func calibrateGpuNanosecondsPerTick() -> Double {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
      return 1.0
    }
    let first = device.sampleTimestamps()
    usleep(1_000)
    let second = device.sampleTimestamps()
    let cpuDelta = second.cpu &- first.cpu
    let gpuDelta = second.gpu &- first.gpu
    guard cpuDelta > 0, gpuDelta > 0 else { return 1.0 }
    let cpuNs =
      Double(cpuDelta) * Double(timebase.numer) / Double(timebase.denom)
    return cpuNs / Double(gpuDelta)
  }

  /// Update the layer's drawable size in pixels (call from view layout).
  @discardableResult
  public func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> Bool {
    let pw = max(1, pixelWidth)
    let ph = max(1, pixelHeight)
    let newScale = max(scale, 1)
    let scaleChanged = abs(newScale - layer.contentsScale) > 0.0001
    let sizeChanged =
      Int(layer.drawableSize.width.rounded()) != pw
      || Int(layer.drawableSize.height.rounded()) != ph
    if scaleChanged {
      layer.contentsScale = newScale
      // Atlas glyphs were rasterized for the old scale; rebuild on scale change.
      if let fresh = MetalGlyphAtlas(
        device: device,
        cellWidth: glyphCellAdvance,
        cellHeight: glyphCellHeight,
        descent: fontAtlas.descent,
        scale: newScale,
        textureSize: glyphAtlas.textureSize)
      {
        glyphAtlas = fresh
      }
      if let fresh = ColorGlyphAtlas(
        device: device,
        cellWidth: glyphCellAdvance,
        cellHeight: glyphCellHeight,
        descent: fontAtlas.descent,
        scale: newScale,
        textureSize: colorGlyphAtlas.textureSize)
      {
        colorGlyphAtlas = fresh
      }
      if sidebarFontAtlas === fontAtlas {
        sidebarGlyphAtlas = glyphAtlas
      } else if let fresh = MetalGlyphAtlas(
        device: device,
        cellWidth: sidebarCellAdvance,
        cellHeight: sidebarCellHeight,
        descent: sidebarFontAtlas.descent,
        scale: newScale,
        textureSize: sidebarGlyphAtlas.textureSize)
      {
        sidebarGlyphAtlas = fresh
      }
      cellGlyphGridGeometry = nil
      cellGlyphs.removeAll(keepingCapacity: true)
      cellGlyphUploadRanges.removeAll(keepingCapacity: true)
      cellGlyphBuffer = nil
    }
    if sizeChanged {
      layer.drawableSize = CGSize(width: pw, height: ph)
      readback.invalidate()
      targetTexture = nil
      clearPresentationTargets()
      targetNeedsFullRedraw = true
    }
    return scaleChanged || sizeChanged
  }

  /// Swap both font atlases (and their GPU glyph atlases) for a live font-size
  /// change. Modeled on the backing-scale branch of `resize`, with one
  /// difference: cell dimensions change too. Prebuilt `MetalGlyphAtlas`
  /// instances (from the atlas ladder) are adopted when supplied and created on
  /// this renderer's device; otherwise fresh empty atlases are constructed
  /// synchronously from the new metrics. Every glyph-derived cache is dropped
  /// and the next frame repaints the full target — no frame can mix the old
  /// atlas with the new grid.
  public func reconfigureFonts(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas,
    prebuiltTerminalAtlas: MetalGlyphAtlas? = nil,
    prebuiltSidebarAtlas: MetalGlyphAtlas? = nil
  ) {
    let cell = fontAtlas.cellSize
    let sidebarCell = sidebarFontAtlas.cellSize

    func usable(_ atlas: MetalGlyphAtlas?) -> MetalGlyphAtlas? {
      guard let atlas, atlas.texture.device === device else { return nil }
      return atlas
    }

    if let prebuilt = usable(prebuiltTerminalAtlas) {
      glyphAtlas = prebuilt
    } else if let fresh = MetalGlyphAtlas(
      device: device,
      cellWidth: cell.width,
      cellHeight: cell.height,
      descent: fontAtlas.descent,
      scale: layer.contentsScale,
      textureSize: glyphAtlas.textureSize)
    {
      glyphAtlas = fresh
    }
    if let fresh = ColorGlyphAtlas(
      device: device,
      cellWidth: cell.width,
      cellHeight: cell.height,
      descent: fontAtlas.descent,
      scale: layer.contentsScale,
      textureSize: colorGlyphAtlas.textureSize)
    {
      colorGlyphAtlas = fresh
    }

    if sidebarFontAtlas === fontAtlas {
      sidebarGlyphAtlas = glyphAtlas
    } else if let prebuilt = usable(prebuiltSidebarAtlas) {
      sidebarGlyphAtlas = prebuilt
    } else if let fresh = MetalGlyphAtlas(
      device: device,
      cellWidth: sidebarCell.width,
      cellHeight: sidebarCell.height,
      descent: sidebarFontAtlas.descent,
      scale: layer.contentsScale,
      textureSize: sidebarGlyphAtlas.textureSize)
    {
      sidebarGlyphAtlas = fresh
    }

    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas
    glyphCellAdvance = cell.width
    glyphCellHeight = cell.height
    sidebarCellAdvance = sidebarCell.width
    sidebarCellHeight = sidebarCell.height

    // Cached entries point into the replaced textures (and cached CTFonts
    // carry the old point size); invalidate everything glyph-derived and
    // force a full-target repaint.
    fontCache.removeAll(keepingCapacity: true)
    scalarEntryCacheGeneration &+= 1
    cellGlyphGridGeometry = nil
    cellGlyphs.removeAll(keepingCapacity: true)
    cellGlyphUploadRanges.removeAll(keepingCapacity: true)
    colorGlyphInstances.removeAll(keepingCapacity: true)
    cellGlyphBuffer = nil
    colorGlyphBuffer = nil
    targetNeedsFullRedraw = true
  }

  // MARK: - render

  /// One-shot pacing hint from the frame loop: the next frame belongs to a
  /// resampled smooth-scroll animation, so when the pipeline is at capacity
  /// it should be DROPPED immediately instead of blocking the main thread —
  /// the next display-link tick repaints from newer state anyway. Blocking
  /// here is what locks a 120 Hz panel at 60: the wait delays the next tick,
  /// so demand permanently exceeds the pipeline's ~117 frames/s capacity.
  /// Consumed (reset to false) by the next render call.
  public var dropNextFrameWhenBusy = false

  /// One-shot: repaint the sidebar strip this frame in a dedicated scissored
  /// pass, regardless of terminal damage. Set by the view while the attention
  /// pulse animates, so the breathing marker never has to force full-damage
  /// terminal repaints — forcing those at the output-driven 120 Hz link rate
  /// is what saturated the main thread ("typing is molasses whenever a tab
  /// needs me"). Consumed (reset to false) by the next render call.
  public var repaintSidebarStrip = false

  /// Minimum on-glass duration declared by paced scroll presents (1/120 s):
  /// the compositor reads the cadence from consistent paced presents, which
  /// is what holds a ProMotion panel at its full refresh rate.
  private static let scrollPresentMinimumDuration: CFTimeInterval = 1.0 / 120.0

  /// Catch-up wake: a prefetched drawable landed after a drop-when-busy
  /// frame missed. Rendering immediately (instead of waiting for the next
  /// display-link tick) presents a second frame into the current swap
  /// interval, which is the only escape from the half-rate drawable-recycle
  /// equilibrium. Called on a background queue — hop before touching UI.
  public var onDrawableReadyAfterMiss: (() -> Void)? {
    get { drawableScheduler.onDrawableReadyAfterMiss }
    set { drawableScheduler.onDrawableReadyAfterMiss = newValue }
  }

  @discardableResult
  public func render(_ commands: [FrameCommand], damage: RenderDamage) -> Bool {
    render(commands, cellPayload: nil, damage: damage, rendererFallbackReason: nil)
  }

  @discardableResult
  public func render(
    _ commands: [FrameCommand],
    cellPayload: TerminalCellPayload?,
    damage: RenderDamage
  ) -> Bool {
    render(commands, cellPayload: cellPayload, damage: damage, rendererFallbackReason: nil)
  }

  @discardableResult
  public func render(
    _ commands: [FrameCommand],
    cellPayload: TerminalCellPayload?,
    damage: RenderDamage,
    rendererFallbackReason: String?
  ) -> Bool {
    let cpuStart = ContinuousClock.now
    lastRenderFailureReason = nil
    lastDrawableAcquireDiagnostic = nil
    let dropIfBusy = dropNextFrameWhenBusy
    dropNextFrameWhenBusy = false
    let stripRepaint = repaintSidebarStrip
    repaintSidebarStrip = false
    reconcileThemeRevision()
    // A GPU command buffer that completed with `.error` (recorded off-main by
    // the completion handler) means the persistent target may be half-painted,
    // so repaint the whole surface this frame instead of trusting damage.
    if consumePendingCommandBufferRecovery() {
      targetNeedsFullRedraw = true
    }
    let selection = resolvedRendererStatus(rendererFallbackReason: rendererFallbackReason)
    rendererStatus = selection.status

    // Drop this frame if the previous GPU frame has not retired. The drawable
    // is acquired later, after offscreen work is encoded, so Core Animation's
    // limited drawable pool is held for the shortest useful interval.
    let needsFullFrame = targetNeedsFullRedraw || damage == .full
    guard
      let scheduledFrame = drawableScheduler.beginFrame(
        needsFullFrame: needsFullFrame, dropIfBusy: dropIfBusy)
    else {
      lastRenderFailureReason = .previousFrameInFlight
      return false
    }
    guard let cmdBuf = queue.makeCommandBuffer() else {
      lastRenderFailureReason = .commandBufferUnavailable
      scheduledFrame.finish()
      return false
    }
    lastFrameCompletion = nil
    cmdBuf.label = "laban.frame"

    let surfaceWPx = max(1, Int(layer.drawableSize.width.rounded()))
    let surfaceHPx = max(1, Int(layer.drawableSize.height.rounded()))
    ensureTargetTexture(width: surfaceWPx, height: surfaceHPx)
    guard let target = targetTexture else {
      lastRenderFailureReason = .targetTextureUnavailable
      scheduledFrame.finish()
      return false
    }

    var u = Uniforms(
      surfaceSizePixels: SIMD2<Float>(Float(surfaceWPx), Float(surfaceHPx)),
      scale: Float(layer.contentsScale))

    // First frame after a target realloc must clear+repaint the full surface.
    // Otherwise honour the caller's damage hint directly.
    let effectiveDamage: RenderDamage = targetNeedsFullRedraw ? .full : damage

    var passSlots = PassSlots()

    // ---------- Pass 1: terminal content into the persistent target ----------
    let didContent: Bool
    if case .partial(let yRanges) = effectiveDamage, yRanges.isEmpty {
      buildCursorInstanceList(commands: commands)
      didContent = false
    } else {
      switch selection.effectiveMode {
      case .classic:
        didContent = encodeContentPass(
          commands: commands,
          damage: effectiveDamage,
          target: target,
          surfacePxH: surfaceHPx,
          uniforms: &u,
          cmdBuf: cmdBuf)
      case .gpuDriven:
        didContent = encodeGPUCellContentPass(
          commands: commands,
          cellPayload: cellPayload,
          damage: effectiveDamage,
          target: target,
          surfacePxH: surfaceHPx,
          uniforms: &u,
          cmdBuf: cmdBuf)
      }
    }
    if targetNeedsFullRedraw && !didContent {
      lastRenderFailureReason = .fullRedrawProducedNoContent
      scheduledFrame.finish()
      return false
    }
    passSlots.contentActive = didContent

    // ---------- Pass 1b: sidebar strip ----------
    // The strip owns its pixels this frame: encoded after the content pass,
    // scissored to the sidebar's width, fed only by sidebar-source commands.
    // A pulse frame over a clean terminal repaints a narrow strip instead of
    // the whole surface, and a band-damage frame can't leave the marker
    // half-stale (the strip pass overdraws the band's sidebar slice with the
    // same frame's commands). A full redraw already repaints the strip.
    if stripRepaint, effectiveDamage != .full {
      encodeSidebarStripPass(
        commands: commands,
        target: target,
        surfacePxH: surfaceHPx,
        uniforms: &u,
        cmdBuf: cmdBuf)
    }

    let usesDisplayLinkPresent = presentQueue != nil
    let outputTexture: MTLTexture
    let drawableToPresent: (any CAMetalDrawable)?
    if usesDisplayLinkPresent {
      guard
        let presentationTarget = ensurePresentationTargetTexture(
          width: surfaceWPx, height: surfaceHPx)
      else {
        lastRenderFailureReason = .targetTextureUnavailable
        scheduledFrame.finish()
        return false
      }
      outputTexture = presentationTarget
      drawableToPresent = nil
    } else {
      let drawable = scheduledFrame.acquireDrawable(nonBlocking: dropIfBusy)
      lastDrawableAcquireDiagnostic = scheduledFrame.lastDrawableAcquireDiagnostic
      guard let drawable else {
        lastRenderFailureReason = .drawableUnavailable
        scheduledFrame.finish()
        return false
      }
      let drawableTex = drawable.texture
      guard drawableTex.width == surfaceWPx, drawableTex.height == surfaceHPx else {
        // The layer resized between target allocation and drawable acquisition.
        // Drop the uncommitted command buffer and force the retry to repaint a
        // correctly-sized target.
        targetTexture = nil
        targetNeedsFullRedraw = true
        lastRenderFailureReason = .drawableSizeMismatch
        scheduledFrame.finish()
        return false
      }
      outputTexture = drawableTex
      drawableToPresent = drawable
    }

    // ---------- Pass 2: blit persistent target → presentation texture ----------
    let presentBlitDesc = MTLBlitPassDescriptor()
    if counterBlitSupported, let cb = counterSampleBuffer,
      let attach = presentBlitDesc.sampleBufferAttachments[0]
    {
      attach.sampleBuffer = cb
      attach.startOfEncoderSampleIndex = 2
      attach.endOfEncoderSampleIndex = 3
    }
    if let blit = cmdBuf.makeBlitCommandEncoder(descriptor: presentBlitDesc) {
      blit.label = "present-blit"
      blit.copy(
        from: target, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: surfaceWPx, height: surfaceHPx, depth: 1),
        to: outputTexture, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      blit.endEncoding()
      passSlots.presentActive = true
    }

    // ---------- Pass 3: cursor overlay on the drawable ----------
    if !cursorInstances.isEmpty,
      let buf = prepareInstanceBuffer(&cursorBuffer, for: cursorInstances)
    {
      let cursorPass = MTLRenderPassDescriptor()
      // Metal render pass descriptors always provide color attachment slot 0.
      let attach = cursorPass.colorAttachments[0]!
      attach.texture = outputTexture
      attach.loadAction = .load
      attach.storeAction = .store
      if counterRenderSupported, let cb = counterSampleBuffer,
        let sa = cursorPass.sampleBufferAttachments[0]
      {
        sa.sampleBuffer = cb
        sa.startOfVertexSampleIndex = 4
        sa.endOfFragmentSampleIndex = 5
      }
      if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: cursorPass) {
        enc.label = "cursor-overlay"
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setRenderPipelineState(solidPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: cursorInstances.count)
        enc.endEncoding()
        passSlots.cursorActive = true
      }
    }

    // ---------- Pass 4: optional capture readback (drawable → CPU-readable) --
    // Only run this when something is actually consuming pngData. With a
    // ProMotion display ticking at 120 Hz, dropping the no-op blit on
    // cursor-blink frames saves measurable wall time and a memory copy
    // of the whole presented surface.
    passSlots.readbackActive = readback.encodeIfNeeded(
      from: outputTexture,
      commandBuffer: cmdBuf,
      counterSampleBuffer: counterSampleBuffer,
      counterBlitSupported: counterBlitSupported)

    self.lastFramePassSlots = passSlots
    if let drawable = drawableToPresent, dropIfBusy {
      // Paced present for scroll-animation frames: declare the intended
      // 120 Hz cadence to the compositor so a ProMotion panel holds its
      // refresh rate instead of inferring a lower one from observed
      // presents. Without the hint, one missed-frame episode lets the panel
      // settle at 60 Hz; drawable recycling then locks to the slower swap
      // rate and the pipeline cannot climb back out (the half-rate basin —
      // see the smooth-scroll ExecPlan). On non-VRR panels a 1/120 minimum
      // is weaker than vsync and changes nothing.
      cmdBuf.present(drawable, afterMinimumDuration: Self.scrollPresentMinimumDuration)
    } else if let drawable = drawableToPresent {
      cmdBuf.present(drawable)
    }
    let cpuEncodeMs = msSince(cpuStart)
    let publishedTarget = usesDisplayLinkPresent ? outputTexture : nil
    // Strong-self capture keeps the renderer alive until the GPU work
    // completes. The same handler closes out per-frame timing and releases
    // the scheduled frame once the GPU has reported gpuStartTime/gpuEndTime.
    cmdBuf.addCompletedHandler { [self] buffer in
      self.noteCommandBufferCompletion(status: buffer.status, error: buffer.error)
      if buffer.status != .error, let publishedTarget {
        self.publishLatestTarget(publishedTarget)
      }
      let gpuMs = max(0.0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0)
      // Resolve per-pass GPU times BEFORE signalling the next frame in
      // (otherwise frame N+1 could overwrite the sample buffer slots).
      let perPass = self.resolvePerPassTimingsForFrame()
      self.frameSampleLock.lock()
      self.frameSamples.append(
        FrameSample(
          cpuMs: cpuEncodeMs, gpuMs: gpuMs,
          contentMs: perPass.content,
          presentBlitMs: perPass.present,
          cursorOverlayMs: perPass.cursor,
          readbackBlitMs: perPass.readback))
      if self.frameSamples.count > Self.frameSampleCap {
        self.frameSamples.removeFirst(self.frameSamples.count - Self.frameSampleCap)
      }
      self.frameSampleLock.unlock()
      self.onFrameCompleted?()
      scheduledFrame.finish()
    }
    cmdBuf.commit()
    lastCmdBuf = cmdBuf
    if waitForFrameCompletion {
      cmdBuf.waitUntilCompleted()
    }
    targetNeedsFullRedraw = false
    lastRenderedThemeRevision = Theme.revision
    return true
  }

  private func reconcileThemeRevision() {
    guard Theme.revision != lastRenderedThemeRevision else { return }
    invalidateContentForThemeChange()
  }

  private func noteCommandBufferCompletion(status: MTLCommandBufferStatus, error: Error?) {
    guard status == .error else { return }
    let failure = CommandBufferFailure(
      status: Int(status.rawValue), error: error?.localizedDescription)
    frameSampleLock.lock()
    lastCommandBufferError = failure
    pendingCommandBufferRecovery = true
    frameSampleLock.unlock()
    Self.log.error(
      "GPU command buffer failed (status \(status.rawValue, privacy: .public)): \(error?.localizedDescription ?? "no detail", privacy: .public) — forcing a full repaint"
    )
  }

  /// Reads and clears the pending GPU-error recovery flag. Called at the top of
  /// `render` on the main thread; the flag is set off-main by the completion
  /// handler, so access is serialised through `frameSampleLock`.
  private func consumePendingCommandBufferRecovery() -> Bool {
    frameSampleLock.lock()
    defer { frameSampleLock.unlock() }
    guard pendingCommandBufferRecovery else { return false }
    pendingCommandBufferRecovery = false
    return true
  }

  private func resolvedRendererStatus(
    rendererFallbackReason: String?
  ) -> (effectiveMode: RendererMode, status: RendererStatus) {
    if let rendererStatusOverride {
      return (.classic, rendererStatusOverride)
    }
    let requested = requestedRendererMode
    guard requested == .gpuDriven else {
      return (
        .classic,
        RendererStatus(
          configuredRenderer: requested.rawValue,
          effectiveRenderer: RendererMode.classic.rawValue,
          textCompositeModel: .encodedSRGBCompatibility)
      )
    }
    if let rendererFallbackReason {
      return (
        .classic,
        RendererStatus(
          configuredRenderer: requested.rawValue,
          effectiveRenderer: RendererMode.classic.rawValue,
          fallbackReason: rendererFallbackReason,
          textCompositeModel: .encodedSRGBCompatibility)
      )
    }
    if #available(macOS 26, *) {
      return (
        .gpuDriven,
        RendererStatus(
          configuredRenderer: requested.rawValue,
          effectiveRenderer: RendererMode.gpuDriven.rawValue,
          textCompositeModel: .encodedSRGBCompatibility)
      )
    }
    return (
      .classic,
      RendererStatus(
        configuredRenderer: requested.rawValue,
        effectiveRenderer: RendererMode.classic.rawValue,
        fallbackReason: "gpuDrivenUnavailableOnCurrentOS",
        textCompositeModel: .encodedSRGBCompatibility)
    )
  }

  /// Slots in flight for the most recent frame. Read by the completion
  /// handler so we know which sample-buffer ranges contain valid data.
  private var lastFramePassSlots = PassSlots()

  private func clearPresentationTargets() {
    presentationTargetRing.removeAll(keepingCapacity: true)
    presentationTargetRingCursor = 0
    presentTargetLock.lock()
    latestPresentedTarget = nil
    presentTargetLock.unlock()
  }

  private func ensurePresentationTargetTexture(width: Int, height: Int) -> MTLTexture? {
    if presentationTargetRing.count == Self.presentationTargetRingDepth,
      presentationTargetRing[0].width == width,
      presentationTargetRing[0].height == height
    {
      presentationTargetRingCursor =
        (presentationTargetRingCursor + 1) % Self.presentationTargetRingDepth
      return presentationTargetRing[presentationTargetRingCursor]
    }

    presentTargetLock.lock()
    latestPresentedTarget = nil
    presentTargetLock.unlock()
    presentationTargetRing.removeAll(keepingCapacity: true)
    for i in 0..<Self.presentationTargetRingDepth {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: layer.pixelFormat,
        width: width,
        height: height,
        mipmapped: false)
      desc.usage = [.renderTarget, .shaderRead]
      desc.storageMode = .private
      guard let texture = device.makeTexture(descriptor: desc) else { return nil }
      texture.label = "laban.metal.present-target.\(i)"
      presentationTargetRing.append(texture)
    }
    presentationTargetRingCursor = 0
    return presentationTargetRing[0]
  }

  private func encodeBlit(
    from source: MTLTexture,
    to destination: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let signposter = RenderEncodeSignpost.signposter
    let spanState = signposter.beginInterval(
      "metal.encodeBlit",
      "\(source.width, privacy: .public)x\(source.height, privacy: .public)")
    defer { signposter.endInterval("metal.encodeBlit", spanState) }
    guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
    blit.label = "laban.metal.displaylink-present-blit"
    blit.copy(
      from: source,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
      to: destination,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
  }

  private func presentLatestTarget(into drawable: any CAMetalDrawable) -> Bool {
    presentTargetLock.lock()
    let target = latestPresentedTarget
    presentTargetLock.unlock()
    guard let target,
      target.width == drawable.texture.width,
      target.height == drawable.texture.height
    else { return false }
    guard let presentQueue,
      let commandBuffer = presentQueue.makeCommandBuffer()
    else { return false }
    encodeBlit(from: target, to: drawable.texture, commandBuffer: commandBuffer)
    commandBuffer.present(drawable)
    commandBuffer.commit()
    return true
  }

  private func publishLatestTarget(_ target: MTLTexture) {
    presentTargetLock.lock()
    latestPresentedTarget = target
    presentTargetLock.unlock()
    if #available(macOS 14.0, *) {
      presentDisplayLink?.notifyContentPublished()
    }
  }

  /// Allocate (or reallocate) the persistent render target to match the
  /// layer's drawable size. Same pixel format so the end-of-frame blit is a
  /// GPU memcpy once the actual drawable is acquired.
  private func ensureTargetTexture(width: Int, height: Int) {
    if let t = targetTexture,
      t.width == width,
      t.height == height,
      t.pixelFormat == layer.pixelFormat
    {
      return
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: layer.pixelFormat,
      width: width,
      height: height,
      mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .private
    targetTexture = device.makeTexture(descriptor: desc)
    targetNeedsFullRedraw = true
  }

  private func growGlyphAtlas(forSidebar: Bool) -> Bool {
    let shared = sidebarGlyphAtlas === glyphAtlas
    let current = forSidebar && !shared ? sidebarGlyphAtlas : glyphAtlas
    let nextSize = min(current.textureSize * 2, Self.maxGlyphAtlasTextureSize)
    guard nextSize > current.textureSize else { return false }

    let activeFontAtlas = forSidebar && !shared ? sidebarFontAtlas : fontAtlas
    let cellAdvance = forSidebar && !shared ? sidebarCellAdvance : glyphCellAdvance
    let cellHeight = forSidebar && !shared ? sidebarCellHeight : glyphCellHeight
    guard
      let fresh = MetalGlyphAtlas(
        device: device,
        cellWidth: cellAdvance,
        cellHeight: cellHeight,
        descent: activeFontAtlas.descent,
        scale: layer.contentsScale,
        textureSize: nextSize)
    else { return false }

    if forSidebar && !shared {
      sidebarGlyphAtlas = fresh
    } else {
      glyphAtlas = fresh
      if shared {
        sidebarGlyphAtlas = fresh
      }
    }
    targetNeedsFullRedraw = true
    return true
  }

  private func growColorGlyphAtlas() -> Bool {
    let nextSize = min(colorGlyphAtlas.textureSize * 2, Self.maxGlyphAtlasTextureSize)
    guard nextSize > colorGlyphAtlas.textureSize else { return false }
    guard
      let fresh = ColorGlyphAtlas(
        device: device,
        cellWidth: glyphCellAdvance,
        cellHeight: glyphCellHeight,
        descent: fontAtlas.descent,
        scale: layer.contentsScale,
        textureSize: nextSize)
    else { return false }
    colorGlyphAtlas = fresh
    targetNeedsFullRedraw = true
    return true
  }

  /// Pass 1: render terminal cells (everything but the cursor) into the
  /// persistent target. Honours `damage`:
  /// - `.full`: clear + draw all instances.
  /// - `.partial([])`: skip the pass entirely (target unchanged).
  /// - `.partial(ranges)`: load + scissor to the union bounding box +
  ///   draw all instances. The scissor culls clean rows; all instances are
  ///   submitted because tracking which instance touches which row would
  ///   be more expensive than the GPU early-rejecting them via scissor.
  /// Returns true if the content render pass actually executed (false when
  /// `damage == .partial([])` or encoder construction failed). The caller
  /// uses this to mark sample-buffer slot 0/1 as valid.
  /// The colour a full-redraw clear should use: the terminal's default
  /// background (from the replace rectangle the FrameProducer always emits), so
  /// a full redraw never flashes black under a themed terminal. If no terminal
  /// canvas exists, the renderer-neutral contract requires transparent black.
  static func fullRedrawClearColor(_ commands: [FrameCommand]) -> MTLClearColor {
    var rgba: UInt32?
    for case .rect(_, let color, let source, let compositing) in commands
    where source == .terminal && compositing == .replace {
      rgba = color
      break
    }
    guard let c = rgba else {
      return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }
    let red = Double((c >> 24) & 0xFF) / 255.0
    let green = Double((c >> 16) & 0xFF) / 255.0
    let blue = Double((c >> 8) & 0xFF) / 255.0
    let alpha = Double(c & 0xFF) / 255.0
    if alpha == 1 {
      // Preserve the shipped opaque clear path exactly; premultiplication is
      // only work when the resolved canvas actually carries alpha.
      return MTLClearColor(red: red, green: green, blue: blue, alpha: 1)
    }
    return MTLClearColor(
      red: red * alpha,
      green: green * alpha,
      blue: blue * alpha,
      alpha: alpha)
  }

  /// Transparent-black overwrite quads for every partial damage band. Keeping
  /// these as distinct instances (rather than one union scissor) preserves clean
  /// rows between disjoint bands.
  private func partialDamageEraseInstances(
    _ damage: RenderDamage,
    targetWidth: Int
  ) -> [SolidInstance] {
    guard case .partial(let ranges) = damage else { return [] }
    let scale = Float(layer.contentsScale)
    let width = Float(targetWidth)
    return ranges.compactMap { range in
      guard range.height > 0 else { return nil }
      return SolidInstance(
        origin: SIMD2<Float>(0, Float(range.y) * scale),
        size: SIMD2<Float>(width, Float(range.height) * scale),
        color: SIMD4<Float>(repeating: 0))
    }
  }

  /// Replay a draw once per exact dirty band. A union scissor would also cover
  /// clean rows between disjoint ranges, while recursively encoding one pass
  /// per band would overwrite the shared instance buffers before the command
  /// buffer is committed.
  private func drawThroughDamageScissors(
    _ damage: RenderDamage,
    target: MTLTexture,
    surfacePxH: Int,
    encoder: MTLRenderCommandEncoder,
    draw: () -> Void
  ) {
    switch damage {
    case .full:
      draw()
    case .partial(let ranges):
      for range in ranges {
        guard
          let scissor = scissorRectFromYRanges(
            [range],
            surfacePxW: target.width,
            surfacePxH: surfacePxH,
            scale: layer.contentsScale)
        else { continue }
        encoder.setScissorRect(scissor)
        draw()
      }
    }
  }

  private func fullRedrawClearColor(_ commands: [FrameCommand]) -> MTLClearColor {
    Self.fullRedrawClearColor(commands)
  }

  @discardableResult
  private func encodeContentPass(
    commands: [FrameCommand],
    damage: RenderDamage,
    target: MTLTexture,
    surfacePxH: Int,
    uniforms u: inout Uniforms,
    cmdBuf: MTLCommandBuffer
  ) -> Bool {
    // Build instance lists once for both the content pass and the cursor pass.
    buildInstanceLists(commands: commands, surfacePxH: surfacePxH, damage: damage)

    // Skip the content pass entirely if the caller said nothing changed.
    if case .partial(let yRanges) = damage, yRanges.isEmpty {
      return false
    }

    let pass = MTLRenderPassDescriptor()
    // Metal render pass descriptors always provide color attachment slot 0.
    let attach = pass.colorAttachments[0]!
    attach.texture = target
    attach.storeAction = .store

    var scissor: MTLScissorRect?
    switch damage {
    case .full:
      attach.loadAction = .clear
      // Clear to the terminal's own default background, not black. A full redraw
      // happens on resizes and on alternate-screen swaps (e.g. quitting btop and
      // starting top); clearing to black there flashes black under a themed
      // terminal wherever the draw does not immediately cover. The FrameProducer
      // always emits a terminal-area background rect, so reuse its colour.
      attach.clearColor = fullRedrawClearColor(commands)
    case .partial(let yRanges):
      attach.loadAction = .load  // preserve clean rows from previous frame
      scissor = scissorRectFromYRanges(
        yRanges,
        surfacePxW: target.width,
        surfacePxH: surfacePxH,
        scale: layer.contentsScale)
    }

    if counterRenderSupported, let cb = counterSampleBuffer,
      let sa = pass.sampleBufferAttachments[0]
    {
      sa.sampleBuffer = cb
      sa.startOfVertexSampleIndex = 0
      sa.endOfFragmentSampleIndex = 1
    }

    let solidFrameBuffer: MTLBuffer?
    if solidInstances.isEmpty {
      solidFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&solidBuffer, for: solidInstances) else {
        return false
      }
      solidFrameBuffer = buffer
    }

    let replaceSolidFrameBuffer: MTLBuffer?
    if replaceSolidInstances.isEmpty {
      replaceSolidFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&replaceSolidBuffer, for: replaceSolidInstances)
      else { return false }
      replaceSolidFrameBuffer = buffer
    }

    let damageEraseInstances = partialDamageEraseInstances(damage, targetWidth: target.width)
    let damageEraseFrameBuffer: MTLBuffer?
    if damageEraseInstances.isEmpty {
      damageEraseFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&damageEraseBuffer, for: damageEraseInstances)
      else { return false }
      damageEraseFrameBuffer = buffer
    }

    let glyphFrameBuffer: MTLBuffer?
    if glyphInstances.isEmpty {
      glyphFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&glyphBuffer, for: glyphInstances) else {
        return false
      }
      glyphFrameBuffer = buffer
    }

    let colorGlyphFrameBuffer: MTLBuffer?
    if colorGlyphInstances.isEmpty {
      colorGlyphFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&colorGlyphBuffer, for: colorGlyphInstances) else {
        return false
      }
      colorGlyphFrameBuffer = buffer
    }

    let sidebarGlyphFrameBuffer: MTLBuffer?
    if sidebarGlyphInstances.isEmpty {
      sidebarGlyphFrameBuffer = nil
    } else {
      guard
        let buffer = prepareInstanceBuffer(&sidebarGlyphBuffer, for: sidebarGlyphInstances)
      else {
        return false
      }
      sidebarGlyphFrameBuffer = buffer
    }

    guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: pass) else {
      return false
    }
    encoder.label = "terminal-content"
    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    if let s = scissor {
      encoder.setScissorRect(s)
    }

    if let buf = damageEraseFrameBuffer {
      encoder.setRenderPipelineState(replaceSolidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: damageEraseInstances.count)
      }
    }
    if let buf = replaceSolidFrameBuffer {
      encoder.setRenderPipelineState(replaceSolidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: replaceSolidInstances.count)
      }
    }

    if let buf = solidFrameBuffer {
      encoder.setRenderPipelineState(solidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: solidInstances.count)
      }
    }
    if let buf = glyphFrameBuffer {
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(glyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: glyphInstances.count)
      }
    }
    if let buf = colorGlyphFrameBuffer {
      encoder.setRenderPipelineState(colorGlyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(colorGlyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: colorGlyphInstances.count)
      }
    }
    if let buf = sidebarGlyphFrameBuffer {
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(sidebarGlyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: sidebarGlyphInstances.count)
      }
    }
    encoder.endEncoding()
    return true
  }

  @discardableResult
  private func encodeGPUCellContentPass(
    commands: [FrameCommand],
    cellPayload: TerminalCellPayload?,
    damage: RenderDamage,
    target: MTLTexture,
    surfacePxH: Int,
    uniforms u: inout Uniforms,
    cmdBuf: MTLCommandBuffer
  ) -> Bool {
    if commandsContainColorGlyph(commands) {
      return encodeContentPass(
        commands: commands,
        damage: damage,
        target: target,
        surfacePxH: surfacePxH,
        uniforms: &u,
        cmdBuf: cmdBuf)
    }

    let builtInstances: Bool
    if let cellPayload {
      builtInstances = buildGPUCellInstanceLists(
        payload: cellPayload,
        commands: commands,
        surfacePxH: surfacePxH,
        damage: damage)
    } else {
      builtInstances = buildGPUCellInstanceLists(
        commands: commands,
        surfacePxH: surfacePxH,
        damage: damage)
    }
    guard builtInstances else {
      if cellPayload != nil {
        targetNeedsFullRedraw = true
        return false
      }
      if gpuCellCommandRequiresFullRedraw {
        // Geometry changed under partial damage: repaint the whole target next
        // frame rather than classic-fallback with the same partial damage,
        // which would also leave stale pixels outside the scissor band.
        gpuCellCommandRequiresFullRedraw = false
        targetNeedsFullRedraw = true
        return false
      }
      return encodeContentPass(
        commands: commands,
        damage: damage,
        target: target,
        surfacePxH: surfacePxH,
        uniforms: &u,
        cmdBuf: cmdBuf)
    }

    if case .partial(let yRanges) = damage, yRanges.isEmpty {
      return false
    }

    let pass = MTLRenderPassDescriptor()
    // Metal render pass descriptors always provide color attachment slot 0.
    let attach = pass.colorAttachments[0]!
    attach.texture = target
    attach.storeAction = .store

    var scissor: MTLScissorRect?
    switch damage {
    case .full:
      attach.loadAction = .clear
      attach.clearColor = fullRedrawClearColor(commands)
    case .partial(let yRanges):
      attach.loadAction = .load
      scissor = scissorRectFromYRanges(
        yRanges,
        surfacePxW: target.width,
        surfacePxH: surfacePxH,
        scale: layer.contentsScale)
    }

    if counterRenderSupported, let cb = counterSampleBuffer,
      let sa = pass.sampleBufferAttachments[0]
    {
      sa.sampleBuffer = cb
      sa.startOfVertexSampleIndex = 0
      sa.endOfFragmentSampleIndex = 1
    }

    let solidFrameBuffer: MTLBuffer?
    if solidInstances.isEmpty {
      solidFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&solidBuffer, for: solidInstances) else {
        return false
      }
      solidFrameBuffer = buffer
    }

    let replaceSolidFrameBuffer: MTLBuffer?
    if replaceSolidInstances.isEmpty {
      replaceSolidFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&replaceSolidBuffer, for: replaceSolidInstances)
      else { return false }
      replaceSolidFrameBuffer = buffer
    }

    let damageEraseInstances = partialDamageEraseInstances(damage, targetWidth: target.width)
    let damageEraseFrameBuffer: MTLBuffer?
    if damageEraseInstances.isEmpty {
      damageEraseFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&damageEraseBuffer, for: damageEraseInstances)
      else { return false }
      damageEraseFrameBuffer = buffer
    }

    let sidebarGlyphFrameBuffer: MTLBuffer?
    if sidebarGlyphInstances.isEmpty {
      sidebarGlyphFrameBuffer = nil
    } else {
      guard
        let buffer = prepareInstanceBuffer(&sidebarGlyphBuffer, for: sidebarGlyphInstances)
      else {
        return false
      }
      sidebarGlyphFrameBuffer = buffer
    }

    let cellGlyphFrameBuffer = prepareCellGlyphBuffer()

    guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: pass) else {
      return false
    }
    encoder.label = "terminal-content-gpu-cell"
    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    if let s = scissor {
      encoder.setScissorRect(s)
    }

    if let buf = damageEraseFrameBuffer {
      encoder.setRenderPipelineState(replaceSolidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: damageEraseInstances.count)
      }
    }
    if let buf = replaceSolidFrameBuffer {
      encoder.setRenderPipelineState(replaceSolidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: replaceSolidInstances.count)
      }
    }

    if let buf = solidFrameBuffer {
      encoder.setRenderPipelineState(solidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: solidInstances.count)
      }
    }
    if let buf = sidebarGlyphFrameBuffer {
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(sidebarGlyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      drawThroughDamageScissors(
        damage, target: target, surfacePxH: surfacePxH, encoder: encoder
      ) {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: sidebarGlyphInstances.count)
      }
    }
    if let buf = cellGlyphFrameBuffer {
      encoder.setRenderPipelineState(cellGlyphPipeline)
      encoder.setFragmentTexture(glyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      // The cell-glyph buffer is the persistent full grid, so this draw rasterizes
      // every row that falls inside the active scissor. Under partial damage the
      // union bounding-box scissor (set above for the background/sidebar passes)
      // spans any clean rows lying between two disjoint dirty runs — e.g. an
      // animated spinner far from updating output. Those interior rows carry no
      // fresh background solid (the payload only emits backgrounds for dirty rows),
      // so re-running the glyph pass over them re-composites their anti-aliased
      // edges onto the loaded target every frame and the text slowly accumulates
      // and shimmers. Scope the glyph rasterization to exactly the dirty Y ranges
      // so clean rows stay untouched by the persistent target's load action.
      if cellPayload != nil, case .partial = damage,
        let geometry = cellGlyphGridGeometry,
        !cellGlyphUploadRanges.isEmpty
      {
        let stride = MemoryLayout<CellGlyph>.stride
        for range in cellGlyphUploadRanges {
          guard range.lowerBound >= 0, range.upperBound <= cellGlyphs.count,
            !range.isEmpty
          else { continue }
          let startRow = range.lowerBound / geometry.cols
          let endRow = (range.upperBound - 1) / geometry.cols
          guard startRow >= 0, endRow < geometry.rows else { continue }
          let rowRange = DirtyYRange(
            y: geometry.originY + CGFloat(startRow) * geometry.cellHeight,
            height: CGFloat(endRow - startRow + 1) * geometry.cellHeight)
          guard
            let rangeScissor = scissorRectFromYRanges(
              [rowRange],
              surfacePxW: target.width,
              surfacePxH: surfacePxH,
              scale: layer.contentsScale)
          else { continue }
          encoder.setScissorRect(rangeScissor)
          encoder.setVertexBuffer(buf, offset: range.lowerBound * stride, index: 0)
          encoder.drawPrimitives(
            type: .triangle, vertexStart: 0,
            vertexCount: 6, instanceCount: range.count)
        }
      } else if case .partial(let yRanges) = damage {
        for range in yRanges {
          guard
            let rangeScissor = scissorRectFromYRanges(
              [range],
              surfacePxW: target.width,
              surfacePxH: surfacePxH,
              scale: layer.contentsScale)
          else { continue }
          encoder.setScissorRect(rangeScissor)
          encoder.setVertexBuffer(buf, offset: 0, index: 0)
          encoder.drawPrimitives(
            type: .triangle, vertexStart: 0,
            vertexCount: 6, instanceCount: cellGlyphs.count)
        }
      } else {
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: cellGlyphs.count)
      }
    }
    encoder.endEncoding()
    return true
  }

  /// Width of the sidebar strip in device pixels, taken from the widest
  /// sidebar-source rect. The producer's first sidebar command is a
  /// full-strip background rect, so this is the strip's true extent — no
  /// extra plumbing from the layout layer needed.
  private static func sidebarStripWidthPx(commands: [FrameCommand], scale: CGFloat) -> Int {
    var maxX: CGFloat = 0
    for cmd in commands {
      if case .rect(let rect, _, .sidebar, _) = cmd {
        maxX = max(maxX, rect.maxX)
      }
    }
    guard maxX > 0 else { return 0 }
    return Int((maxX * scale).rounded(.up))
  }

  /// Repaint only the sidebar strip on the persistent target. Shared by both
  /// renderer modes: instances are rebuilt from sidebar-source commands into
  /// dedicated buffers, so the pass neither depends on what the content pass
  /// built (its sidebar instances may be damage-scoped to a band, or absent)
  /// nor disturbs the terminal cells right of the strip (scissor).
  @discardableResult
  private func encodeSidebarStripPass(
    commands: [FrameCommand],
    target: MTLTexture,
    surfacePxH: Int,
    uniforms u: inout Uniforms,
    cmdBuf: MTLCommandBuffer
  ) -> Bool {
    let widthPx = Self.sidebarStripWidthPx(commands: commands, scale: layer.contentsScale)
    guard widthPx > 0 else { return false }
    guard buildSidebarStripInstanceLists(commands: commands) else { return false }
    guard
      !stripReplaceSolidInstances.isEmpty || !stripSolidInstances.isEmpty
        || !stripGlyphInstances.isEmpty
    else { return false }

    let replaceSolidFrameBuffer: MTLBuffer?
    if stripReplaceSolidInstances.isEmpty {
      replaceSolidFrameBuffer = nil
    } else {
      guard
        let buffer = prepareInstanceBuffer(
          &stripReplaceSolidBuffer, for: stripReplaceSolidInstances)
      else { return false }
      replaceSolidFrameBuffer = buffer
    }

    let solidFrameBuffer: MTLBuffer?
    if stripSolidInstances.isEmpty {
      solidFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&stripSolidBuffer, for: stripSolidInstances)
      else { return false }
      solidFrameBuffer = buffer
    }
    let glyphFrameBuffer: MTLBuffer?
    if stripGlyphInstances.isEmpty {
      glyphFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&stripGlyphBuffer, for: stripGlyphInstances)
      else { return false }
      glyphFrameBuffer = buffer
    }

    let pass = MTLRenderPassDescriptor()
    // Metal render pass descriptors always provide color attachment slot 0.
    let attach = pass.colorAttachments[0]!
    attach.texture = target
    attach.loadAction = .load  // terminal pixels right of the scissor survive
    attach.storeAction = .store
    guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: pass) else { return false }
    encoder.label = "sidebar-strip"
    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setScissorRect(
      MTLScissorRect(
        x: 0, y: 0,
        width: min(widthPx, target.width),
        height: min(surfacePxH, target.height)))
    if let buf = replaceSolidFrameBuffer {
      encoder.setRenderPipelineState(replaceSolidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: stripReplaceSolidInstances.count)
    }
    if let buf = solidFrameBuffer {
      encoder.setRenderPipelineState(solidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: stripSolidInstances.count)
    }
    if let buf = glyphFrameBuffer {
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(sidebarGlyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: stripGlyphInstances.count)
    }
    encoder.endEncoding()
    return true
  }

  private func buildSidebarStripInstanceLists(commands: [FrameCommand]) -> Bool {
    var attempts = 0
    while true {
      sidebarGlyphAtlas.clearOverflowFlag()
      buildSidebarStripInstanceListsOnce(commands: commands)
      guard sidebarGlyphAtlas.didOverflow else { return true }
      attempts += 1
      guard attempts < 4, growGlyphAtlas(forSidebar: true) else { return false }
      // A shared atlas relocated the terminal glyphs too — the persistent
      // cell-glyph cache's UVs are stale, so force its rebuild next frame.
      if sidebarGlyphAtlas === glyphAtlas {
        cellGlyphGridGeometry = nil
      }
    }
  }

  private func buildSidebarStripInstanceListsOnce(commands: [FrameCommand]) {
    stripReplaceSolidInstances.removeAll(keepingCapacity: true)
    stripSolidInstances.removeAll(keepingCapacity: true)
    stripGlyphInstances.removeAll(keepingCapacity: true)
    let scale = Float(layer.contentsScale)

    @inline(__always)
    func appendSolid(
      rect: CGRect,
      color: UInt32,
      compositing: FrameCompositingMode = .sourceOver
    ) {
      guard rect.width > 0, rect.height > 0 else { return }
      let instance = SolidInstance(
        origin: SIMD2<Float>(Float(rect.origin.x) * scale, Float(rect.origin.y) * scale),
        size: SIMD2<Float>(Float(rect.width) * scale, Float(rect.height) * scale),
        color: rgbaToFloat4(color))
      if compositing == .replace {
        stripReplaceSolidInstances.append(instance)
      } else {
        stripSolidInstances.append(instance)
      }
    }

    for cmd in commands {
      switch cmd {
      case .rect(let rect, let color, .sidebar, let compositing):
        appendSolid(rect: rect, color: color, compositing: compositing)
      case .glyphRun(
        let origin, let text, let fg, _, let attrs, .sidebar,
        let underlineStyle, let underlineColor, _, _, _, _, _):
        let font = styledFont(for: attrs, in: sidebarFontAtlas)
        let traits = CTFontGetSymbolicTraits(font)
        let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
        let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)
        let atlasW = Float(sidebarGlyphAtlas.textureSize)
        let atlasH = Float(sidebarGlyphAtlas.textureSize)
        for (cellIndex, cluster) in text.enumerated() {
          guard
            let entry = sidebarGlyphAtlas.entry(
              character: cluster, font: font,
              boldFallback: needsBoldFallback,
              italicFallback: needsItalicFallback)
          else { continue }
          let cellX = origin.x + CGFloat(cellIndex) * sidebarCellAdvance
          stripGlyphInstances.append(
            GlyphInstance(
              origin: SIMD2<Float>(
                Float(cellX + entry.logicalOriginX) * scale,
                Float(origin.y) * scale),
              size: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
              uvOrigin: SIMD2<Float>(
                Float(entry.originX) / atlasW, Float(entry.originY) / atlasH),
              uvSize: SIMD2<Float>(
                Float(entry.pixelWidth) / atlasW, Float(entry.pixelHeight) / atlasH),
              color: rgbaToFloat4(fg)))
        }
        emitDecorations(
          for: text, at: origin, attributes: attrs,
          cellAdvance: sidebarCellAdvance,
          cellHeight: sidebarCellHeight,
          descent: sidebarFontAtlas.descent,
          fg: fg,
          underlineStyle: underlineStyle, underlineColor: underlineColor,
          appendSolid: { rect, color in appendSolid(rect: rect, color: color) })
      default:
        break
      }
    }
  }

  /// Compute the union bounding-box scissor rect (in device pixels) covering
  /// all dirty Y ranges. Returns nil for an empty list. CG has y-up; Metal
  /// scissor rects use y-down (origin top-left), so we flip here.
  private func scissorRectFromYRanges(
    _ ranges: [DirtyYRange], surfacePxW: Int, surfacePxH: Int, scale: CGFloat
  ) -> MTLScissorRect? {
    guard !ranges.isEmpty else { return nil }
    var minY = CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    for r in ranges {
      minY = min(minY, r.y)
      maxY = max(maxY, r.y + r.height)
    }
    let topPx = max(0, Int(((CGFloat(surfacePxH) / scale - maxY) * scale).rounded(.down)))
    let bottomPx = min(
      surfacePxH, Int(((CGFloat(surfacePxH) / scale - minY) * scale).rounded(.up)))
    let height = max(0, bottomPx - topPx)
    guard height > 0 else { return nil }
    return MTLScissorRect(x: 0, y: topPx, width: surfacePxW, height: height)
  }

  // MARK: - Frame encoding

  /// Walks the FrameCommand list once, packing solid/glyph/cursor instances
  /// into separate buffers. Cursor commands are split out so the cursor pass
  /// (which lives on the drawable, above the persistent target) doesn't
  /// pollute the persistent terminal target with a blink-rate redraw.
  private func buildInstanceLists(
    commands: [FrameCommand],
    surfacePxH: Int,
    damage: RenderDamage
  ) {
    var attempts = 0
    let damageBounds = Self.useClassicDamageScoped ? Self.damageYBounds(damage) : nil
    while true {
      glyphAtlas.clearOverflowFlag()
      colorGlyphAtlas.clearOverflowFlag()
      if sidebarGlyphAtlas !== glyphAtlas {
        sidebarGlyphAtlas.clearOverflowFlag()
      }
      buildInstanceListsOnce(
        commands: commands,
        surfacePxH: surfacePxH,
        damageBounds: damageBounds)

      let terminalOverflow = glyphAtlas.didOverflow
      let colorOverflow = colorGlyphAtlas.didOverflow
      let sidebarOverflow = sidebarGlyphAtlas.didOverflow
      guard terminalOverflow || colorOverflow || sidebarOverflow else { return }

      attempts += 1
      guard attempts < 4 else { return }

      var grew = false
      if terminalOverflow {
        grew = growGlyphAtlas(forSidebar: false) || grew
      }
      if colorOverflow {
        grew = growColorGlyphAtlas() || grew
      }
      if sidebarOverflow && !(terminalOverflow && sidebarGlyphAtlas === glyphAtlas) {
        grew = growGlyphAtlas(forSidebar: true) || grew
      }
      guard grew else { return }
    }
  }

  private static let gpuCellActiveFlag: UInt32 = 1
  private static let gpuCellSupportedAttributes = TextAttributes.gpuCellRenderableMask
  private static let gpuCellFontAttributes: TextAttributes = [.bold, .italic]
  private static let gpuCellDecorationAttributes: TextAttributes = [
    .underline, .strikethrough, .overline,
  ]
  private static let gridAlignmentEpsilon: CGFloat = 0.001

  private struct TerminalGridGeometry: Equatable {
    var originX: CGFloat
    var originY: CGFloat
    var cols: Int
    var rows: Int
    var cellAdvance: CGFloat
    var cellHeight: CGFloat
    var scale: CGFloat
    var fontPointSize: CGFloat
    var fontDescent: CGFloat
    var fontCellAdvance: CGFloat
    var fontCellHeight: CGFloat

    var cellCount: Int { max(0, cols * rows) }

    func index(cellX: CGFloat, cellY: CGFloat, cellOffset: Int) -> Int? {
      let rawCol = (cellX - originX) / cellAdvance
      let rawRow = (cellY - originY) / cellHeight
      let roundedCol = rawCol.rounded()
      let roundedRow = rawRow.rounded()
      guard abs(rawCol - roundedCol) <= MetalRenderer.gridAlignmentEpsilon,
        abs(rawRow - roundedRow) <= MetalRenderer.gridAlignmentEpsilon
      else {
        return nil
      }
      let col = Int(roundedCol) + cellOffset
      let row = Int(roundedRow)
      guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
      return row * cols + col
    }
  }

  private static var emptyCellGlyph: CellGlyph {
    CellGlyph(
      originPx: .zero,
      sizePx: .zero,
      uvOrigin: .zero,
      uvSize: .zero,
      flags: 0,
      fg: .zero)
  }

  private func terminalGridGeometry(commands: [FrameCommand]) -> TerminalGridGeometry? {
    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude

    @inline(__always)
    func include(_ rect: CGRect) {
      guard rect.width > 0, rect.height > 0 else { return }
      minX = min(minX, rect.minX)
      minY = min(minY, rect.minY)
      maxX = max(maxX, rect.maxX)
      maxY = max(maxY, rect.maxY)
    }

    for cmd in commands {
      switch cmd {
      case .rect(let rect, _, let source, _) where source == .terminal:
        include(rect)
      case .glyphRun(let origin, let text, _, _, _, let source, _, _, _, _, _, _, _)
      where source == .terminal:
        guard !text.isEmpty else { continue }
        include(
          CGRect(
            x: origin.x,
            y: origin.y,
            width: CGFloat(text.count) * glyphCellAdvance,
            height: glyphCellHeight))
      default:
        break
      }
    }

    guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
      maxX > minX, maxY > minY,
      glyphCellAdvance > 0, glyphCellHeight > 0
    else { return nil }

    let cols = max(1, Int(((maxX - minX) / glyphCellAdvance).rounded()))
    let rows = max(1, Int(((maxY - minY) / glyphCellHeight).rounded()))
    return TerminalGridGeometry(
      originX: minX,
      originY: minY,
      cols: cols,
      rows: rows,
      cellAdvance: glyphCellAdvance,
      cellHeight: glyphCellHeight,
      scale: layer.contentsScale,
      fontPointSize: fontAtlas.pointSize,
      fontDescent: fontAtlas.descent,
      fontCellAdvance: glyphCellAdvance,
      fontCellHeight: glyphCellHeight)
  }

  private func rowsToPatch(
    for damageBounds: DamageYBounds?,
    geometry: TerminalGridGeometry?
  ) -> [Bool] {
    guard let damageBounds, let geometry else { return [] }
    var rows = [Bool](repeating: false, count: geometry.rows)
    let rawStart = ((damageBounds.minY - geometry.originY) / geometry.cellHeight).rounded(.down)
    let rawEnd = ((damageBounds.maxY - geometry.originY) / geometry.cellHeight).rounded(.up)
    let start = max(0, min(geometry.rows, Int(rawStart)))
    let end = max(0, min(geometry.rows, Int(rawEnd)))
    guard start < end else { return rows }
    for row in start..<end {
      rows[row] = true
    }
    return rows
  }

  private func terminalGridGeometry(payload: TerminalCellPayload) -> TerminalGridGeometry? {
    guard payload.rows > 0, payload.cols > 0,
      payload.cellSize.width > 0, payload.cellSize.height > 0
    else { return nil }
    return TerminalGridGeometry(
      originX: payload.origin.x,
      originY: payload.origin.y + payload.contentYOffset,
      cols: payload.cols,
      rows: payload.rows,
      cellAdvance: payload.cellSize.width,
      cellHeight: payload.cellSize.height,
      scale: layer.contentsScale,
      fontPointSize: fontAtlas.pointSize,
      fontDescent: fontAtlas.descent,
      fontCellAdvance: glyphCellAdvance,
      fontCellHeight: glyphCellHeight)
  }

  private func resetPayloadRowsWithFullBackgroundRun(count: Int) {
    if payloadRowsWithFullBackgroundRun.count != count {
      payloadRowsWithFullBackgroundRun.removeAll(keepingCapacity: true)
      payloadRowsWithFullBackgroundRun.reserveCapacity(count)
      payloadRowsWithFullBackgroundRun.append(contentsOf: repeatElement(false, count: count))
    } else {
      for index in payloadRowsWithFullBackgroundRun.indices {
        payloadRowsWithFullBackgroundRun[index] = false
      }
    }
  }

  private static func gpuCellPayloadFailurePreview(
    glyph: TerminalCellPayload.Glyph,
    payload: TerminalCellPayload
  ) -> String? {
    if let scalarValue = glyph.scalarValue, let scalar = Unicode.Scalar(scalarValue) {
      return debugEscapedPreview(String(scalar))
    }
    if let range = glyph.utf8Range,
      range.lowerBound >= 0,
      range.upperBound <= payload.utf8Bytes.count
    {
      return debugEscapedPreview(String(decoding: payload.utf8Bytes[range], as: UTF8.self))
    }
    return nil
  }

  private static func debugEscapedPreview(_ text: String, limit: Int = 24) -> String {
    var result = ""
    var count = 0
    for scalar in text.unicodeScalars {
      if count >= limit {
        result += "..."
        break
      }
      switch scalar.value {
      case 0x5C:
        result += "\\\\"
      case 0x22:
        result += "\\\""
      case 0x0A:
        result += "\\n"
      case 0x0D:
        result += "\\r"
      case 0x09:
        result += "\\t"
      case 0x00..<0x20, 0x7F:
        result += String(format: "U+%04X", scalar.value)
      default:
        result.unicodeScalars.append(scalar)
      }
      count += 1
    }
    return result
  }

  private func buildGPUCellInstanceLists(
    payload: TerminalCellPayload,
    commands: [FrameCommand],
    surfacePxH: Int,
    damage: RenderDamage
  ) -> Bool {
    lastGPUCellPayloadBuildFailure = nil
    guard payload.isGPUCellCompatible else { return false }
    var attempts = 0
    let damageBounds = Self.useClassicDamageScoped ? Self.damageYBounds(damage) : nil
    while true {
      glyphAtlas.clearOverflowFlag()
      if sidebarGlyphAtlas !== glyphAtlas {
        sidebarGlyphAtlas.clearOverflowFlag()
      }
      guard
        buildGPUCellPayloadInstanceListsOnce(
          payload: payload,
          commands: commands,
          surfacePxH: surfacePxH,
          damage: damage,
          damageBounds: damageBounds)
      else {
        return false
      }

      let terminalOverflow = glyphAtlas.didOverflow
      let sidebarOverflow = sidebarGlyphAtlas.didOverflow
      guard terminalOverflow || sidebarOverflow else { return true }

      attempts += 1
      guard attempts < 4 else { return false }

      var grew = false
      if terminalOverflow {
        grew = growGlyphAtlas(forSidebar: false) || grew
      }
      if sidebarOverflow && !(terminalOverflow && sidebarGlyphAtlas === glyphAtlas) {
        grew = growGlyphAtlas(forSidebar: true) || grew
      }
      guard grew else { return false }
      cellGlyphGridGeometry = nil
    }
  }

  private func buildGPUCellPayloadInstanceListsOnce(
    payload: TerminalCellPayload,
    commands: [FrameCommand],
    surfacePxH: Int,
    damage: RenderDamage,
    damageBounds: DamageYBounds?
  ) -> Bool {
    solidInstances.removeAll(keepingCapacity: true)
    replaceSolidInstances.removeAll(keepingCapacity: true)
    glyphInstances.removeAll(keepingCapacity: true)
    colorGlyphInstances.removeAll(keepingCapacity: true)
    sidebarGlyphInstances.removeAll(keepingCapacity: true)
    cellGlyphUploadRanges.removeAll(keepingCapacity: true)
    cursorInstances.removeAll(keepingCapacity: true)

    guard let geometry = terminalGridGeometry(payload: payload) else {
      cellGlyphs.removeAll(keepingCapacity: true)
      cellGlyphGridGeometry = nil
      return false
    }

    let payloadRowsAreValid = payload.dirtyRows.allSatisfy { $0 >= 0 && $0 < payload.rows }
    let payloadFillsAllIncludedRows =
      payloadRowsAreValid && payload.glyphs.count == payload.dirtyRows.count * geometry.cols
    let payloadFillsEntireGrid =
      payloadFillsAllIncludedRows && payload.dirtyRows.count == geometry.rows
    let geometryChanged =
      geometry != cellGlyphGridGeometry || geometry.cellCount != cellGlyphs.count
    let fullCellRebuild = damage == .full || geometryChanged
    if fullCellRebuild, damage != .full { return false }
    if fullCellRebuild {
      if geometryChanged {
        cellGlyphs = Array(repeating: Self.emptyCellGlyph, count: geometry.cellCount)
      } else if !payloadFillsEntireGrid {
        for index in cellGlyphs.indices {
          cellGlyphs[index] = Self.emptyCellGlyph
        }
      }
      cellGlyphGridGeometry = geometry
      if !cellGlyphs.isEmpty {
        appendCellGlyphUploadRange(0..<cellGlyphs.count)
      }
    }

    let dirtyRowsFillAllCells =
      !fullCellRebuild
      && payloadFillsAllIncludedRows

    if !fullCellRebuild, case .partial = damage {
      for topDownRow in payload.dirtyRows {
        let row = geometry.rows - 1 - topDownRow
        guard row >= 0, row < geometry.rows else { continue }
        let start = row * geometry.cols
        let end = min(start + geometry.cols, cellGlyphs.count)
        guard start < end else { continue }
        if !dirtyRowsFillAllCells {
          for index in start..<end {
            cellGlyphs[index] = Self.emptyCellGlyph
          }
        }
        appendCellGlyphUploadRange(start..<end)
      }
    }

    let surfaceH = Float(surfacePxH)
    let scale = Float(layer.contentsScale)

    @inline(__always)
    func appendSolid(
      rect: CGRect,
      color: UInt32,
      compositing: FrameCompositingMode = .sourceOver
    ) {
      guard rect.width > 0, rect.height > 0 else { return }
      if let damageBounds, !damageBounds.overlaps(y: rect.origin.y, height: rect.height) {
        return
      }
      let instance = SolidInstance(
        origin: SIMD2<Float>(Float(rect.origin.x) * scale, Float(rect.origin.y) * scale),
        size: SIMD2<Float>(Float(rect.width) * scale, Float(rect.height) * scale),
        color: rgbaToFloat4(color))
      if compositing == .replace {
        replaceSolidInstances.append(instance)
      } else {
        solidInstances.append(instance)
      }
      _ = surfaceH
    }

    @inline(__always)
    func appendSidebarGlyph(
      cellX: CGFloat,
      cellY: CGFloat,
      entry: MetalGlyphAtlas.Entry,
      atlas: MetalGlyphAtlas,
      color: UInt32
    ) {
      let atlasW = Float(atlas.textureSize)
      let atlasH = Float(atlas.textureSize)
      sidebarGlyphInstances.append(
        GlyphInstance(
          origin: SIMD2<Float>(
            Float(cellX + entry.logicalOriginX) * scale,
            Float(cellY) * scale),
          size: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
          uvOrigin: SIMD2<Float>(Float(entry.originX) / atlasW, Float(entry.originY) / atlasH),
          uvSize: SIMD2<Float>(Float(entry.pixelWidth) / atlasW, Float(entry.pixelHeight) / atlasH),
          color: rgbaToFloat4(color)))
    }

    for cmd in commands {
      // The `.preedit` mask is intentionally skipped here and re-emitted by the
      // preedit pass below — AFTER the payload's own cell backgrounds — so it
      // covers an app-rendered caret under the composition instead of being
      // painted over by those backgrounds.
      guard case .rect(let rect, let color, let source, let compositing) = cmd,
        source != .preedit
      else { continue }
      // On a partial payload frame the per-dirty-row background below repaints
      // exactly the dirty rows; the full-viewport terminal-area background rect
      // (source .terminal, appended by TerminalSurfaceController and not removed
      // by canSkipTerminalCommands) would otherwise be drawn across the whole
      // damage-union scissor and wipe clean interior rows' non-default
      // backgrounds / procedural fills to the default colour. Skip it on partial
      // frames — clean rows are preserved by the persistent target's load action.
      if case .partial = damage, source == .terminal { continue }
      appendSolid(rect: rect, color: color, compositing: compositing)
    }

    switch damage {
    case .full:
      appendSolid(
        rect: payload.terminalRect,
        color: payload.defaultBackground,
        compositing: .replace)
    case .partial:
      resetPayloadRowsWithFullBackgroundRun(count: payload.rows)
      for run in payload.backgroundRuns
      where run.row >= 0 && run.row < payload.rows && run.startCol <= 0
        && run.colCount >= payload.cols
      {
        payloadRowsWithFullBackgroundRun[run.row] = true
      }
      for row in payload.dirtyRows where row >= 0 && row < payload.rows {
        guard !payloadRowsWithFullBackgroundRun[row] else { continue }
        appendSolid(
          rect: CGRect(
            x: payload.origin.x,
            y: payload.origin.y + CGFloat(payload.rows - 1 - row) * payload.cellSize.height
              + payload.contentYOffset,
            width: CGFloat(payload.cols) * payload.cellSize.width,
            height: payload.cellSize.height),
          color: payload.defaultBackground,
          compositing: .replace)
      }
    }
    for run in payload.backgroundRuns {
      let rect = CGRect(
        x: payload.origin.x + CGFloat(run.startCol) * payload.cellSize.width,
        y: payload.origin.y + CGFloat(payload.rows - 1 - run.row) * payload.cellSize.height
          + payload.contentYOffset,
        width: CGFloat(run.colCount) * payload.cellSize.width,
        height: payload.cellSize.height)
      appendSolid(rect: rect, color: run.color, compositing: .replace)
    }

    for procedural in payload.proceduralCells {
      guard procedural.row >= 0, procedural.row < payload.rows,
        procedural.col >= 0, procedural.col < payload.cols,
        let scalar = Unicode.Scalar(procedural.scalarValue)
      else {
        return false
      }
      let cellOrigin = CGPoint(
        x: payload.origin.x + CGFloat(procedural.col) * payload.cellSize.width,
        y: payload.origin.y + CGFloat(payload.rows - 1 - procedural.row) * payload.cellSize.height
          + payload.contentYOffset)
      for filled in BoxDrawing.proceduralCellElementRects(
        scalar,
        at: cellOrigin,
        cellWidth: payload.cellSize.width,
        cellHeight: payload.cellSize.height,
        foreground: procedural.foreground)
      {
        appendSolid(rect: filled.rect, color: filled.color)
      }
    }

    for cmd in commands {
      switch cmd {
      case .selection(let rect, let color),
        .findMatch(let rect, let color),
        .findSelected(let rect, let color):
        appendSolid(rect: rect, color: color)
      case .cursor(let rect, let color):
        guard rect.width > 0, rect.height > 0 else { break }
        cursorInstances.append(
          SolidInstance(
            origin: SIMD2<Float>(Float(rect.origin.x) * scale, Float(rect.origin.y) * scale),
            size: SIMD2<Float>(Float(rect.width) * scale, Float(rect.height) * scale),
            color: rgbaToFloat4(color)))
      case .glyphRun(
        let origin, let text, let fg, _, let attrs, let runSource,
        let underlineStyle, let underlineColor, _, _, _, _, _) where runSource == .sidebar:
        let runHeight = sidebarCellHeight
        if let damageBounds, !damageBounds.overlaps(y: origin.y, height: runHeight) {
          continue
        }
        let font = styledFont(for: attrs, in: sidebarFontAtlas)
        let traits = CTFontGetSymbolicTraits(font)
        let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
        let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)
        for (cellIndex, cluster) in text.enumerated() {
          guard
            let entry = sidebarGlyphAtlas.entry(
              character: cluster,
              font: font,
              boldFallback: needsBoldFallback,
              italicFallback: needsItalicFallback)
          else { continue }
          appendSidebarGlyph(
            cellX: origin.x + CGFloat(cellIndex) * sidebarCellAdvance,
            cellY: origin.y,
            entry: entry,
            atlas: sidebarGlyphAtlas,
            color: fg)
        }
        emitDecorations(
          for: text, at: origin, attributes: attrs,
          cellAdvance: sidebarCellAdvance,
          cellHeight: sidebarCellHeight,
          descent: sidebarFontAtlas.descent,
          fg: fg,
          underlineStyle: underlineStyle, underlineColor: underlineColor,
          appendSolid: { rect, color in appendSolid(rect: rect, color: color) })
      default:
        break
      }
    }

    var cachedPayloadAttributes: TextAttributes?
    var cachedPayloadFont: CTFont?
    var cachedPayloadNeedsBoldFallback = false
    var cachedPayloadNeedsItalicFallback = false

    var runRow: Int?
    var runStartCol = 0
    var runCellCount = 0
    var runFg: UInt32 = 0
    var runBg: UInt32 = 0
    var runAttributes: TextAttributes = []
    var runUnderlineStyle: UnderlineStyle = .none
    var runUnderlineColor: UInt32?
    var runHasHyperlink = false

    @inline(__always)
    func flushPayloadDecorationRun() {
      guard let row = runRow, runCellCount > 0 else {
        runRow = nil
        runCellCount = 0
        return
      }
      emitDecorations(
        cellCount: runCellCount,
        at: CGPoint(
          x: payload.origin.x + CGFloat(runStartCol) * payload.cellSize.width,
          y: payload.origin.y + CGFloat(payload.rows - 1 - row) * payload.cellSize.height
            + payload.contentYOffset),
        attributes: runAttributes,
        cellAdvance: payload.cellSize.width,
        cellHeight: payload.cellSize.height,
        descent: fontAtlas.descent,
        fg: runFg,
        underlineStyle: runUnderlineStyle,
        underlineColor: runUnderlineColor,
        phaseOriginX: payload.origin.x,
        appendSolid: { rect, color in appendSolid(rect: rect, color: color) })
      runRow = nil
      runCellCount = 0
    }

    @inline(__always)
    func appendPayloadDecorationCell(_ glyph: TerminalCellPayload.Glyph) {
      let sameStyle =
        runRow == glyph.row
        && glyph.col == runStartCol + runCellCount
        && runFg == glyph.foreground
        && runBg == glyph.background
        && runAttributes == glyph.attributes
        && runUnderlineStyle == glyph.underlineStyle
        && runUnderlineColor == glyph.underlineColor
        && runHasHyperlink == glyph.hasHyperlink
      if runRow != nil, sameStyle {
        runCellCount += 1
        return
      }

      flushPayloadDecorationRun()
      runRow = glyph.row
      runStartCol = glyph.col
      runCellCount = 1
      runFg = glyph.foreground
      runBg = glyph.background
      runAttributes = glyph.attributes
      runUnderlineStyle = glyph.underlineStyle
      runUnderlineColor = glyph.underlineColor
      runHasHyperlink = glyph.hasHyperlink
    }

    @inline(__always)
    func terminalFontInfo(
      for attributes: TextAttributes
    ) -> (font: CTFont, needsBoldFallback: Bool, needsItalicFallback: Bool) {
      if cachedPayloadAttributes == attributes, let cachedPayloadFont {
        return (
          cachedPayloadFont,
          cachedPayloadNeedsBoldFallback,
          cachedPayloadNeedsItalicFallback
        )
      }
      let font = styledFont(for: attributes, in: fontAtlas)
      let traits = CTFontGetSymbolicTraits(font)
      let needsBoldFallback = attributes.contains(.bold) && !traits.contains(.traitBold)
      let needsItalicFallback = attributes.contains(.italic) && !traits.contains(.traitItalic)
      cachedPayloadAttributes = attributes
      cachedPayloadFont = font
      cachedPayloadNeedsBoldFallback = needsBoldFallback
      cachedPayloadNeedsItalicFallback = needsItalicFallback
      return (font, needsBoldFallback, needsItalicFallback)
    }

    let defaultTerminalFontInfo = terminalFontInfo(for: [])

    @inline(__always)
    func recordPayloadFailure(
      _ reason: String,
      glyph: TerminalCellPayload.Glyph,
      textPreview: String? = nil,
      logicalWidth: CGFloat? = nil,
      maxLogicalWidth: CGFloat? = nil
    ) {
      let range = glyph.utf8Range
      lastGPUCellPayloadBuildFailure = GPUCellPayloadBuildFailure(
        reason: reason,
        row: glyph.row,
        col: glyph.col,
        scalarValue: glyph.scalarValue,
        textPreview: textPreview
          ?? Self.gpuCellPayloadFailurePreview(glyph: glyph, payload: payload),
        utf8RangeLowerBound: range?.lowerBound,
        utf8RangeUpperBound: range?.upperBound,
        utf8ByteCount: payload.utf8Bytes.count,
        wide: glyph.wide,
        attributesRawValue: glyph.attributes.rawValue,
        logicalWidth: logicalWidth.map(Double.init),
        maxLogicalWidth: maxLogicalWidth.map(Double.init))
    }

    let invAtlasSize = 1.0 / Float(glyphAtlas.textureSize)
    let payloadOriginX = payload.origin.x
    let payloadOriginY = payload.origin.y
    let payloadCellWidth = payload.cellSize.width
    let payloadCellHeight = payload.cellSize.height
    let payloadContentYOffset = payload.contentYOffset
    let payloadRows = payload.rows
    let payloadCols = payload.cols
    let maxLogicalWidth = payloadCellWidth * Self.maxNarrowGlyphLogicalWidthCells
    var cachedPayloadForeground: UInt32?
    var cachedPayloadForegroundFloat = SIMD4<Float>.zero
    scalarEntryCacheGeneration &+= 1
    var payloadGlyphLoopFailed = false
    var payloadGlyphAtlasOverflow = false
    payload.glyphs.withUnsafeBufferPointer { glyphsBuffer in
      guard let glyphsBase = glyphsBuffer.baseAddress else { return }
      cellGlyphs.withUnsafeMutableBufferPointer { cells in
        var lastBottomRow = Int.min
        var cellYPx: Float = 0
        for glyphIndex in 0..<glyphsBuffer.count {
          // Field loads through the pointer avoid copying the ~100-byte Glyph
          // (and retain/releasing its String) for every cell of the grid.
          let glyph = glyphsBase + glyphIndex
          let row = glyph.pointee.row
          guard row >= 0, row < payloadRows else {
            recordPayloadFailure("rowOutOfBounds", glyph: glyph.pointee)
            payloadGlyphLoopFailed = true
            return
          }
          let col = glyph.pointee.col
          guard col >= 0, col < payloadCols else {
            recordPayloadFailure("colOutOfBounds", glyph: glyph.pointee)
            payloadGlyphLoopFailed = true
            return
          }
          let wide = glyph.pointee.wide
          guard wide == 0 || wide == 1 else {
            recordPayloadFailure("unsupportedWideFlag", glyph: glyph.pointee)
            payloadGlyphLoopFailed = true
            return
          }
          let attributes = glyph.pointee.attributes
          guard (attributes.rawValue & ~Self.gpuCellSupportedAttributes.rawValue) == 0 else {
            recordPayloadFailure("unsupportedAttributes", glyph: glyph.pointee)
            payloadGlyphLoopFailed = true
            return
          }
          let scalarValue = glyph.pointee.scalarValue
          guard scalarValue != nil || glyph.pointee.utf8Range != nil else {
            recordPayloadFailure("missingGlyphText", glyph: glyph.pointee)
            payloadGlyphLoopFailed = true
            return
          }
          let bottomRow = payloadRows - 1 - row
          if bottomRow != lastBottomRow {
            lastBottomRow = bottomRow
            cellYPx =
              Float(
                payloadOriginY + CGFloat(bottomRow) * payloadCellHeight + payloadContentYOffset)
              * scale
          }
          let cellX = payloadOriginX + CGFloat(col) * payloadCellWidth
          // `terminalGridGeometry(payload:)` mirrors payload rows/cols, so the row/col
          // guards above prove this index is in the retained full-grid buffer.
          let index = bottomRow * geometry.cols + col
          let fontAttrsKey = attributes.rawValue & Self.gpuCellFontAttributes.rawValue
          let entry: MetalGlyphAtlas.Entry?
          if let scalarValue {
            if fontAttrsKey == 0, scalarValue < UInt32(Self.defaultASCIIEntryCacheSize) {
              entry = cachedDefaultASCIIEntry(
                scalarValue: scalarValue,
                fontInfo: defaultTerminalFontInfo)
            } else if let scalar = Unicode.Scalar(scalarValue) {
              entry = cachedScalarEntry(
                scalarValue: scalarValue,
                scalar: scalar,
                attrsKey: UInt64(fontAttrsKey),
                fontInfo: fontAttrsKey == 0
                  ? defaultTerminalFontInfo : terminalFontInfo(for: attributes))
            } else {
              recordPayloadFailure("invalidScalar", glyph: glyph.pointee)
              payloadGlyphLoopFailed = true
              return
            }
          } else if let range = glyph.pointee.utf8Range {
            guard range.lowerBound >= 0, range.upperBound <= payload.utf8Bytes.count else {
              recordPayloadFailure("utf8RangeOutOfBounds", glyph: glyph.pointee)
              payloadGlyphLoopFailed = true
              return
            }
            let text = String(decoding: payload.utf8Bytes[range], as: UTF8.self)
            guard text.count == 1, let character = text.first else {
              recordPayloadFailure(
                "utf8ClusterNotSingleCharacter",
                glyph: glyph.pointee,
                textPreview: Self.debugEscapedPreview(text))
              payloadGlyphLoopFailed = true
              return
            }
            let fontInfo =
              fontAttrsKey == 0 ? defaultTerminalFontInfo : terminalFontInfo(for: attributes)
            entry = glyphAtlas.entry(
              character: character,
              font: fontInfo.font,
              boldFallback: fontInfo.needsBoldFallback,
              italicFallback: fontInfo.needsItalicFallback)
          } else {
            entry = nil
          }
          // Match the command-driven GPU-cell builder: some single-cell terminal UI
          // symbols (for example U+23BF/U+21B3 in fallback fonts) have two-cell ink
          // metrics even when libghostty marks the cell as narrow.
          guard let entry else {
            if glyphAtlas.didOverflow {
              payloadGlyphAtlasOverflow = true
              return
            }
            cells[index] = Self.emptyCellGlyph
            continue
          }
          guard entry.admissionWidth <= maxLogicalWidth else {
            recordPayloadFailure(
              "logicalWidthTooWide",
              glyph: glyph.pointee,
              logicalWidth: entry.admissionWidth,
              maxLogicalWidth: maxLogicalWidth)
            payloadGlyphLoopFailed = true
            return
          }
          let foreground = glyph.pointee.foreground
          let foregroundFloat: SIMD4<Float>
          if cachedPayloadForeground == foreground {
            foregroundFloat = cachedPayloadForegroundFloat
          } else {
            foregroundFloat = rgbaToFloat4(foreground)
            cachedPayloadForeground = foreground
            cachedPayloadForegroundFloat = foregroundFloat
          }
          cells[index] = CellGlyph(
            originPx: SIMD2<Float>(
              Float(cellX + entry.logicalOriginX) * scale,
              cellYPx),
            sizePx: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
            uvOrigin: SIMD2<Float>(
              Float(entry.originX) * invAtlasSize, Float(entry.originY) * invAtlasSize),
            uvSize: SIMD2<Float>(
              Float(entry.pixelWidth) * invAtlasSize, Float(entry.pixelHeight) * invAtlasSize),
            flags: Self.gpuCellActiveFlag,
            fg: foregroundFloat)
          if glyph.pointee.underlineStyle != .none
            || (attributes.rawValue & Self.gpuCellDecorationAttributes.rawValue) != 0
          {
            appendPayloadDecorationCell(glyph.pointee)
          }
        }
      }
    }
    if payloadGlyphAtlasOverflow { return true }
    if payloadGlyphLoopFailed { return false }
    flushPayloadDecorationRun()

    // IME/dictation preedit. Drawn AFTER the payload has filled the cell grid
    // so the composition glyphs overwrite the cells under the caret rather than
    // being clobbered by them. Replay every producer mask here, including a
    // mask-only spacer left when a wide grapheme wraps from the final column;
    // the earlier rect prepass intentionally skips `.preedit` rectangles.
    for case .rect(let rect, let color, .preedit, _) in commands {
      let bottomRow = Int(
        ((rect.origin.y - payload.origin.y - payload.contentYOffset) / payload.cellSize.height)
          .rounded())
      let startCol = Int(
        floor((rect.minX - payload.origin.x) / payload.cellSize.width))
      let endCol = Int(
        ceil((rect.maxX - payload.origin.x) / payload.cellSize.width))
      if bottomRow >= 0, bottomRow < geometry.rows {
        let lower = max(startCol, 0)
        let upper = min(endCol, geometry.cols)
        if lower < upper {
          let startIndex = bottomRow * geometry.cols + lower
          let endIndex = bottomRow * geometry.cols + upper
          for index in startIndex..<endIndex where index < cellGlyphs.count {
            cellGlyphs[index] = Self.emptyCellGlyph
          }
          appendCellGlyphUploadRange(startIndex..<min(endIndex, cellGlyphs.count))
        }
      }
      appendSolid(rect: rect, color: color)
    }

    // Set the terminal-atlas glyphs + underline. Index math mirrors the
    // payload fill (row/col from the run origin minus
    // `contentYOffset`) so it stays correct mid-smooth-scroll, where
    // `geometry.index`'s integer-alignment check would reject the shifted Y.
    // The `.preedit` source is only produced at the cursor, so ordinary cells
    // are never touched.
    for cmd in commands {
      guard
        case .glyphRun(
          let origin, let text, let fg, _, let attrs, let runSource,
          let underlineStyle, let underlineColor, _, let displayCellCount, _, _, _) = cmd,
        runSource == .preedit, !text.isEmpty
      else { continue }
      let font = styledFont(for: attrs, in: fontAtlas)
      let traits = CTFontGetSymbolicTraits(font)
      let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
      let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)
      let preeditCellCount =
        displayCellCount
        ?? text.reduce(into: 0) { total, cluster in
          if let entry = glyphAtlas.entry(
            character: cluster, font: font,
            boldFallback: needsBoldFallback,
            italicFallback: needsItalicFallback
          ),
            entry.admissionWidth
              <= payload.cellSize.width * Self.maxNarrowGlyphLogicalWidthCells
          {
            total += max(
              1,
              Int(
                ceil(
                  entry.logicalWidth / payload.cellSize.width)))
          } else {
            total += 1
          }
        }
      let atlasW = Float(glyphAtlas.textureSize)
      let atlasH = Float(glyphAtlas.textureSize)
      let bottomRow = Int(
        ((origin.y - payload.origin.y - payload.contentYOffset) / payload.cellSize.height)
          .rounded())
      let baseCol = Int(((origin.x - payload.origin.x) / payload.cellSize.width).rounded())
      var cellIndex = 0
      for cluster in text {
        let col = baseCol + cellIndex
        let isCellInBounds =
          bottomRow >= 0 && bottomRow < geometry.rows
          && col >= 0 && col < geometry.cols
        let index = isCellInBounds ? (bottomRow * geometry.cols + col) : -1
        if let entry = glyphAtlas.entry(
          character: cluster, font: font,
          boldFallback: needsBoldFallback,
          italicFallback: needsItalicFallback
        ), entry.admissionWidth <= payload.cellSize.width * Self.maxNarrowGlyphLogicalWidthCells {
          if isCellInBounds, index >= 0, index < cellGlyphs.count {
            let cellX = origin.x + CGFloat(cellIndex) * glyphCellAdvance
            cellGlyphs[index] = CellGlyph(
              originPx: SIMD2<Float>(
                Float(cellX + entry.logicalOriginX) * scale,
                Float(origin.y) * scale),
              sizePx: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
              uvOrigin: SIMD2<Float>(
                Float(entry.originX) / atlasW, Float(entry.originY) / atlasH),
              uvSize: SIMD2<Float>(
                Float(entry.pixelWidth) / atlasW, Float(entry.pixelHeight) / atlasH),
              flags: Self.gpuCellActiveFlag,
              fg: rgbaToFloat4(fg))
            appendCellGlyphUploadRange(index..<(index + 1))
          }
          cellIndex += max(
            1,
            Int(
              ceil(
                entry.logicalWidth / payload.cellSize.width)))
        } else {
          cellIndex += 1
        }
      }
      emitDecorations(
        cellCount: preeditCellCount, at: origin, attributes: attrs,
        cellAdvance: glyphCellAdvance,
        cellHeight: glyphCellHeight,
        descent: fontAtlas.descent,
        fg: fg,
        underlineStyle: underlineStyle, underlineColor: underlineColor,
        appendSolid: { rect, color in appendSolid(rect: rect, color: color) })
    }

    for cursor in payload.cursorRects {
      let rect = cursor.rect
      guard rect.width > 0, rect.height > 0 else { continue }
      cursorInstances.append(
        SolidInstance(
          origin: SIMD2<Float>(Float(rect.origin.x) * scale, Float(rect.origin.y) * scale),
          size: SIMD2<Float>(Float(rect.width) * scale, Float(rect.height) * scale),
          color: rgbaToFloat4(cursor.color)))
    }

    lastInstanceCounts = RenderInstanceCounts(
      solids: solidInstances.count + replaceSolidInstances.count,
      glyphs: glyphInstances.count + colorGlyphInstances.count,
      sidebarGlyphs: sidebarGlyphInstances.count,
      cellGlyphs: cellGlyphs.count,
      cursors: cursorInstances.count)
    return true
  }

  private func appendCellGlyphUploadRange(_ range: Range<Int>) {
    guard !range.isEmpty else { return }
    if let last = cellGlyphUploadRanges.last,
      last.lowerBound <= range.upperBound && range.lowerBound <= last.upperBound
    {
      cellGlyphUploadRanges[cellGlyphUploadRanges.count - 1] =
        min(last.lowerBound, range.lowerBound)..<max(last.upperBound, range.upperBound)
      return
    }
    cellGlyphUploadRanges.append(range)
  }

  // Direct-mapped, per-build memo in front of `glyphAtlas.entry`. The key fully
  // determines the atlas entry: the glyph scalar plus the cell attributes (the
  // font, bold-fallback, and italic-fallback the atlas keys on are all derived
  // from the attributes via `terminalFontInfo`). A hit skips the atlas
  // dictionary's hashing entirely.
  @inline(__always)
  private func cachedDefaultASCIIEntry(
    scalarValue: UInt32,
    fontInfo: (font: CTFont, needsBoldFallback: Bool, needsItalicFallback: Bool)
  ) -> MetalGlyphAtlas.Entry? {
    let index = Int(scalarValue)
    if defaultASCIIEntryCacheStamp[index] == scalarEntryCacheGeneration {
      return defaultASCIIEntryCacheEntries[index]
    }
    guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
    let entry = glyphAtlas.entry(
      scalar: scalar,
      font: fontInfo.font,
      boldFallback: fontInfo.needsBoldFallback,
      italicFallback: fontInfo.needsItalicFallback)
    defaultASCIIEntryCacheEntries[index] = entry
    defaultASCIIEntryCacheStamp[index] = scalarEntryCacheGeneration
    return entry
  }

  @inline(__always)
  private func cachedScalarEntry(
    scalarValue: UInt32,
    scalar: Unicode.Scalar,
    attrsKey: UInt64,
    fontInfo: (font: CTFont, needsBoldFallback: Bool, needsItalicFallback: Bool)
  ) -> MetalGlyphAtlas.Entry? {
    let key = (UInt64(scalarValue) << 32) | (attrsKey & 0xFFFF_FFFF)
    let slot = Int((key &* 0x9E37_79B9_7F4A_7C15) >> 54) & (Self.scalarEntryCacheSize - 1)
    if scalarEntryCacheStamp[slot] == scalarEntryCacheGeneration,
      scalarEntryCacheKeys[slot] == key
    {
      return scalarEntryCacheEntries[slot]
    }
    let entry = glyphAtlas.entry(
      scalar: scalar,
      font: fontInfo.font,
      boldFallback: fontInfo.needsBoldFallback,
      italicFallback: fontInfo.needsItalicFallback)
    scalarEntryCacheKeys[slot] = key
    scalarEntryCacheEntries[slot] = entry
    scalarEntryCacheStamp[slot] = scalarEntryCacheGeneration
    return entry
  }

  private func buildGPUCellInstanceLists(
    commands: [FrameCommand],
    surfacePxH: Int,
    damage: RenderDamage
  ) -> Bool {
    var attempts = 0
    let damageBounds = Self.useClassicDamageScoped ? Self.damageYBounds(damage) : nil
    while true {
      glyphAtlas.clearOverflowFlag()
      if sidebarGlyphAtlas !== glyphAtlas {
        sidebarGlyphAtlas.clearOverflowFlag()
      }
      guard
        buildGPUCellInstanceListsOnce(
          commands: commands,
          surfacePxH: surfacePxH,
          damageBounds: damageBounds)
      else {
        return false
      }

      let terminalOverflow = glyphAtlas.didOverflow
      let sidebarOverflow = sidebarGlyphAtlas.didOverflow
      guard terminalOverflow || sidebarOverflow else { return true }

      attempts += 1
      guard attempts < 4 else { return false }

      var grew = false
      if terminalOverflow {
        grew = growGlyphAtlas(forSidebar: false) || grew
      }
      if sidebarOverflow && !(terminalOverflow && sidebarGlyphAtlas === glyphAtlas) {
        grew = growGlyphAtlas(forSidebar: true) || grew
      }
      guard grew else { return false }
      cellGlyphGridGeometry = nil
    }
  }

  private func buildGPUCellInstanceListsOnce(
    commands: [FrameCommand],
    surfacePxH: Int,
    damageBounds: DamageYBounds?
  ) -> Bool {
    solidInstances.removeAll(keepingCapacity: true)
    replaceSolidInstances.removeAll(keepingCapacity: true)
    glyphInstances.removeAll(keepingCapacity: true)
    colorGlyphInstances.removeAll(keepingCapacity: true)
    sidebarGlyphInstances.removeAll(keepingCapacity: true)
    cellGlyphUploadRanges.removeAll(keepingCapacity: true)
    cursorInstances.removeAll(keepingCapacity: true)

    gpuCellCommandRequiresFullRedraw = false
    let geometry = terminalGridGeometry(commands: commands)
    let fullCellRebuild =
      damageBounds == nil || geometry != cellGlyphGridGeometry
      || geometry?.cellCount != cellGlyphs.count
    // Mirror the cell-payload path (buildGPUCellPayloadInstanceListsOnce): a
    // partial update (damageBounds != nil) cannot be honoured when the retained
    // cell cache must be fully rebuilt because the terminal grid geometry
    // changed (or the cache is cold). Partial-rendering would scissor to the
    // dirty band and leave stale pre-change pixels in the clean rows, so signal
    // a full-target redraw instead of partial-rendering or classic fallback.
    if let geometry, damageBounds != nil,
      geometry != cellGlyphGridGeometry || geometry.cellCount != cellGlyphs.count
    {
      gpuCellCommandRequiresFullRedraw = true
      return false
    }
    if let geometry, fullCellRebuild {
      cellGlyphs = Array(repeating: Self.emptyCellGlyph, count: geometry.cellCount)
      cellGlyphGridGeometry = geometry
      if !cellGlyphs.isEmpty {
        appendCellGlyphUploadRange(0..<cellGlyphs.count)
      }
    } else if geometry == nil {
      cellGlyphs.removeAll(keepingCapacity: true)
      cellGlyphGridGeometry = nil
    }

    let patchRows = fullCellRebuild ? [] : rowsToPatch(for: damageBounds, geometry: geometry)
    if let geometry, !fullCellRebuild {
      for row in patchRows.indices where patchRows[row] {
        let start = row * geometry.cols
        let end = min(start + geometry.cols, cellGlyphs.count)
        guard start < end else { continue }
        for index in start..<end {
          cellGlyphs[index] = Self.emptyCellGlyph
        }
        appendCellGlyphUploadRange(start..<end)
      }
    }

    let surfaceH = Float(surfacePxH)
    let scale = Float(layer.contentsScale)
    let preeditMaskRects = commands.compactMap { command -> CGRect? in
      if case .rect(let rect, _, .preedit, _) = command { return rect }
      return nil
    }

    @inline(__always)
    func appendSolid(
      rect: CGRect,
      color: UInt32,
      compositing: FrameCompositingMode = .sourceOver
    ) {
      guard rect.width > 0, rect.height > 0 else { return }
      if let damageBounds, !damageBounds.overlaps(y: rect.origin.y, height: rect.height) {
        return
      }
      let originPx = SIMD2<Float>(
        Float(rect.origin.x) * scale, Float(rect.origin.y) * scale)
      let sizePx = SIMD2<Float>(
        Float(rect.width) * scale, Float(rect.height) * scale)
      let instance = SolidInstance(
        origin: originPx, size: sizePx, color: rgbaToFloat4(color))
      if compositing == .replace {
        replaceSolidInstances.append(instance)
      } else {
        solidInstances.append(instance)
      }
      _ = surfaceH
    }

    @inline(__always)
    func appendSidebarGlyph(
      cellX: CGFloat, cellY: CGFloat,
      entry: MetalGlyphAtlas.Entry,
      atlas: MetalGlyphAtlas,
      color: UInt32
    ) {
      let atlasW = Float(atlas.textureSize)
      let atlasH = Float(atlas.textureSize)
      sidebarGlyphInstances.append(
        GlyphInstance(
          origin: SIMD2<Float>(
            Float(cellX + entry.logicalOriginX) * scale,
            Float(cellY) * scale),
          size: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
          uvOrigin: SIMD2<Float>(Float(entry.originX) / atlasW, Float(entry.originY) / atlasH),
          uvSize: SIMD2<Float>(Float(entry.pixelWidth) / atlasW, Float(entry.pixelHeight) / atlasH),
          color: rgbaToFloat4(color)))
    }

    @inline(__always)
    func writeTerminalCellGlyph(
      index: Int,
      cellX: CGFloat,
      cellY: CGFloat,
      entry: MetalGlyphAtlas.Entry,
      color: UInt32
    ) -> Bool {
      guard index >= 0, index < cellGlyphs.count else { return false }
      guard entry.admissionWidth <= glyphCellAdvance * Self.maxNarrowGlyphLogicalWidthCells else {
        return false
      }
      if !patchRows.isEmpty {
        let row = index / max(1, cellGlyphGridGeometry?.cols ?? 1)
        guard row >= 0, row < patchRows.count, patchRows[row] else { return true }
      }
      let atlasW = Float(glyphAtlas.textureSize)
      let atlasH = Float(glyphAtlas.textureSize)
      cellGlyphs[index] = CellGlyph(
        originPx: SIMD2<Float>(
          Float(cellX + entry.logicalOriginX) * scale,
          Float(cellY) * scale),
        sizePx: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
        uvOrigin: SIMD2<Float>(Float(entry.originX) / atlasW, Float(entry.originY) / atlasH),
        uvSize: SIMD2<Float>(Float(entry.pixelWidth) / atlasW, Float(entry.pixelHeight) / atlasH),
        flags: Self.gpuCellActiveFlag,
        fg: rgbaToFloat4(color))
      return true
    }

    for cmd in commands {
      switch cmd {
      case .rect(let rect, let color, _, let compositing):
        appendSolid(rect: rect, color: color, compositing: compositing)

      case .cursor(let rect, let color):
        guard rect.width > 0, rect.height > 0 else { break }
        cursorInstances.append(
          SolidInstance(
            origin: SIMD2<Float>(
              Float(rect.origin.x) * scale, Float(rect.origin.y) * scale),
            size: SIMD2<Float>(
              Float(rect.width) * scale, Float(rect.height) * scale),
            color: rgbaToFloat4(color)))

      case .selection(let rect, let color):
        appendSolid(rect: rect, color: color)

      case .findMatch(let rect, let color),
        .findSelected(let rect, let color):
        appendSolid(rect: rect, color: color)

      case .clip:
        break

      case .glyphRun(
        let origin, let text, let fg, _, let attrs, let runSource,
        let underlineStyle, let underlineColor, _, _, _, _, _):
        let isSidebar = runSource == .sidebar
        let runHeight = isSidebar ? sidebarCellHeight : glyphCellHeight
        if isSidebar, let damageBounds, !damageBounds.overlaps(y: origin.y, height: runHeight) {
          continue
        }

        if !isSidebar {
          guard attrs.subtracting(Self.gpuCellSupportedAttributes).isEmpty,
            let geometry
          else {
            return false
          }
          let font = styledFont(for: attrs, in: fontAtlas)
          let traits = CTFontGetSymbolicTraits(font)
          let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
          let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)

          for (cellIndex, cluster) in text.enumerated() {
            let cellX = origin.x + CGFloat(cellIndex) * glyphCellAdvance
            let cellRect = CGRect(
              x: cellX, y: origin.y,
              width: glyphCellAdvance, height: runHeight)
            if runSource != .preedit,
              preeditMaskRects.contains(where: { $0.intersects(cellRect) })
            {
              continue
            }
            if !patchRows.isEmpty,
              let index = geometry.index(cellX: cellX, cellY: origin.y, cellOffset: 0)
            {
              let row = index / max(1, geometry.cols)
              guard row >= 0, row < patchRows.count, patchRows[row] else { continue }
            }
            guard
              let entry = glyphAtlas.entry(
                character: cluster, font: font,
                boldFallback: needsBoldFallback,
                italicFallback: needsItalicFallback)
            else { continue }
            guard
              let index = geometry.index(cellX: cellX, cellY: origin.y, cellOffset: 0),
              writeTerminalCellGlyph(
                index: index, cellX: cellX, cellY: origin.y, entry: entry, color: fg)
            else {
              return false
            }
          }
          emitDecorations(
            for: text, at: origin, attributes: attrs,
            cellAdvance: glyphCellAdvance,
            cellHeight: glyphCellHeight,
            descent: fontAtlas.descent,
            fg: fg,
            underlineStyle: underlineStyle, underlineColor: underlineColor,
            phaseOriginX: geometry.originX,
            appendSolid: { rect, color in appendSolid(rect: rect, color: color) })
          continue
        }

        let font = styledFont(for: attrs, in: sidebarFontAtlas)
        let traits = CTFontGetSymbolicTraits(font)
        let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
        let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)

        for (cellIndex, cluster) in text.enumerated() {
          guard
            let entry = sidebarGlyphAtlas.entry(
              character: cluster, font: font,
              boldFallback: needsBoldFallback,
              italicFallback: needsItalicFallback)
          else { continue }
          appendSidebarGlyph(
            cellX: origin.x + CGFloat(cellIndex) * sidebarCellAdvance,
            cellY: origin.y,
            entry: entry,
            atlas: sidebarGlyphAtlas,
            color: fg)
        }

        emitDecorations(
          for: text, at: origin, attributes: attrs,
          cellAdvance: sidebarCellAdvance,
          cellHeight: sidebarCellHeight,
          descent: sidebarFontAtlas.descent,
          fg: fg,
          underlineStyle: underlineStyle, underlineColor: underlineColor,
          appendSolid: { rect, color in appendSolid(rect: rect, color: color) })

      case .texturedQuad, .waveRegion:
        break
      }
    }

    lastInstanceCounts = RenderInstanceCounts(
      solids: solidInstances.count + replaceSolidInstances.count,
      glyphs: glyphInstances.count + colorGlyphInstances.count,
      sidebarGlyphs: sidebarGlyphInstances.count,
      cellGlyphs: cellGlyphs.count,
      cursors: cursorInstances.count)
    return true
  }

  private func buildCursorInstanceList(commands: [FrameCommand]) {
    solidInstances.removeAll(keepingCapacity: true)
    replaceSolidInstances.removeAll(keepingCapacity: true)
    glyphInstances.removeAll(keepingCapacity: true)
    colorGlyphInstances.removeAll(keepingCapacity: true)
    sidebarGlyphInstances.removeAll(keepingCapacity: true)
    cursorInstances.removeAll(keepingCapacity: true)

    let scale = Float(layer.contentsScale)
    for cmd in commands {
      guard case .cursor(let rect, let color) = cmd else { continue }
      guard rect.width > 0, rect.height > 0 else { continue }
      cursorInstances.append(
        SolidInstance(
          origin: SIMD2<Float>(
            Float(rect.origin.x) * scale, Float(rect.origin.y) * scale),
          size: SIMD2<Float>(
            Float(rect.width) * scale, Float(rect.height) * scale),
          color: rgbaToFloat4(color)))
    }
    lastInstanceCounts = RenderInstanceCounts(
      solids: solidInstances.count + replaceSolidInstances.count,
      glyphs: glyphInstances.count + colorGlyphInstances.count,
      sidebarGlyphs: sidebarGlyphInstances.count,
      cellGlyphs: 0,
      cursors: cursorInstances.count)
  }

  private struct DamageYBounds {
    var minY: CGFloat
    var maxY: CGFloat

    func overlaps(y: CGFloat, height: CGFloat) -> Bool {
      guard height > 0 else { return false }
      return y < maxY && (y + height) > minY
    }
  }

  private static func damageYBounds(_ damage: RenderDamage) -> DamageYBounds? {
    guard case .partial(let ranges) = damage, !ranges.isEmpty else { return nil }
    var minY = CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    for range in ranges {
      guard range.height > 0 else { continue }
      minY = min(minY, range.y)
      maxY = max(maxY, range.y + range.height)
    }
    guard minY.isFinite, maxY.isFinite, minY < maxY else { return nil }
    return DamageYBounds(minY: minY, maxY: maxY)
  }

  private func buildInstanceListsOnce(
    commands: [FrameCommand],
    surfacePxH: Int,
    damageBounds: DamageYBounds?
  ) {
    solidInstances.removeAll(keepingCapacity: true)
    replaceSolidInstances.removeAll(keepingCapacity: true)
    glyphInstances.removeAll(keepingCapacity: true)
    colorGlyphInstances.removeAll(keepingCapacity: true)
    sidebarGlyphInstances.removeAll(keepingCapacity: true)
    cellGlyphs.removeAll(keepingCapacity: true)
    cursorInstances.removeAll(keepingCapacity: true)

    let surfaceH = Float(surfacePxH)
    // FrameProducer issues commands in (cgX, cgY = up-from-bottom) coords
    // measured in *points*. Multiply by scale to get device pixels for the
    // GPU, but keep y-up — Metal NDC matches.
    let scale = Float(layer.contentsScale)
    let preeditMaskRects = commands.compactMap { command -> CGRect? in
      if case .rect(let rect, _, .preedit, _) = command { return rect }
      return nil
    }

    @inline(__always)
    func appendSolid(
      rect: CGRect,
      color: UInt32,
      compositing: FrameCompositingMode = .sourceOver
    ) {
      // Skip empty rects — a stray .clip(.zero) would otherwise blank the screen.
      guard rect.width > 0, rect.height > 0 else { return }
      let originPx = SIMD2<Float>(
        Float(rect.origin.x) * scale, Float(rect.origin.y) * scale)
      let sizePx = SIMD2<Float>(
        Float(rect.width) * scale, Float(rect.height) * scale)
      let instance = SolidInstance(
        origin: originPx, size: sizePx, color: rgbaToFloat4(color))
      if compositing == .replace {
        replaceSolidInstances.append(instance)
      } else {
        solidInstances.append(instance)
      }
      _ = surfaceH  // silences the unused-capture lint when building release
    }

    @inline(__always)
    func appendGlyph(
      cellX: CGFloat, cellY: CGFloat,
      tilePixelW: Int, tilePixelH: Int,
      logicalOriginX: CGFloat,
      logicalWidth: CGFloat,
      atlasX: Int, atlasY: Int,
      color: UInt32,
      toSidebar: Bool
    ) {
      let originPx = SIMD2<Float>(
        Float(cellX + logicalOriginX) * scale, Float(cellY) * scale)
      let sizePx = SIMD2<Float>(Float(tilePixelW), Float(tilePixelH))
      let atlas = toSidebar ? sidebarGlyphAtlas : glyphAtlas
      let atlasW = Float(atlas.textureSize)
      let atlasH = Float(atlas.textureSize)
      let uvOrigin = SIMD2<Float>(Float(atlasX) / atlasW, Float(atlasY) / atlasH)
      let uvSize = SIMD2<Float>(Float(tilePixelW) / atlasW, Float(tilePixelH) / atlasH)
      let inst = GlyphInstance(
        origin: originPx, size: sizePx,
        uvOrigin: uvOrigin, uvSize: uvSize,
        color: rgbaToFloat4(color))
      if toSidebar {
        sidebarGlyphInstances.append(inst)
      } else {
        glyphInstances.append(inst)
      }
      _ = logicalWidth  // reserved for future per-cell width reconciliation
    }

    @inline(__always)
    func appendColorGlyph(
      cellX: CGFloat,
      cellY: CGFloat,
      entry: ColorGlyphAtlas.Entry
    ) {
      let originPx = SIMD2<Float>(
        Float(cellX + entry.logicalOriginX) * scale, Float(cellY) * scale)
      let sizePx = SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight))
      let atlasW = Float(colorGlyphAtlas.textureSize)
      let atlasH = Float(colorGlyphAtlas.textureSize)
      colorGlyphInstances.append(
        GlyphInstance(
          origin: originPx,
          size: sizePx,
          uvOrigin: SIMD2<Float>(
            Float(entry.originX) / atlasW,
            Float(entry.originY) / atlasH),
          uvSize: SIMD2<Float>(
            Float(entry.pixelWidth) / atlasW,
            Float(entry.pixelHeight) / atlasH),
          color: SIMD4<Float>(1, 1, 1, 1)))
    }

    for cmd in commands {
      switch cmd {
      case .rect(let rect, let color, _, let compositing):
        if let damageBounds, !damageBounds.overlaps(y: rect.origin.y, height: rect.height) {
          continue
        }
        appendSolid(rect: rect, color: color, compositing: compositing)

      case .cursor(let rect, let color):
        // Cursor lives in its own overlay pass on the drawable, not in the
        // persistent target. Blinks therefore don't dirty the terminal cells
        // beneath the cursor and don't require a content-pass redraw.
        guard rect.width > 0, rect.height > 0 else { break }
        cursorInstances.append(
          SolidInstance(
            origin: SIMD2<Float>(
              Float(rect.origin.x) * scale, Float(rect.origin.y) * scale),
            size: SIMD2<Float>(
              Float(rect.width) * scale, Float(rect.height) * scale),
            color: rgbaToFloat4(color)))

      case .selection(let rect, let color):
        if let damageBounds, !damageBounds.overlaps(y: rect.origin.y, height: rect.height) {
          continue
        }
        appendSolid(rect: rect, color: color)

      case .findMatch(let rect, let color),
        .findSelected(let rect, let color):
        if let damageBounds, !damageBounds.overlaps(y: rect.origin.y, height: rect.height) {
          continue
        }
        appendSolid(rect: rect, color: color)

      case .clip:
        // Flushing the batch + applying a scissor would honour clip ranges,
        // but FrameProducer doesn't currently emit .clip on the terminal
        // path — sidebar/terminal rects are positioned so nothing draws
        // outside the cell grid. Treat as no-op for now and revisit when a
        // producer needs hard clipping.
        break

      case .glyphRun(
        let origin, let text, let fg, _, let attrs, let runSource,
        let underlineStyle, let underlineColor, _, _, _, _, _):
        let isSidebar = runSource == .sidebar
        let runHeight = isSidebar ? sidebarCellHeight : glyphCellHeight
        if let damageBounds, !damageBounds.overlaps(y: origin.y, height: runHeight) {
          continue
        }
        let activeAtlas = isSidebar ? sidebarGlyphAtlas : glyphAtlas
        let activeAdvance = isSidebar ? sidebarCellAdvance : glyphCellAdvance
        let activeFontAtlas = isSidebar ? sidebarFontAtlas : fontAtlas
        let font = styledFont(for: attrs, in: activeFontAtlas)
        let traits = CTFontGetSymbolicTraits(font)
        let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
        let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)
        let runWantsColor =
          !isSidebar && emojiRenderingMode == .color
          && ColorGlyphSupport.mayContainColorGlyph(text: text, font: font)

        for (cellIndex, cluster) in text.enumerated() {
          let cellX = origin.x + CGFloat(cellIndex) * activeAdvance
          let cellRect = CGRect(
            x: cellX, y: origin.y, width: activeAdvance, height: runHeight)
          if !isSidebar, runSource != .preedit,
            preeditMaskRects.contains(where: { $0.intersects(cellRect) })
          {
            continue
          }
          if runWantsColor,
            ColorGlyphSupport.clusterMayBeColor(cluster),
            let entry = colorGlyphAtlas.entry(
              character: cluster,
              font: font,
              boldFallback: needsBoldFallback,
              italicFallback: needsItalicFallback)
          {
            appendColorGlyph(cellX: cellX, cellY: origin.y, entry: entry)
            continue
          }
          guard
            let entry = activeAtlas.entry(
              character: cluster, font: font,
              boldFallback: needsBoldFallback,
              italicFallback: needsItalicFallback)
          else { continue }
          appendGlyph(
            cellX: cellX, cellY: origin.y,
            tilePixelW: entry.pixelWidth, tilePixelH: entry.pixelHeight,
            logicalOriginX: entry.logicalOriginX,
            logicalWidth: entry.logicalWidth,
            atlasX: entry.originX, atlasY: entry.originY,
            color: fg,
            toSidebar: isSidebar)
        }

        // Decorations
        emitDecorations(
          for: text, at: origin, attributes: attrs,
          cellAdvance: activeAdvance,
          cellHeight: isSidebar ? sidebarCellHeight : glyphCellHeight,
          descent: activeFontAtlas.descent,
          fg: fg,
          underlineStyle: underlineStyle, underlineColor: underlineColor,
          appendSolid: { rect, color in appendSolid(rect: rect, color: color) })

      case .texturedQuad, .waveRegion:
        break
      }
    }
    lastInstanceCounts = RenderInstanceCounts(
      solids: solidInstances.count + replaceSolidInstances.count,
      glyphs: glyphInstances.count + colorGlyphInstances.count,
      sidebarGlyphs: sidebarGlyphInstances.count,
      cellGlyphs: cellGlyphs.count,
      cursors: cursorInstances.count)
  }

  private func prepareInstanceBuffer<Element>(
    _ buffer: inout MTLBuffer?,
    for instances: [Element]
  ) -> MTLBuffer? {
    let stride = MemoryLayout<Element>.stride
    guard
      let target = ensureBuffer(
        &buffer,
        elementCount: instances.count,
        elementStride: stride)
    else { return nil }
    instances.withUnsafeBufferPointer { src in
      if let base = src.baseAddress {
        memcpy(target.contents(), base, src.count * stride)
      }
    }
    return target
  }

  private func prepareCellGlyphBuffer() -> MTLBuffer? {
    guard !cellGlyphs.isEmpty else { return nil }
    let stride = MemoryLayout<CellGlyph>.stride
    let needsFullUpload = cellGlyphBuffer == nil
    guard
      let target = ensureBuffer(
        &cellGlyphBuffer,
        elementCount: cellGlyphs.count,
        elementStride: stride)
    else { return nil }
    let ranges = needsFullUpload ? [0..<cellGlyphs.count] : cellGlyphUploadRanges
    guard !ranges.isEmpty else { return target }
    cellGlyphs.withUnsafeBufferPointer { src in
      guard let base = src.baseAddress else { return }
      let dst = target.contents()
      for range in ranges {
        guard range.lowerBound >= 0, range.upperBound <= src.count else { continue }
        let byteOffset = range.lowerBound * stride
        memcpy(
          dst.advanced(by: byteOffset),
          base.advanced(by: range.lowerBound),
          range.count * stride)
      }
    }
    return target
  }

  /// Grow `buffer` if the current capacity can't fit `elementCount` x `elementStride` bytes.
  /// Adds 25% headroom to amortise growth in long sessions.
  private func ensureBuffer(
    _ buffer: inout MTLBuffer?,
    elementCount: Int,
    elementStride: Int
  ) -> MTLBuffer? {
    let required = elementCount.multipliedReportingOverflow(by: elementStride)
    guard !required.overflow, required.partialValue > 0 else { return nil }
    let needed = required.partialValue
    if let existing = buffer, existing.length >= needed {
      return existing
    }
    let headroom = needed / 4
    guard needed <= Int.max - headroom else { return nil }
    let withHeadroom = max(needed + headroom, 4096)
    guard let fresh = device.makeBuffer(length: withHeadroom, options: [.storageModeShared])
    else { return nil }
    buffer = fresh
    return fresh
  }

  // MARK: - Decorations (underline / strike / overline)

  private func emitDecorations(
    for text: String,
    at origin: CGPoint,
    attributes: TextAttributes,
    cellAdvance: CGFloat,
    cellHeight: CGFloat,
    descent: CGFloat,
    fg: UInt32,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    phaseOriginX: CGFloat? = nil,
    appendSolid: (CGRect, UInt32) -> Void
  ) {
    emitDecorations(
      cellCount: TerminalDisplayWidth.cells(of: text),
      at: origin,
      attributes: attributes,
      cellAdvance: cellAdvance,
      cellHeight: cellHeight,
      descent: descent,
      fg: fg,
      underlineStyle: underlineStyle,
      underlineColor: underlineColor,
      phaseOriginX: phaseOriginX,
      appendSolid: appendSolid)
  }

  private func emitDecorations(
    cellCount: Int,
    at origin: CGPoint,
    attributes: TextAttributes,
    cellAdvance: CGFloat,
    cellHeight: CGFloat,
    descent: CGFloat,
    fg: UInt32,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    phaseOriginX: CGFloat? = nil,
    appendSolid: (CGRect, UInt32) -> Void
  ) {
    guard
      let layout = TextDecorationLayout.make(
        origin: origin,
        cellCount: cellCount,
        attributes: attributes,
        underlineStyle: underlineStyle,
        cellAdvance: cellAdvance,
        cellHeight: cellHeight,
        descent: descent,
        scale: layer.contentsScale,
        phaseOriginX: phaseOriginX)
    else { return }

    let underlineRGBA = underlineColor ?? fg

    for rect in layout.underlineRects {
      appendSolid(rect, underlineRGBA)
    }

    if !layout.curlyUnderlinePoints.isEmpty {
      for (start, end) in zip(
        layout.curlyUnderlinePoints,
        layout.curlyUnderlinePoints.dropFirst())
      {
        appendSolid(
          CGRect(
            x: start.x,
            y: min(start.y, end.y),
            width: max(end.x - start.x, layout.thickness),
            height: max(layout.thickness, abs(end.y - start.y))),
          underlineRGBA)
      }
    }

    if let rect = layout.strikethroughRect {
      appendSolid(rect, fg)
    }
    if let rect = layout.overlineRect {
      appendSolid(rect, fg)
    }
  }

  private func commandsContainColorGlyph(_ commands: [FrameCommand]) -> Bool {
    guard emojiRenderingMode == .color else { return false }
    for command in commands {
      guard
        case .glyphRun(_, let text, _, _, let attrs, let source, _, _, _, _, _, _, _) = command,
        source != .sidebar,
        !text.isEmpty
      else { continue }
      let font = styledFont(for: attrs, in: fontAtlas)
      guard ColorGlyphSupport.mayContainColorGlyph(text: text, font: font) else { continue }
      let traits = CTFontGetSymbolicTraits(font)
      let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
      let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)
      for cluster in text where ColorGlyphSupport.clusterMayBeColor(cluster) {
        if colorGlyphAtlas.isColorGlyph(
          character: cluster, font: font,
          boldFallback: needsBoldFallback, italicFallback: needsItalicFallback)
        {
          return true
        }
      }
    }
    return false
  }

  // MARK: - Color-glyph routing (bed1a2b scroll-regression fix)
  //
  // Color-ness is a static property of (cluster, font): ghostty, kitty,
  // alacritty and wezterm all decide it once at rasterization and cache it on
  // the glyph, never re-shaping per frame. bed1a2b instead built a CoreText
  // CTLine per cluster across the whole screen every frame — tens of ms/frame
  // while scrolling. The decision now lives on `ColorGlyphAtlas` (computed once
  // at rasterization, read back as a boolean); the cheap scalar pre-filter in
  // `ColorGlyphSupport` rejects all plain text before the atlas is consulted.

  /// Cached emoji policy; refreshed on theme/emoji changes via
  /// `invalidateContentForThemeChange` so the encode path never reads
  /// `UserDefaults`.
  private var emojiRenderingMode: EmojiRenderingMode = EmojiRenderingSettings.current()

  // MARK: - Font cache (mirrors SoftwareRenderer.styledFont)

  private var fontCache: [UInt32: CTFont] = [:]
  private func styledFont(for attributes: TextAttributes, in atlas: FontAtlas) -> CTFont {
    // Cache key combines attribute bits with the atlas identity so the
    // sidebar's smaller-pt copies don't collide with the terminal's.
    let attrKey = UInt32(attributes.intersection([.bold, .italic]).rawValue)
    let atlasBit: UInt32 = (atlas === fontAtlas) ? 0 : 0x1_0000
    let key = attrKey | atlasBit
    if let cached = fontCache[key] { return cached }
    let font = atlas.styledFontVariant(
      bold: attributes.contains(.bold),
      italic: attributes.contains(.italic)
    ).font
    fontCache[key] = font
    return font
  }

  private static func record(from glyph: GlyphInstance) -> GPUCellGlyphRecord {
    GPUCellGlyphRecord(
      originPx: glyph.origin,
      sizePx: glyph.size,
      uvOrigin: glyph.uvOrigin,
      uvSize: glyph.uvSize,
      color: glyph.color,
      flags: gpuCellActiveFlag)
  }

  private static func record(from cell: CellGlyph) -> GPUCellGlyphRecord {
    GPUCellGlyphRecord(
      originPx: cell.originPx,
      sizePx: cell.sizePx,
      uvOrigin: cell.uvOrigin,
      uvSize: cell.uvSize,
      color: cell.fg,
      flags: cell.flags)
  }
}

// MARK: - Helpers

extension Array where Element == GPUCellGlyphRecord {
  fileprivate func sortedForOriginParity() -> [GPUCellGlyphRecord] {
    sorted { lhs, rhs in
      if lhs.originPx.y != rhs.originPx.y {
        return lhs.originPx.y < rhs.originPx.y
      }
      if lhs.originPx.x != rhs.originPx.x {
        return lhs.originPx.x < rhs.originPx.x
      }
      return lhs.sizePx.x < rhs.sizePx.x
    }
  }
}

// Precomputed byte -> unit-float table. Bit-identical to `Float(byte) / 255.0`
// (the table is filled by that exact expression), so colours are unchanged; it
// just trades four divisions per cell for four loads on the per-glyph hot path.
private let rgbaUnitFloatTable: [Float] = (0...255).map { Float($0) / 255.0 }

@inline(__always)
private func rgbaToFloat4(_ rgba: UInt32) -> SIMD4<Float> {
  SIMD4<Float>(
    rgbaUnitFloatTable[Int((rgba >> 24) & 0xFF)],
    rgbaUnitFloatTable[Int((rgba >> 16) & 0xFF)],
    rgbaUnitFloatTable[Int((rgba >> 8) & 0xFF)],
    rgbaUnitFloatTable[Int(rgba & 0xFF)])
}

@inline(__always)
private func msSince(_ start: ContinuousClock.Instant) -> Double {
  let dt = ContinuousClock.now - start
  return Double(dt.components.attoseconds) / 1e15
}

@inline(__always)
private func mean(_ xs: [Double]) -> Double {
  guard !xs.isEmpty else { return 0 }
  return xs.reduce(0, +) / Double(xs.count)
}

private func percentile(_ xs: [Double], _ p: Double) -> Double {
  guard !xs.isEmpty else { return 0 }
  let sorted = xs.sorted()
  let idx = Int((Double(sorted.count - 1) * p).rounded())
  return sorted[max(0, min(sorted.count - 1, idx))]
}
