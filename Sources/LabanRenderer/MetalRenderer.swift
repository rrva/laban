import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore

// MARK: - Per-instance GPU types
//
// Layouts MUST match the structs in Shaders.metal exactly. Sizes and pads
// are commented; tweak with care if either side changes.

private struct SolidInstance {
  var origin: SIMD2<Float>      //  8
  var size:   SIMD2<Float>      //  8
  var color:  SIMD4<Float>      // 16  (rgba 0..1, straight alpha)
}

private struct GlyphInstance {
  var origin:    SIMD2<Float>   //  8
  var size:      SIMD2<Float>   //  8
  var uvOrigin:  SIMD2<Float>   //  8
  var uvSize:    SIMD2<Float>   //  8
  var color:     SIMD4<Float>   // 16
}

private struct Uniforms {
  var surfaceSizePixels: SIMD2<Float>
  var scale:             Float
  // Trailing pad to round to 16 bytes — Metal expects naturally aligned
  // constant buffers and the simd2/float here would otherwise leave a hole.
  var _pad:              Float = 0
}

/// GPU renderer backed by `CAMetalLayer`. One device, one queue, one library.
/// Two pipelines (solid quad + textured glyph quad). Two draw calls per
/// "scissor span" — clip changes flush, everything else batches.
public final class MetalRenderer: RendererBackend {

  // MARK: - Public surface

  public let device: MTLDevice
  public let layer: CAMetalLayer
  public let fontAtlas: FontAtlas

  public var surfaceWidth: Int { Int(layer.drawableSize.width.rounded()) }
  public var surfaceHeight: Int { Int(layer.drawableSize.height.rounded()) }
  public var surfaceScale: CGFloat { layer.contentsScale }

  public var presentationLayer: CALayer? { layer }
  public var presentationImage: CGImage? { nil }

  /// Last-frame readback for screenshots / capture. Filled on demand from
  /// the most recently rendered offscreen color attachment.
  public var pngData: Data? { encodeLastFrameAsPNG() }

  // MARK: - Internals

  private let queue: MTLCommandQueue
  private let solidPipeline: MTLRenderPipelineState
  private let glyphPipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private var glyphAtlas: MetalGlyphAtlas

  private var solidInstances: [SolidInstance] = []
  private var glyphInstances: [GlyphInstance] = []
  // Cursor instances drawn in a separate overlay pass — they live ON TOP of
  // the persistent target, never IN it, so cursor blinks don't dirty the
  // terminal cells underneath.
  private var cursorInstances: [SolidInstance] = []
  // setVertexBytes has a hard 4 KB limit, which one 80×24 frame can blow
  // past easily (one solid instance is 32 B, one glyph instance is 48 B).
  // We size MTLBuffers on demand and reuse them frame-to-frame.
  private var solidBuffer: MTLBuffer?
  private var glyphBuffer: MTLBuffer?
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
  // CGImage of the last rendered drawable, captured via blit-readback on
  // demand for the pngData accessor (capture/screenshot path).
  private var readbackTexture: MTLTexture?
  private let glyphCellAdvance: CGFloat
  private let glyphCellHeight: CGFloat

  /// Initializes the renderer. Returns nil when Metal is unavailable (no
  /// device, missing default library, or pipeline compile failure).
  public init?(fontAtlas: FontAtlas, scale: CGFloat = 1) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    guard let queue = device.makeCommandQueue() else { return nil }
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

    let solidDesc = MTLRenderPipelineDescriptor()
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
        scale: scale)
    else { return nil }

    self.device = device
    self.queue = queue
    self.layer = layer
    self.fontAtlas = fontAtlas
    self.solidPipeline = solidPipeline
    self.glyphPipeline = glyphPipeline
    self.sampler = sampler
    self.glyphAtlas = atlas
    self.glyphCellAdvance = cell.width
    self.glyphCellHeight = cell.height
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
        scale: newScale)
      {
        glyphAtlas = fresh
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
    // Block until the previous frame's GPU work has retired. Without this,
    // multiple in-flight frames stomp on the shared persistent target and
    // scratch textures and the user sees ghost pixels.
    frameInFlight.wait()
    guard let drawable = layer.nextDrawable() else {
      frameInFlight.signal()
      return
    }
    let drawableTex = drawable.texture
    guard let cmdBuf = queue.makeCommandBuffer() else {
      frameInFlight.signal()
      return
    }
    // Strong-self capture keeps the renderer alive until the GPU work
    // completes — DispatchSemaphore traps on deinit if a wait() outstrips
    // the matching signal(), so the renderer must outlive any frame it
    // committed.
    cmdBuf.addCompletedHandler { [self] _ in
      self.frameInFlight.signal()
    }

    ensureTargetTexture(matching: drawableTex)
    guard let target = targetTexture else { return }

    let surfaceWPx = drawableTex.width
    let surfaceHPx = drawableTex.height
    var u = Uniforms(
      surfaceSizePixels: SIMD2<Float>(Float(surfaceWPx), Float(surfaceHPx)),
      scale: Float(layer.contentsScale))

    // First frame after a target realloc must clear+repaint the full surface.
    // Otherwise honour the caller's damage hint directly.
    let effectiveDamage: RenderDamage = targetNeedsFullRedraw ? .full : damage

    // ---------- Pass 1: terminal content into the persistent target ----------
    encodeContentPass(
      commands: commands,
      damage: effectiveDamage,
      target: target,
      surfacePxH: surfaceHPx,
      uniforms: &u,
      cmdBuf: cmdBuf)

    // ---------- Pass 2: blit persistent target → drawable ----------
    if let blit = cmdBuf.makeBlitCommandEncoder() {
      blit.copy(
        from: target, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: surfaceWPx, height: surfaceHPx, depth: 1),
        to: drawableTex, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      blit.endEncoding()
    }

    // ---------- Pass 3: cursor overlay on the drawable ----------
    if !cursorInstances.isEmpty {
      let cursorPass = MTLRenderPassDescriptor()
      let attach = cursorPass.colorAttachments[0]!
      attach.texture = drawableTex
      attach.loadAction = .load
      attach.storeAction = .store
      if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: cursorPass) {
        enc.label = "cursor-overlay"
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        let buf = ensureBuffer(
          &cursorBuffer,
          elementCount: cursorInstances.count,
          elementStride: MemoryLayout<SolidInstance>.stride)
        cursorInstances.withUnsafeBufferPointer { src in
          if let base = src.baseAddress {
            memcpy(buf.contents(), base, src.count * MemoryLayout<SolidInstance>.stride)
          }
        }
        enc.setRenderPipelineState(solidPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(
          type: .triangle, vertexStart: 0,
          vertexCount: 6, instanceCount: cursorInstances.count)
        enc.endEncoding()
      }
    }

    // ---------- Pass 4: capture readback (blit drawable → CPU-readable) -----
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
    }
    if let dst = readbackTexture, let blit = cmdBuf.makeBlitCommandEncoder() {
      blit.copy(
        from: drawableTex, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: drawableTex.width, height: drawableTex.height, depth: 1),
        to: dst, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      blit.endEncoding()
    }

    cmdBuf.present(drawable)
    cmdBuf.commit()
    lastCmdBuf = cmdBuf
    targetNeedsFullRedraw = false
  }

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

  /// Pass 1: render terminal cells (everything but the cursor) into the
  /// persistent target. Honours `damage`:
  /// - `.full`: clear + draw all instances.
  /// - `.partial([])`: skip the pass entirely (target unchanged).
  /// - `.partial(ranges)`: load + scissor to the union bounding box +
  ///   draw all instances. The scissor culls clean rows; all instances are
  ///   submitted because tracking which instance touches which row would
  ///   be more expensive than the GPU early-rejecting them via scissor.
  private func encodeContentPass(
    commands: [FrameCommand],
    damage: RenderDamage,
    target: MTLTexture,
    surfacePxH: Int,
    uniforms u: inout Uniforms,
    cmdBuf: MTLCommandBuffer
  ) {
    // Build instance lists once for both the content pass and the cursor pass.
    buildInstanceLists(commands: commands, surfacePxH: surfacePxH)

    // Skip the content pass entirely if the caller said nothing changed.
    if case .partial(let yRanges) = damage, yRanges.isEmpty {
      return
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
        yRanges, surfacePxH: surfacePxH, scale: layer.contentsScale)
    }

    guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: pass) else {
      return
    }
    encoder.label = "terminal-content"
    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    if let s = scissor {
      encoder.setScissorRect(s)
    }

    if !solidInstances.isEmpty {
      let buf = ensureBuffer(
        &solidBuffer,
        elementCount: solidInstances.count,
        elementStride: MemoryLayout<SolidInstance>.stride)
      solidInstances.withUnsafeBufferPointer { src in
        if let base = src.baseAddress {
          memcpy(buf.contents(), base, src.count * MemoryLayout<SolidInstance>.stride)
        }
      }
      encoder.setRenderPipelineState(solidPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: solidInstances.count)
    }
    if !glyphInstances.isEmpty {
      let buf = ensureBuffer(
        &glyphBuffer,
        elementCount: glyphInstances.count,
        elementStride: MemoryLayout<GlyphInstance>.stride)
      glyphInstances.withUnsafeBufferPointer { src in
        if let base = src.baseAddress {
          memcpy(buf.contents(), base, src.count * MemoryLayout<GlyphInstance>.stride)
        }
      }
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setVertexBuffer(buf, offset: 0, index: 0)
      encoder.setFragmentTexture(glyphAtlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0,
        vertexCount: 6, instanceCount: glyphInstances.count)
    }
    encoder.endEncoding()
  }

  /// Compute the union bounding-box scissor rect (in device pixels) covering
  /// all dirty Y ranges. Returns nil for an empty list. CG has y-up; Metal
  /// scissor rects use y-down (origin top-left), so we flip here.
  private func scissorRectFromYRanges(
    _ ranges: [DirtyYRange], surfacePxH: Int, scale: CGFloat
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
    return MTLScissorRect(x: 0, y: topPx, width: surfaceWidth, height: height)
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
    solidInstances.removeAll(keepingCapacity: true)
    glyphInstances.removeAll(keepingCapacity: true)
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
      color: UInt32
    ) {
      let originPx = SIMD2<Float>(Float(cellX) * scale, Float(cellY) * scale)
      let sizePx = SIMD2<Float>(Float(tilePixelW), Float(tilePixelH))
      let atlasW = Float(glyphAtlas.textureSize)
      let atlasH = Float(glyphAtlas.textureSize)
      let uvOrigin = SIMD2<Float>(Float(atlasX) / atlasW, Float(atlasY) / atlasH)
      let uvSize = SIMD2<Float>(Float(tilePixelW) / atlasW, Float(tilePixelH) / atlasH)
      glyphInstances.append(
        GlyphInstance(
          origin: originPx, size: sizePx,
          uvOrigin: uvOrigin, uvSize: uvSize,
          color: rgbaToFloat4(color)))
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
        let origin, let text, let fg, _, let attrs, _,
        let underlineStyle, let underlineColor, _
      ):
        let font = styledFont(for: attrs)
        let traits = CTFontGetSymbolicTraits(font)
        let needsBoldFallback = attrs.contains(.bold) && !traits.contains(.traitBold)
        let needsItalicFallback = attrs.contains(.italic) && !traits.contains(.traitItalic)

        for (cellIndex, cluster) in text.enumerated() {
          guard cluster.unicodeScalars.count == 1,
            let scalar = cluster.unicodeScalars.first
          else { continue }
          guard
            let entry = glyphAtlas.entry(
              scalar: scalar, font: font,
              boldFallback: needsBoldFallback,
              italicFallback: needsItalicFallback)
          else { continue }
          let cellX = origin.x + CGFloat(cellIndex) * glyphCellAdvance
          appendGlyph(
            cellX: cellX, cellY: origin.y,
            tilePixelW: entry.pixelWidth, tilePixelH: entry.pixelHeight,
            logicalWidth: entry.logicalWidth,
            atlasX: entry.originX, atlasY: entry.originY,
            color: fg)
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

  /// Grow `buffer` if the current capacity can't fit `elementCount` × `elementStride` bytes.
  /// Adds 25% headroom to amortise growth in long sessions.
  private func ensureBuffer(
    _ buffer: inout MTLBuffer?,
    elementCount: Int,
    elementStride: Int
  ) -> MTLBuffer {
    let needed = elementCount * elementStride
    if let existing = buffer, existing.length >= needed {
      return existing
    }
    let withHeadroom = max(needed + needed / 4, 4096)
    let fresh = device.makeBuffer(length: withHeadroom, options: [.storageModeShared])!
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

  private var fontCache: [UInt16: CTFont] = [:]
  private func styledFont(for attributes: TextAttributes) -> CTFont {
    let key = attributes.intersection([.bold, .italic]).rawValue
    if let cached = fontCache[key] { return cached }
    var desired: CTFontSymbolicTraits = []
    if attributes.contains(.bold) { desired.insert(.traitBold) }
    if attributes.contains(.italic) { desired.insert(.traitItalic) }
    let font: CTFont
    if desired.isEmpty {
      font = fontAtlas.font
    } else {
      font =
        CTFontCreateCopyWithSymbolicTraits(
          fontAtlas.font, fontAtlas.pointSize, nil, desired, desired)
        ?? fontAtlas.font
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
      let cs = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: bytesPerRow, space: cs,
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
