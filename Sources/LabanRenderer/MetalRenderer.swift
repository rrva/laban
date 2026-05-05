import CoreGraphics
import CoreText
import Darwin.Mach
import Foundation
import Metal
import QuartzCore

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

private struct Uniforms {
  var surfaceSizePixels: SIMD2<Float>
  var scale: Float
  // Trailing pad to round to 16 bytes — Metal expects naturally aligned
  // constant buffers and the simd2/float here would otherwise leave a hole.
  var _pad: Float = 0
}

/// GPU renderer backed by `CAMetalLayer`. One device, one queue, one library.
/// Two pipelines (solid quad + textured glyph quad). Two draw calls per
/// "scissor span" — clip changes flush, everything else batches.
public final class MetalRenderer: RendererBackend {
  private static let maxGlyphAtlasTextureSize = 16_384

  // MARK: - Public surface

  public let device: MTLDevice
  public let layer: CAMetalLayer
  public let fontAtlas: FontAtlas
  /// Optional smaller font for sidebar chrome. When the caller provides
  /// nil at init time, sidebar text uses the same atlas as the terminal.
  public let sidebarFontAtlas: FontAtlas

  public var surfaceWidth: Int { Int(layer.drawableSize.width.rounded()) }
  public var surfaceHeight: Int { Int(layer.drawableSize.height.rounded()) }
  public var surfaceScale: CGFloat { layer.contentsScale }

  public var presentationLayer: CALayer? { layer }
  public var presentationImage: CGImage? { nil }

  /// Last-frame readback for screenshots / capture. Returns nil when
  /// `captureMode` is off (the drawable→CPU blit is skipped to keep
  /// cursor-blink frames cheap).
  public var pngData: Data? { encodeLastFrameAsPNG() }

  /// Rolling per-frame stats. p50/p99 in milliseconds. CPU = wall time
  /// inside `render()`. GPU = `cmdBuf.gpuEndTime - gpuStartTime` from the
  /// completion handler. Per-pass timings (content / presentBlit /
  /// cursorOverlay / readbackBlit) come from `MTLCounterSampleBuffer`
  /// timestamp samples — they are 0 when the device doesn't support
  /// timestamp counters or when the corresponding pass didn't execute
  /// this frame (e.g., readback skipped because captureMode is off).
  public struct FrameTimings: Equatable, Sendable {
    public var sampleCount: Int
    public var cpuMeanMs: Double
    public var cpuP50Ms: Double
    public var cpuP99Ms: Double
    public var gpuMeanMs: Double
    public var gpuP50Ms: Double
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
      cpuMeanMs: mean(cpu), cpuP50Ms: percentile(cpu, 0.50), cpuP99Ms: percentile(cpu, 0.99),
      gpuMeanMs: mean(gpu), gpuP50Ms: percentile(gpu, 0.50), gpuP99Ms: percentile(gpu, 0.99),
      contentMeanMs: mean(content),
      presentBlitMeanMs: mean(present),
      cursorOverlayMeanMs: mean(cursor),
      readbackBlitMeanMs: mean(readback),
      perPassAvailable: counterSampleBuffer != nil)
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
  private let glyphPipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private var glyphAtlas: MetalGlyphAtlas
  /// Distinct atlas for sidebar text — same when sidebarFontAtlas ===
  /// fontAtlas, otherwise a separately-rasterized R8 texture sized to
  /// the smaller font's cell metrics.
  private var sidebarGlyphAtlas: MetalGlyphAtlas

  private var solidInstances: [SolidInstance] = []
  private var glyphInstances: [GlyphInstance] = []
  /// Glyphs that draw against the sidebar atlas. Kept separate so we can
  /// issue one draw call per atlas — the sidebar's R8 texture holds glyphs
  /// rasterized at a smaller pt size and isn't substitutable for the main.
  private var sidebarGlyphInstances: [GlyphInstance] = []
  // Cursor instances drawn in a separate overlay pass — they live ON TOP of
  // the persistent target, never IN it, so cursor blinks don't dirty the
  // terminal cells underneath.
  private var cursorInstances: [SolidInstance] = []
  // setVertexBytes has a hard 4 KB limit, which one 80×24 frame can blow
  // past easily (one solid instance is 32 B, one glyph instance is 48 B).
  // We size MTLBuffers on demand and reuse them frame-to-frame.
  private var solidBuffer: MTLBuffer?
  private var glyphBuffer: MTLBuffer?
  private var sidebarGlyphBuffer: MTLBuffer?
  private var cursorBuffer: MTLBuffer?

  /// Persistent terminal-content render target. Holds the most recent fully
  /// rendered terminal cells (no cursor). Damage-driven updates write into
  /// this texture; clean rows survive untouched. Reallocated on resize, on
  /// first frame, and whenever a damage hint can't be honoured (e.g.,
  /// caller passed `.partial(empty)` but the surface size changed).
  private var targetTexture: MTLTexture?
  private var targetNeedsFullRedraw: Bool = true
  /// Last frame's command buffer. `pngData` waits on it before reading the
  /// readback texture so capture-side callers see the actual just-rendered
  /// pixels and not whatever the previous frame happened to leave behind.
  private var lastCmdBuf: MTLCommandBuffer?

  /// Limits frames in flight to 1. CAMetalLayer hands out up to 3 drawables
  /// in parallel, but our persistent target + scratch are SINGLE shared
  /// MTLTextures — without serialization, frame N's blit can read the
  /// target while frame N+1's content pass writes it. The visible artefact
  /// is a "ghost" (mixed pixels from two frames). One frame in flight on a
  /// terminal at vsync still leaves several ms of headroom; the safety
  /// outweighs the lost pipeline depth.
  private let frameInFlight = DispatchSemaphore(value: 1)

  /// Set true while a capture session needs the per-frame readback blit;
  /// false otherwise so cursor-blink frames don't pay the drawable→CPU copy
  /// (~50–100 µs of pure overhead with no consumer).
  public var captureMode: Bool = false

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
  // CGImage of the last rendered drawable, captured via blit-readback on
  // demand for the pngData accessor (capture/screenshot path).
  private var readbackTexture: MTLTexture?
  private let glyphCellAdvance: CGFloat
  private let glyphCellHeight: CGFloat
  private let sidebarCellAdvance: CGFloat
  private let sidebarCellHeight: CGFloat

  var terminalGlyphAtlasTextureSizeForTesting: Int { glyphAtlas.textureSize }

  /// Initializes the renderer. Returns nil when Metal is unavailable (no
  /// device, missing default library, or pipeline compile failure).
  public init?(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil,
    scale: CGFloat = 1,
    glyphAtlasTextureSize: Int = 2048
  ) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    guard let queue = device.makeCommandQueue() else { return nil }
    let initialAtlasTextureSize = min(
      max(1, glyphAtlasTextureSize),
      Self.maxGlyphAtlasTextureSize)
    // SwiftPM's .process(metal) just copies the source as a bundle resource;
    // it does not pre-compile to .metallib. We compile from source on startup
    // (~1 ms one-time cost) so the renderer ships with no extra build step.
    guard
      let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
      let source = try? String(contentsOf: url, encoding: .utf8),
      let library = try? device.makeLibrary(source: source, options: nil)
    else { return nil }
    guard
      let solidVS = library.makeFunction(name: "solid_vertex"),
      let solidFS = library.makeFunction(name: "solid_fragment"),
      let glyphVS = library.makeFunction(name: "glyph_vertex"),
      let glyphFS = library.makeFunction(name: "glyph_fragment")
    else { return nil }

    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false  // need readable color for capture readback
    layer.contentsScale = scale
    layer.isOpaque = true
    // Anchor the drawable to the bottom-left of the layer's frame. Without
    // this, CAMetalLayer's default `.resize` gravity stretches the old
    // drawable to the new layer frame between a window-resize event and
    // the next render — which visibly drifts content (most noticeably the
    // cursor at row 0). With bottomLeft, the existing pixels stay at their
    // native size and any newly-uncovered area shows the layer background.
    layer.contentsGravity = .bottomLeft

    let solidDesc = MTLRenderPipelineDescriptor()
    solidDesc.label = "laban.solid-quad"
    solidDesc.vertexFunction = solidVS
    solidDesc.fragmentFunction = solidFS
    let solidAttachment = solidDesc.colorAttachments[0]!
    solidAttachment.pixelFormat = layer.pixelFormat
    solidAttachment.isBlendingEnabled = true
    solidAttachment.rgbBlendOperation = .add
    solidAttachment.alphaBlendOperation = .add
    solidAttachment.sourceRGBBlendFactor = .one  // shader pre-multiplies
    solidAttachment.sourceAlphaBlendFactor = .one
    solidAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    solidAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    let glyphDesc = MTLRenderPipelineDescriptor()
    glyphDesc.label = "laban.glyph-quad"
    glyphDesc.vertexFunction = glyphVS
    glyphDesc.fragmentFunction = glyphFS
    let glyphAttachment = glyphDesc.colorAttachments[0]!
    glyphAttachment.pixelFormat = layer.pixelFormat
    glyphAttachment.isBlendingEnabled = true
    glyphAttachment.rgbBlendOperation = .add
    glyphAttachment.alphaBlendOperation = .add
    glyphAttachment.sourceRGBBlendFactor = .one
    glyphAttachment.sourceAlphaBlendFactor = .one
    glyphAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    glyphAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    guard
      let solidPipeline = try? device.makeRenderPipelineState(descriptor: solidDesc),
      let glyphPipeline = try? device.makeRenderPipelineState(descriptor: glyphDesc)
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
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarAtlas
    self.solidPipeline = solidPipeline
    self.glyphPipeline = glyphPipeline
    self.sampler = sampler
    self.glyphAtlas = atlas
    self.sidebarGlyphAtlas = sidebarGlyphAtlasInstance
    self.glyphCellAdvance = cell.width
    self.glyphCellHeight = cell.height
    self.sidebarCellAdvance = sidebarCell.width
    self.sidebarCellHeight = sidebarCell.height

    setupCounterSampling()
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
  public func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) {
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
    }
    if sizeChanged {
      layer.drawableSize = CGSize(width: pw, height: ph)
      readbackTexture = nil
      targetTexture = nil
      targetNeedsFullRedraw = true
    }
  }

  // MARK: - render

  public func render(_ commands: [FrameCommand], damage: RenderDamage) {
    let cpuStart = ContinuousClock.now

    // Drop this frame if the previous GPU frame has not retired. Without a
    // gate, multiple in-flight frames stomp on the shared persistent target
    // and scratch textures; blocking here would put that wait on the caller.
    guard frameInFlight.wait(timeout: .now()) == .success else {
      return
    }
    guard let drawable = layer.nextDrawable() else {
      frameInFlight.signal()
      return
    }
    let drawableTex = drawable.texture
    guard let cmdBuf = queue.makeCommandBuffer() else {
      frameInFlight.signal()
      return
    }
    cmdBuf.label = "laban.frame"
    // Strong-self capture keeps the renderer alive until the GPU work
    // completes — DispatchSemaphore traps on deinit if a wait() outstrips
    // the matching signal(), so the renderer must outlive any frame it
    // committed. The same handler also closes out per-frame timing once
    // the GPU has reported gpuStartTime/gpuEndTime.
    cmdBuf.addCompletedHandler { [self] buffer in
      let cpuMs = msSince(cpuStart)
      let gpuMs = max(0.0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0)
      // Resolve per-pass GPU times BEFORE signalling the next frame in
      // (otherwise frame N+1 could overwrite the sample buffer slots).
      let perPass = self.resolvePerPassTimingsForFrame()
      self.frameSampleLock.lock()
      self.frameSamples.append(
        FrameSample(
          cpuMs: cpuMs, gpuMs: gpuMs,
          contentMs: perPass.content,
          presentBlitMs: perPass.present,
          cursorOverlayMs: perPass.cursor,
          readbackBlitMs: perPass.readback))
      if self.frameSamples.count > Self.frameSampleCap {
        self.frameSamples.removeFirst(self.frameSamples.count - Self.frameSampleCap)
      }
      self.frameSampleLock.unlock()
      self.onFrameCompleted?()
      self.frameInFlight.signal()
    }

    ensureTargetTexture(matching: drawableTex)
    guard let target = targetTexture else {
      frameInFlight.signal()
      return
    }

    let surfaceWPx = drawableTex.width
    let surfaceHPx = drawableTex.height
    var u = Uniforms(
      surfaceSizePixels: SIMD2<Float>(Float(surfaceWPx), Float(surfaceHPx)),
      scale: Float(layer.contentsScale))

    // First frame after a target realloc must clear+repaint the full surface.
    // Otherwise honour the caller's damage hint directly.
    let effectiveDamage: RenderDamage = targetNeedsFullRedraw ? .full : damage

    var passSlots = PassSlots()

    // ---------- Pass 1: terminal content into the persistent target ----------
    let didContent = encodeContentPass(
      commands: commands,
      damage: effectiveDamage,
      target: target,
      surfacePxH: surfaceHPx,
      uniforms: &u,
      cmdBuf: cmdBuf)
    if targetNeedsFullRedraw && !didContent {
      frameInFlight.signal()
      return
    }
    passSlots.contentActive = didContent

    // ---------- Pass 2: blit persistent target → drawable ----------
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
        to: drawableTex, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      blit.endEncoding()
      passSlots.presentActive = true
    }

    // ---------- Pass 3: cursor overlay on the drawable ----------
    if !cursorInstances.isEmpty,
      let buf = prepareInstanceBuffer(&cursorBuffer, for: cursorInstances)
    {
      let cursorPass = MTLRenderPassDescriptor()
      let attach = cursorPass.colorAttachments[0]!
      attach.texture = drawableTex
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
    // of the whole drawable.
    if captureMode {
      if readbackTexture == nil
        || readbackTexture?.width != drawableTex.width
        || readbackTexture?.height != drawableTex.height
      {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: layer.pixelFormat,
          width: drawableTex.width, height: drawableTex.height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        readbackTexture = device.makeTexture(descriptor: desc)
        readbackTexture?.label = "readback"
      }
      let readbackBlitDesc = MTLBlitPassDescriptor()
      if counterBlitSupported, let cb = counterSampleBuffer,
        let attach = readbackBlitDesc.sampleBufferAttachments[0]
      {
        attach.sampleBuffer = cb
        attach.startOfEncoderSampleIndex = 6
        attach.endOfEncoderSampleIndex = 7
      }
      if let dst = readbackTexture,
        let blit = cmdBuf.makeBlitCommandEncoder(descriptor: readbackBlitDesc)
      {
        blit.label = "readback-blit"
        blit.copy(
          from: drawableTex, sourceSlice: 0, sourceLevel: 0,
          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: drawableTex.width, height: drawableTex.height, depth: 1),
          to: dst, destinationSlice: 0, destinationLevel: 0,
          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        passSlots.readbackActive = true
      }
    }

    self.lastFramePassSlots = passSlots
    cmdBuf.present(drawable)
    cmdBuf.commit()
    lastCmdBuf = cmdBuf
    targetNeedsFullRedraw = false
  }

  /// Slots in flight for the most recent frame. Read by the completion
  /// handler so we know which sample-buffer ranges contain valid data.
  private var lastFramePassSlots = PassSlots()

  /// Allocate (or reallocate) the persistent render target to match the
  /// drawable. Same pixel format so the end-of-frame blit is a GPU memcpy.
  private func ensureTargetTexture(matching drawableTex: MTLTexture) {
    if let t = targetTexture,
      t.width == drawableTex.width,
      t.height == drawableTex.height,
      t.pixelFormat == layer.pixelFormat
    {
      return
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: layer.pixelFormat,
      width: drawableTex.width,
      height: drawableTex.height,
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
    buildInstanceLists(commands: commands, surfacePxH: surfacePxH)

    // Skip the content pass entirely if the caller said nothing changed.
    if case .partial(let yRanges) = damage, yRanges.isEmpty {
      return false
    }

    let pass = MTLRenderPassDescriptor()
    let attach = pass.colorAttachments[0]!
    attach.texture = target
    attach.storeAction = .store

    var scissor: MTLScissorRect?
    switch damage {
    case .full:
      attach.loadAction = .clear
      attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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

    let glyphFrameBuffer: MTLBuffer?
    if glyphInstances.isEmpty {
      glyphFrameBuffer = nil
    } else {
      guard let buffer = prepareInstanceBuffer(&glyphBuffer, for: glyphInstances) else {
        return false
      }
      glyphFrameBuffer = buffer
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

    if let buf = solidFrameBuffer {
      encoder.setRenderPipelineState(solidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: solidInstances.count)
    }
    if let buf = glyphFrameBuffer {
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(glyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: glyphInstances.count)
    }
    if let buf = sidebarGlyphFrameBuffer {
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(sidebarGlyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: sidebarGlyphInstances.count)
    }
    encoder.endEncoding()
    return true
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
    surfacePxH: Int
  ) {
    var attempts = 0
    while true {
      glyphAtlas.clearOverflowFlag()
      if sidebarGlyphAtlas !== glyphAtlas {
        sidebarGlyphAtlas.clearOverflowFlag()
      }
      buildInstanceListsOnce(commands: commands, surfacePxH: surfacePxH)

      let terminalOverflow = glyphAtlas.didOverflow
      let sidebarOverflow = sidebarGlyphAtlas.didOverflow
      guard terminalOverflow || sidebarOverflow else { return }

      attempts += 1
      guard attempts < 4 else { return }

      var grew = false
      if terminalOverflow {
        grew = growGlyphAtlas(forSidebar: false) || grew
      }
      if sidebarOverflow && !(terminalOverflow && sidebarGlyphAtlas === glyphAtlas) {
        grew = growGlyphAtlas(forSidebar: true) || grew
      }
      guard grew else { return }
    }
  }

  private func buildInstanceListsOnce(
    commands: [FrameCommand],
    surfacePxH: Int
  ) {
    solidInstances.removeAll(keepingCapacity: true)
    glyphInstances.removeAll(keepingCapacity: true)
    sidebarGlyphInstances.removeAll(keepingCapacity: true)
    cursorInstances.removeAll(keepingCapacity: true)

    let surfaceH = Float(surfacePxH)
    // FrameProducer issues commands in (cgX, cgY = up-from-bottom) coords
    // measured in *points*. Multiply by scale to get device pixels for the
    // GPU, but keep y-up — Metal NDC matches.
    let scale = Float(layer.contentsScale)

    @inline(__always)
    func appendSolid(rect: CGRect, color: UInt32) {
      // Skip empty rects — a stray .clip(.zero) would otherwise blank the screen.
      guard rect.width > 0, rect.height > 0 else { return }
      let originPx = SIMD2<Float>(
        Float(rect.origin.x) * scale, Float(rect.origin.y) * scale)
      let sizePx = SIMD2<Float>(
        Float(rect.width) * scale, Float(rect.height) * scale)
      solidInstances.append(
        SolidInstance(origin: originPx, size: sizePx, color: rgbaToFloat4(color)))
      _ = surfaceH  // silences the unused-capture lint when building release
    }

    @inline(__always)
    func appendGlyph(
      cellX: CGFloat, cellY: CGFloat,
      tilePixelW: Int, tilePixelH: Int,
      logicalWidth: CGFloat,
      atlasX: Int, atlasY: Int,
      color: UInt32,
      toSidebar: Bool
    ) {
      let originPx = SIMD2<Float>(Float(cellX) * scale, Float(cellY) * scale)
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

    for cmd in commands {
      switch cmd {
      case .rect(let rect, let color, _):
        appendSolid(rect: rect, color: color)

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
        let underlineStyle, let underlineColor, _
      ):
        let isSidebar = runSource == .sidebar
        let activeAtlas = isSidebar ? sidebarGlyphAtlas : glyphAtlas
        let activeAdvance = isSidebar ? sidebarCellAdvance : glyphCellAdvance
        let activeFontAtlas = isSidebar ? sidebarFontAtlas : fontAtlas
        let font = styledFont(for: attrs, in: activeFontAtlas)
        let traits = CTFontGetSymbolicTraits(font)
        let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
        let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)

        for (cellIndex, cluster) in text.enumerated() {
          guard
            let entry = activeAtlas.entry(
              character: cluster, font: font,
              boldFallback: needsBoldFallback,
              italicFallback: needsItalicFallback)
          else { continue }
          let cellX = origin.x + CGFloat(cellIndex) * activeAdvance
          appendGlyph(
            cellX: cellX, cellY: origin.y,
            tilePixelW: entry.pixelWidth, tilePixelH: entry.pixelHeight,
            logicalWidth: entry.logicalWidth,
            atlasX: entry.originX, atlasY: entry.originY,
            color: fg,
            toSidebar: isSidebar)
        }

        // Decorations
        emitDecorations(
          for: text, at: origin, attributes: attrs,
          fg: fg,
          underlineStyle: underlineStyle, underlineColor: underlineColor,
          appendSolid: appendSolid)

      case .texturedQuad:
        break
      }
    }
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
    fg: UInt32,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    appendSolid: (CGRect, UInt32) -> Void
  ) {
    let drawsUnderline = attributes.contains(.underline) || underlineStyle != .none
    let drawsStrike = attributes.contains(.strikethrough)
    let drawsOverline = attributes.contains(.overline)
    guard drawsUnderline || drawsStrike || drawsOverline, !text.isEmpty else { return }

    let width = CGFloat(text.count) * glyphCellAdvance
    let cellHeight = glyphCellHeight
    let thickness = max(1.0 / layer.contentsScale, 1)
    let underlineY = origin.y + max(1, floor(fontAtlas.descent * 0.45))
    let underlineRGBA = underlineColor ?? fg

    if drawsUnderline {
      let style: UnderlineStyle = underlineStyle == .none ? .single : underlineStyle
      switch style {
      case .none, .single:
        appendSolid(
          CGRect(x: origin.x, y: underlineY, width: width, height: thickness),
          underlineRGBA)
      case .double:
        appendSolid(
          CGRect(x: origin.x, y: underlineY, width: width, height: thickness),
          underlineRGBA)
        let gap = max(thickness, 1)
        appendSolid(
          CGRect(
            x: origin.x, y: underlineY + thickness + gap,
            width: width, height: thickness),
          underlineRGBA)
      case .curly:
        // Approximate a sine wave with short segments — keeps the renderer
        // shader-free at the cost of ~2× cell-width quads per cell.
        let amplitude = max(thickness * 1.2, 1.0)
        let baseY = underlineY + thickness * 0.5
        let steps = max(Int(width / 1.5), 8)
        var prev = CGPoint(x: origin.x, y: baseY)
        for i in 1...steps {
          let t = CGFloat(i) / CGFloat(steps)
          let cx = origin.x + width * t
          let cy = baseY + amplitude * CGFloat(sin(Double(t * width / glyphCellAdvance) * 2 * .pi))
          appendSolid(
            CGRect(
              x: prev.x,
              y: min(prev.y, cy),
              width: max(cx - prev.x, 1),
              height: max(thickness, abs(cy - prev.y))),
            underlineRGBA)
          prev = CGPoint(x: cx, y: cy)
        }
      case .dotted:
        let dot = max(thickness, 1)
        var cx = origin.x
        while cx < origin.x + width {
          appendSolid(
            CGRect(x: cx, y: underlineY, width: dot, height: thickness),
            underlineRGBA)
          cx += dot * 2
        }
      case .dashed:
        let dash = max(glyphCellAdvance * 0.5, 3)
        let gap = max(glyphCellAdvance * 0.25, 2)
        var cx = origin.x
        while cx < origin.x + width {
          let segW = min(dash, origin.x + width - cx)
          appendSolid(
            CGRect(x: cx, y: underlineY, width: segW, height: thickness),
            underlineRGBA)
          cx += dash + gap
        }
      }
    }

    if drawsStrike {
      appendSolid(
        CGRect(
          x: origin.x, y: origin.y + floor(cellHeight * 0.52),
          width: width, height: thickness),
        fg)
    }
    if drawsOverline {
      appendSolid(
        CGRect(
          x: origin.x, y: origin.y + cellHeight - thickness - 1,
          width: width, height: thickness),
        fg)
    }
  }

  // MARK: - Font cache (mirrors SoftwareRenderer.styledFont)

  private var fontCache: [UInt32: CTFont] = [:]
  private func styledFont(for attributes: TextAttributes, in atlas: FontAtlas) -> CTFont {
    // Cache key combines attribute bits with the atlas identity so the
    // sidebar's smaller-pt copies don't collide with the terminal's.
    let attrKey = UInt32(attributes.intersection([.bold, .italic]).rawValue)
    let atlasBit: UInt32 = (atlas === fontAtlas) ? 0 : 0x1_0000
    let key = attrKey | atlasBit
    if let cached = fontCache[key] { return cached }
    var desired: CTFontSymbolicTraits = []
    if attributes.contains(.bold) { desired.insert(.traitBold) }
    if attributes.contains(.italic) { desired.insert(.traitItalic) }
    let font: CTFont
    if desired.isEmpty {
      font = atlas.font
    } else {
      font =
        CTFontCreateCopyWithSymbolicTraits(
          atlas.font, atlas.pointSize, nil, desired, desired)
        ?? atlas.font
    }
    fontCache[key] = font
    return font
  }

  // MARK: - PNG readback

  private func encodeLastFrameAsPNG() -> Data? {
    guard let tex = readbackTexture else { return nil }
    // Capture / screenshot callers can read pngData any time; the GPU might
    // not have finished the most recent render yet. Block until it has so
    // we never serialise a stale frame.
    lastCmdBuf?.waitUntilCompleted()
    let w = tex.width
    let h = tex.height
    let bytesPerRow = w * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
    bytes.withUnsafeMutableBytes { ptr in
      if let base = ptr.baseAddress {
        tex.getBytes(
          base,
          bytesPerRow: bytesPerRow,
          from: MTLRegionMake2D(0, 0, w, h),
          mipmapLevel: 0)
      }
    }
    let bitmapInfo: UInt32 =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard
      let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }
    return PNGEncoder.encode(image)
  }
}

// MARK: - Helpers

private func rgbaToFloat4(_ rgba: UInt32) -> SIMD4<Float> {
  let r = Float((rgba >> 24) & 0xFF) / 255.0
  let g = Float((rgba >> 16) & 0xFF) / 255.0
  let b = Float((rgba >> 8) & 0xFF) / 255.0
  let a = Float(rgba & 0xFF) / 255.0
  return SIMD4<Float>(r, g, b, a)
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
