import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore

struct VectorGlyphMaskSnapshot: Equatable {
  var glyph: CGGlyph
  var width: Int
  var height: Int
  var origin: CGPoint
  var bytes: [UInt8]
}

private struct VectorSolidInstance {
  var origin: SIMD2<Float>
  var size: SIMD2<Float>
  var color: SIMD4<Float>
}

private struct VectorGlyphInstance {
  var origin: SIMD2<Float>
  var size: SIMD2<Float>
  var uvOrigin: SIMD2<Float>
  var uvSize: SIMD2<Float>
  var color: SIMD4<Float>
  // Exponent applied to vector coverage (c^e) for stem-darkening: e<1 thickens.
  // 1.0 = no change (used by raster/emoji fallbacks whose masks are already
  // weighted by CoreText).
  var coverageExponent: Float
}

private struct VectorUniforms {
  var surfaceSizePixels: SIMD2<Float>
  var scale: Float
  var _pad: Float = 0
}

private struct VectorMaskDescriptor {
  var outline: GlyphCurveOutline
  var key: VectorGlyphMaskAtlas.Key
  var width: Int
  var height: Int
  var origin: CGPoint
  // Signed device-pixel sub-pixel phase baked into this mask (the accumulate
  // kernel biases its sample grid by this). Zero for static (integer-cell) text.
  var subpixelSampleOffset: CGPoint = .zero
}

public final class VectorGlyphRenderer: RendererBackend {
  private static let syntheticItalicShear: CGFloat = 0.18
  private static let maxInlineInstanceBytes = 4096

  public private(set) var fontAtlas: FontAtlas
  public private(set) var sidebarFontAtlas: FontAtlas

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let layer: CAMetalLayer
  private let solidPipeline: MTLRenderPipelineState
  private let glyphCoveragePipeline: MTLRenderPipelineState
  private let glyphColorPipeline: MTLRenderPipelineState
  private let rasterGlyphPipeline: MTLRenderPipelineState
  private let colorGlyphPipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  /// Bilinear sampler for the vector glyph atlas. Fluid smooth-scroll places the
  /// quad at a fractional device-pixel position, so the mask must interpolate to
  /// glide; static / per-phase placement lands on integer pixels where bilinear
  /// equals nearest, so it stays crisp. Raster/emoji atlases keep `sampler`.
  private let linearSampler: MTLSamplerState
  private let scratchRasterizer: VectorGlyphScratchRasterizer
  private let curveStore = GlyphCurveStore()

  private var pixelWidth: Int
  private var pixelHeight: Int
  private var scale: CGFloat
  private var targetTexture: MTLTexture?
  private var atlasTexture: MTLTexture?
  private var accumTexture: MTLTexture?
  public private(set) var subpixelLayout: VectorSubpixelLayout = .grayscale
  private var displayDownsampled = false
  /// Sub-cell scroll offset for the current frame, in *points* (the FrameProducer
  /// coordinate space). The vector path renders glyphs at this true fractional
  /// position via per-phase masks (M4) instead of snapping to the pixel grid, so
  /// smooth scrolling glides instead of jumping. Zero when no scroll is in flight,
  /// which keeps static text on its single phase-0 mask (no regression).
  private var scrollPhaseOffset: CGPoint = .zero
  /// Layout actually rendered, after the display-condition auto-policy
  /// (grayscale fallback on scaled/non-integer-scale displays).
  var effectiveSubpixelLayout: VectorSubpixelLayout {
    VectorSubpixelLayout.effective(
      configured: subpixelLayout, scale: Double(scale), downsampled: displayDownsampled)
  }
  public private(set) var lastRasterFallbackGlyphs = 0
  private var lastCommandBuffer: MTLCommandBuffer?
  private var fontCache: [UInt32: (font: CTFont, boldFallback: Bool, italicFallback: Bool)] = [:]
  private var maskAtlas = VectorGlyphMaskAtlas()
  private var rasterAtlas: MetalGlyphAtlas?
  private var sidebarRasterAtlas: MetalGlyphAtlas?
  private var colorGlyphAtlas: ColorGlyphAtlas?
  private var emojiRenderingMode: EmojiRenderingMode = EmojiRenderingSettings.current()
  private var textWeight: Double = VectorTextWeightSettings.current()
  private var smoothScrollMode: VectorSmoothScrollMode = VectorSmoothScrollSettings.current()

  public var onFrameCompleted: (() -> Void)?
  public var rendererStatus: RendererStatus {
    RendererStatus(
      configuredRenderer: RendererSelection.vectorGlyph.rawValue,
      effectiveRenderer: RendererSelection.vectorGlyph.rawValue,
      rasterFallbackGlyphs: lastRasterFallbackGlyphs,
      vectorSubpixelLayout: effectiveSubpixelLayout.name)
  }

  public init?(
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil,
    pixelWidth: Int = 1,
    pixelHeight: Int = 1,
    scale: CGFloat = 1
  ) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue(),
      let scratchRasterizer = VectorGlyphScratchRasterizer(device: device)
    else { return nil }

    let options = MTLCompileOptions()
    if #available(macOS 15.0, *) {
      options.mathMode = .safe
    } else {
      options.fastMathEnabled = false
    }
    guard
      let url = LabanRendererResources.bundle?.url(
        forResource: "VectorGlyphShaders",
        withExtension: "metal"),
      let source = try? String(contentsOf: url, encoding: .utf8),
      let library = try? device.makeLibrary(source: source, options: options),
      let solidVertex = library.makeFunction(name: "vectorSolidVertex"),
      let solidFragment = library.makeFunction(name: "vectorSolidFragment"),
      let glyphVertex = library.makeFunction(name: "vectorGlyphVertex"),
      let glyphCoverageFragment = library.makeFunction(name: "vectorGlyphCoverageFragment"),
      let glyphColorFragment = library.makeFunction(name: "vectorGlyphColorFragment"),
      let rasterGlyphFragment = library.makeFunction(name: "vectorRasterGlyphFragment"),
      let colorGlyphFragment = library.makeFunction(name: "vectorColorGlyphFragment")
    else { return nil }

    let layer = CAMetalLayer()
    layer.device = device
    // sRGB target so the fixed-function blend composites coverage in linear
    // light (gamma-correct), instead of lerping in gamma-encoded space which
    // renders text the wrong weight. Vector-only: the classic renderer is not
    // a reference and is intentionally left on its existing path.
    layer.pixelFormat = .bgra8Unorm_srgb
    layer.framebufferOnly = false
    layer.contentsScale = max(scale, 1)
    layer.drawableSize = CGSize(width: max(1, pixelWidth), height: max(1, pixelHeight))
    layer.isOpaque = true
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
    layer.contentsGravity = .topLeft

    let solidDescriptor = MTLRenderPipelineDescriptor()
    solidDescriptor.label = "laban.vector.solid"
    solidDescriptor.vertexFunction = solidVertex
    solidDescriptor.fragmentFunction = solidFragment
    solidDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureAlphaBlend(solidDescriptor.colorAttachments[0])

    let glyphCoverageDescriptor = MTLRenderPipelineDescriptor()
    glyphCoverageDescriptor.label = "laban.vector.glyph-coverage"
    glyphCoverageDescriptor.vertexFunction = glyphVertex
    glyphCoverageDescriptor.fragmentFunction = glyphCoverageFragment
    glyphCoverageDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureSubpixelCoverageBlend(glyphCoverageDescriptor.colorAttachments[0])

    let glyphColorDescriptor = MTLRenderPipelineDescriptor()
    glyphColorDescriptor.label = "laban.vector.glyph-color"
    glyphColorDescriptor.vertexFunction = glyphVertex
    glyphColorDescriptor.fragmentFunction = glyphColorFragment
    glyphColorDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureAdditiveRGBPreserveAlphaBlend(glyphColorDescriptor.colorAttachments[0])

    let rasterGlyphDescriptor = MTLRenderPipelineDescriptor()
    rasterGlyphDescriptor.label = "laban.vector.raster-glyph"
    rasterGlyphDescriptor.vertexFunction = glyphVertex
    rasterGlyphDescriptor.fragmentFunction = rasterGlyphFragment
    rasterGlyphDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureAlphaBlend(rasterGlyphDescriptor.colorAttachments[0])

    let colorGlyphDescriptor = MTLRenderPipelineDescriptor()
    colorGlyphDescriptor.label = "laban.vector.color-glyph"
    colorGlyphDescriptor.vertexFunction = glyphVertex
    colorGlyphDescriptor.fragmentFunction = colorGlyphFragment
    colorGlyphDescriptor.colorAttachments[0]?.pixelFormat = layer.pixelFormat
    configureAlphaBlend(colorGlyphDescriptor.colorAttachments[0])

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .nearest
    samplerDescriptor.magFilter = .nearest
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge

    let linearSamplerDescriptor = MTLSamplerDescriptor()
    linearSamplerDescriptor.minFilter = .linear
    linearSamplerDescriptor.magFilter = .linear
    linearSamplerDescriptor.sAddressMode = .clampToEdge
    linearSamplerDescriptor.tAddressMode = .clampToEdge

    guard
      let solidPipeline = try? device.makeRenderPipelineState(descriptor: solidDescriptor),
      let glyphCoveragePipeline = try? device.makeRenderPipelineState(
        descriptor: glyphCoverageDescriptor),
      let glyphColorPipeline = try? device.makeRenderPipelineState(
        descriptor: glyphColorDescriptor),
      let rasterGlyphPipeline = try? device.makeRenderPipelineState(
        descriptor: rasterGlyphDescriptor),
      let colorGlyphPipeline = try? device.makeRenderPipelineState(
        descriptor: colorGlyphDescriptor),
      let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
      let linearSampler = device.makeSamplerState(descriptor: linearSamplerDescriptor)
    else { return nil }

    self.device = device
    self.queue = queue
    self.layer = layer
    self.solidPipeline = solidPipeline
    self.glyphCoveragePipeline = glyphCoveragePipeline
    self.glyphColorPipeline = glyphColorPipeline
    self.rasterGlyphPipeline = rasterGlyphPipeline
    self.colorGlyphPipeline = colorGlyphPipeline
    self.sampler = sampler
    self.linearSampler = linearSampler
    self.scratchRasterizer = scratchRasterizer
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas ?? fontAtlas
    self.pixelWidth = max(1, pixelWidth)
    self.pixelHeight = max(1, pixelHeight)
    self.scale = max(scale, 1)
    self.rasterAtlas = Self.makeRasterAtlas(device: device, fontAtlas: fontAtlas, scale: scale)
    self.sidebarRasterAtlas = Self.makeRasterAtlas(
      device: device,
      fontAtlas: sidebarFontAtlas ?? fontAtlas,
      scale: scale)
    self.colorGlyphAtlas = Self.makeColorGlyphAtlas(
      device: device,
      fontAtlas: fontAtlas,
      scale: scale)
  }

  private static let accumulationSampleCap = 512
  /// Total accumulation samples that *phased* (sub-pixel scroll) masks may newly
  /// encode in one frame, shared across all new phases that frame. Static glyphs
  /// are not charged against this: their settled first paint stays full quality.
  /// During active scroll many new phases appear at once, so each gets OSOR's
  /// front-loaded handful and converges to full quality once motion settles.
  private static let phasedSampleBudgetPerFrame = 256
  /// Free a mask after this many frames without a reference (keep-or-free sweep).
  private static let maskEvictionTTLFrames = 240
  /// Distinct sub-pixel phases the per-phase scroll mode quantizes to per device
  /// pixel (per axis). Coarse on purpose: a continuous scroll shares one offset
  /// across the whole screen each frame, so few phases means masks repeat and
  /// cache instead of thrashing the atlas. 4/pixel reads as smooth quarter-pixel
  /// steps. Must divide 256 (the u0.8 phase range).
  private static let phaseStepsPerPixel = 4
  private var remainingPhasedSampleBudget = 0

  private static func makeRasterAtlas(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    scale: CGFloat
  ) -> MetalGlyphAtlas? {
    let cellSize = fontAtlas.cellSize
    return MetalGlyphAtlas(
      device: device,
      cellWidth: cellSize.width,
      cellHeight: cellSize.height,
      descent: fontAtlas.descent,
      scale: scale)
  }

  private static func makeColorGlyphAtlas(
    device: MTLDevice,
    fontAtlas: FontAtlas,
    scale: CGFloat
  ) -> ColorGlyphAtlas? {
    let cellSize = fontAtlas.cellSize
    return ColorGlyphAtlas(
      device: device,
      cellWidth: cellSize.width,
      cellHeight: cellSize.height,
      descent: fontAtlas.descent,
      scale: scale)
  }

  public var surfaceWidth: Int { pixelWidth }
  public var surfaceHeight: Int { pixelHeight }
  public var surfaceScale: CGFloat { scale }
  public var presentationLayer: CALayer? { layer }
  public var presentationImage: CGImage? { nil }

  public var pngData: Data? {
    lastCommandBuffer?.waitUntilCompleted()
    guard let targetTexture else { return nil }
    let bytesPerRow = targetTexture.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * targetTexture.height)
    bytes.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      targetTexture.getBytes(
        base,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, targetTexture.width, targetTexture.height),
        mipmapLevel: 0)
    }

    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: targetTexture.width,
        height: targetTexture.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }
    return PNGEncoder.encode(image)
  }

  @discardableResult
  public func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> Bool {
    let pw = max(1, pixelWidth)
    let ph = max(1, pixelHeight)
    let newScale = max(scale, 1)
    let changed = pw != self.pixelWidth || ph != self.pixelHeight || newScale != self.scale
    let scaleChanged = newScale != self.scale
    guard changed else { return false }
    self.pixelWidth = pw
    self.pixelHeight = ph
    self.scale = newScale
    layer.contentsScale = newScale
    layer.drawableSize = CGSize(width: pw, height: ph)
    targetTexture = nil
    if scaleChanged {
      maskAtlas = VectorGlyphMaskAtlas()
      atlasTexture = nil
      accumTexture = nil
      rasterAtlas = Self.makeRasterAtlas(device: device, fontAtlas: fontAtlas, scale: newScale)
      sidebarRasterAtlas = Self.makeRasterAtlas(
        device: device,
        fontAtlas: sidebarFontAtlas,
        scale: newScale)
      colorGlyphAtlas = Self.makeColorGlyphAtlas(
        device: device,
        fontAtlas: fontAtlas,
        scale: newScale)
    }
    return true
  }

  public func reconfigureFonts(fontAtlas: FontAtlas, sidebarFontAtlas: FontAtlas? = nil) {
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas ?? fontAtlas
    fontCache.removeAll(keepingCapacity: true)
    maskAtlas = VectorGlyphMaskAtlas()
    atlasTexture = nil
    accumTexture = nil
    rasterAtlas = Self.makeRasterAtlas(device: device, fontAtlas: fontAtlas, scale: scale)
    sidebarRasterAtlas = Self.makeRasterAtlas(
      device: device,
      fontAtlas: self.sidebarFontAtlas,
      scale: scale)
    colorGlyphAtlas = Self.makeColorGlyphAtlas(device: device, fontAtlas: fontAtlas, scale: scale)
  }

  public func setSubpixelLayout(_ layout: VectorSubpixelLayout) {
    guard layout != subpixelLayout else { return }
    let previousEffective = effectiveSubpixelLayout
    subpixelLayout = layout
    if effectiveSubpixelLayout != previousEffective { resetMaskCaches() }
  }

  /// Set whether the display resamples the framebuffer (a "scaled" mode). When
  /// true, subpixel AA auto-disables (see `VectorSubpixelLayout.effective`).
  /// Set whether the display resamples the framebuffer (a "scaled" mode). When
  /// true, subpixel AA auto-disables (see `VectorSubpixelLayout.effective`).
  /// Returns whether the effective (rendered) layout changed, so the caller can
  /// repaint; an unchanged value (including a no-op toggle) returns false.
  @discardableResult
  public func setDisplayDownsampled(_ downsampled: Bool) -> Bool {
    guard downsampled != displayDownsampled else { return false }
    let previousEffective = effectiveSubpixelLayout
    displayDownsampled = downsampled
    let changed = effectiveSubpixelLayout != previousEffective
    if changed { resetMaskCaches() }
    return changed
  }

  /// Set the sub-cell scroll offset (in points) for the frames that follow, so
  /// the vector path renders glyphs at their true fractional position through
  /// per-phase masks. The app passes the unsnapped scroll remainder here while
  /// the classic path keeps the pixel-snapped offset. Pass `.zero` (the default
  /// once scrolling settles) to return to static phase-0 rendering.
  public func setScrollPhaseOffset(_ offset: CGPoint) {
    let resolved = offset.x.isFinite && offset.y.isFinite ? offset : .zero
    scrollPhaseOffset = resolved
  }

  private func resetMaskCaches() {
    maskAtlas = VectorGlyphMaskAtlas()
    atlasTexture = nil
    accumTexture = nil
  }

  public func refreshEmojiRenderingMode() {
    emojiRenderingMode = EmojiRenderingSettings.current()
  }

  public func refreshTextWeight() {
    textWeight = VectorTextWeightSettings.current()
  }

  public func refreshSmoothScrollMode() {
    let mode = VectorSmoothScrollSettings.current()
    guard mode != smoothScrollMode else { return }
    smoothScrollMode = mode
    // The two modes populate the atlas with different keys (fluid bakes a single
    // phase-0 mask per glyph; per-phase bakes one per phase). Drop the caches so
    // the next frame rebuilds under the new mode.
    resetMaskCaches()
  }

  func maskSnapshot(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool = false
  ) -> VectorGlyphMaskSnapshot? {
    guard
      let entry = rasterizedMaskForSnapshot(
        for: glyph,
        font: font,
        syntheticItalic: syntheticItalic)
    else { return nil }
    return VectorGlyphMaskSnapshot(
      glyph: glyph,
      width: entry.width,
      height: entry.height,
      origin: entry.origin,
      bytes: maskAtlas.bytes(for: entry))
  }

  @discardableResult
  public func render(_ commands: [FrameCommand], damage: RenderDamage) -> Bool {
    guard let target = ensureTargetTexture(),
      let commandBuffer = queue.makeCommandBuffer()
    else { return false }

    var retainedInstanceBuffers: [MTLBuffer] = []
    maskAtlas.beginFrame()
    remainingPhasedSampleBudget = Self.phasedSampleBudgetPerFrame
    lastRasterFallbackGlyphs = prepareGlyphResources(
      commands: commands,
      commandBuffer: commandBuffer)
    // Free masks not referenced for a while (mostly scroll sub-pixel phases that
    // churn through the atlas); static glyphs are touched every frame and survive.
    maskAtlas.evictUnused(olderThan: Self.maskEvictionTTLFrames)
    encode(
      commands: commands,
      into: target,
      commandBuffer: commandBuffer,
      retainedInstanceBuffers: &retainedInstanceBuffers)
    if let drawable = layer.nextDrawable() {
      encodeBlit(from: target, to: drawable.texture, commandBuffer: commandBuffer)
      commandBuffer.present(drawable)
    }

    let completion = onFrameCompleted
    let buffersToRetain = retainedInstanceBuffers
    commandBuffer.addCompletedHandler { _ in
      _ = buffersToRetain
      completion?()
    }
    commandBuffer.commit()
    lastCommandBuffer = commandBuffer
    return true
  }

  private func encode(
    commands: [FrameCommand],
    into target: MTLTexture,
    commandBuffer: MTLCommandBuffer,
    retainedInstanceBuffers: inout [MTLBuffer]
  ) {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = target
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }
    encoder.label = "laban.vector.content"

    var solids: [VectorSolidInstance] = []
    var glyphs: [VectorGlyphInstance] = []
    var rasterGlyphs: [VectorGlyphInstance] = []
    var sidebarRasterGlyphs: [VectorGlyphInstance] = []
    var colorGlyphs: [VectorGlyphInstance] = []
    var currentClip: CGRect? = nil

    func flush() {
      guard
        !solids.isEmpty || !glyphs.isEmpty || !rasterGlyphs.isEmpty
          || !sidebarRasterGlyphs.isEmpty || !colorGlyphs.isEmpty
      else { return }
      setScissor(currentClip, encoder: encoder)
      var uniforms = VectorUniforms(
        surfaceSizePixels: SIMD2<Float>(Float(pixelWidth), Float(pixelHeight)),
        scale: Float(scale))
      if !solids.isEmpty {
        encoder.setRenderPipelineState(solidPipeline)
        if setVertexInstances(solids, encoder: encoder, retainedBuffers: &retainedInstanceBuffers) {
          encoder.setVertexBytes(&uniforms, length: MemoryLayout<VectorUniforms>.stride, index: 1)
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: solids.count)
        }
        solids.removeAll(keepingCapacity: true)
      }
      if !glyphs.isEmpty, let atlasTexture {
        if setVertexInstances(glyphs, encoder: encoder, retainedBuffers: &retainedInstanceBuffers) {
          encoder.setVertexBytes(&uniforms, length: MemoryLayout<VectorUniforms>.stride, index: 1)
          encoder.setFragmentTexture(atlasTexture, index: 0)
          encoder.setFragmentSamplerState(linearSampler, index: 0)
          encoder.setRenderPipelineState(glyphCoveragePipeline)
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: glyphs.count)
          encoder.setRenderPipelineState(glyphColorPipeline)
          encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: glyphs.count)
        }
        glyphs.removeAll(keepingCapacity: true)
      }
      drawRasterGlyphs(
        &rasterGlyphs,
        atlas: rasterAtlas,
        encoder: encoder,
        uniforms: &uniforms,
        retainedInstanceBuffers: &retainedInstanceBuffers)
      drawRasterGlyphs(
        &sidebarRasterGlyphs,
        atlas: sidebarRasterAtlas,
        encoder: encoder,
        uniforms: &uniforms,
        retainedInstanceBuffers: &retainedInstanceBuffers)
      drawColorGlyphs(
        &colorGlyphs,
        atlas: colorGlyphAtlas,
        encoder: encoder,
        uniforms: &uniforms,
        retainedInstanceBuffers: &retainedInstanceBuffers)
    }

    for command in commands {
      switch command {
      case .clip(let rect):
        flush()
        currentClip = rect

      case .rect(let rect, let color, _),
        .cursor(let rect, let color),
        .selection(let rect, let color),
        .findMatch(let rect, let color),
        .findSelected(let rect, let color):
        solids.append(solid(rect: rect, color: color))

      case .glyphRun(
        let origin, let text, let foreground, let background, let attributes, let source,
        let underlineStyle, let underlineColor, _
      ):
        let atlas = source == .sidebar ? sidebarFontAtlas : fontAtlas
        appendGlyphRun(
          text,
          origin: origin,
          foreground: foreground,
          background: background,
          attributes: attributes,
          underlineStyle: underlineStyle,
          underlineColor: underlineColor,
          atlas: atlas,
          source: source,
          solids: &solids,
          glyphs: &glyphs,
          rasterGlyphs: &rasterGlyphs,
          sidebarRasterGlyphs: &sidebarRasterGlyphs,
          colorGlyphs: &colorGlyphs)

      case .texturedQuad:
        break
      }
    }
    flush()
    encoder.endEncoding()
  }

  private func drawRasterGlyphs(
    _ glyphs: inout [VectorGlyphInstance],
    atlas: MetalGlyphAtlas?,
    encoder: MTLRenderCommandEncoder,
    uniforms: inout VectorUniforms,
    retainedInstanceBuffers: inout [MTLBuffer]
  ) {
    guard !glyphs.isEmpty, let atlas else {
      glyphs.removeAll(keepingCapacity: true)
      return
    }
    encoder.setRenderPipelineState(rasterGlyphPipeline)
    if setVertexInstances(glyphs, encoder: encoder, retainedBuffers: &retainedInstanceBuffers) {
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<VectorUniforms>.stride, index: 1)
      encoder.setFragmentTexture(atlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: 6,
        instanceCount: glyphs.count)
    }
    glyphs.removeAll(keepingCapacity: true)
  }

  private func drawColorGlyphs(
    _ glyphs: inout [VectorGlyphInstance],
    atlas: ColorGlyphAtlas?,
    encoder: MTLRenderCommandEncoder,
    uniforms: inout VectorUniforms,
    retainedInstanceBuffers: inout [MTLBuffer]
  ) {
    guard !glyphs.isEmpty, let atlas else {
      glyphs.removeAll(keepingCapacity: true)
      return
    }
    encoder.setRenderPipelineState(colorGlyphPipeline)
    if setVertexInstances(glyphs, encoder: encoder, retainedBuffers: &retainedInstanceBuffers) {
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<VectorUniforms>.stride, index: 1)
      encoder.setFragmentTexture(atlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: 6,
        instanceCount: glyphs.count)
    }
    glyphs.removeAll(keepingCapacity: true)
  }

  private func setVertexInstances<Element>(
    _ instances: [Element],
    encoder: MTLRenderCommandEncoder,
    retainedBuffers: inout [MTLBuffer]
  ) -> Bool {
    let stride = MemoryLayout<Element>.stride
    let byteCount = instances.count.multipliedReportingOverflow(by: stride)
    guard !byteCount.overflow, byteCount.partialValue > 0 else { return false }

    return instances.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      if raw.count <= Self.maxInlineInstanceBytes {
        encoder.setVertexBytes(base, length: raw.count, index: 0)
        return true
      }
      guard
        let buffer = device.makeBuffer(
          bytes: base,
          length: raw.count,
          options: .storageModeShared)
      else { return false }
      retainedBuffers.append(buffer)
      encoder.setVertexBuffer(buffer, offset: 0, index: 0)
      return true
    }
  }

  private func prepareGlyphResources(
    commands: [FrameCommand],
    commandBuffer: MTLCommandBuffer
  ) -> Int {
    var rasterFallbackGlyphs = 0
    for command in commands {
      guard
        case .glyphRun(
          _,
          let text,
          _,
          _,
          let attributes,
          let source,
          _,
          _,
          _
        ) = command
      else {
        continue
      }
      let atlas = source == .sidebar ? sidebarFontAtlas : fontAtlas
      let variant = styledFontVariant(for: attributes, in: atlas)
      let font = variant.font
      let runWantsColor =
        source != .sidebar && emojiRenderingMode == .color
        && ColorGlyphSupport.mayContainColorGlyph(text: text, font: font)
      for cluster in text {
        if runWantsColor,
          ColorGlyphSupport.clusterMayBeColor(cluster),
          colorGlyphFallbackEntry(
            cluster: cluster,
            font: font,
            boldFallback: variant.boldFallback,
            italicFallback: variant.italicFallback) != nil
        {
          rasterFallbackGlyphs += 1
          continue
        }
        if let glyph = vectorGlyph(
          for: cluster,
          font: font,
          boldFallback: variant.boldFallback,
          italicFallback: variant.italicFallback),
          ensureResidentMaskForMode(
            for: glyph,
            font: font,
            syntheticItalic: variant.italicFallback,
            commandBuffer: commandBuffer) != nil
        {
          continue
        }
        guard !isBlankCluster(cluster) else { continue }
        if rasterFallbackEntry(
          cluster: cluster,
          font: font,
          boldFallback: variant.boldFallback,
          italicFallback: variant.italicFallback,
          source: source) != nil
        {
          rasterFallbackGlyphs += 1
        }
      }
    }
    return rasterFallbackGlyphs
  }

  private func appendGlyphRun(
    _ text: String,
    origin: CGPoint,
    foreground: UInt32,
    background: UInt32,
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    atlas: FontAtlas,
    source: FrameSource,
    solids: inout [VectorSolidInstance],
    glyphs: inout [VectorGlyphInstance],
    rasterGlyphs: inout [VectorGlyphInstance],
    sidebarRasterGlyphs: inout [VectorGlyphInstance],
    colorGlyphs: inout [VectorGlyphInstance]
  ) {
    let variant = styledFontVariant(for: attributes, in: atlas)
    let font = variant.font
    let cellAdvance = atlas.cellSize.width
    let baseline = origin.y + atlas.descent
    let coverageExponent = Self.coverageExponent(
      foreground: foreground, background: background, weight: textWeight)
    let runWantsColor =
      source != .sidebar && emojiRenderingMode == .color
      && ColorGlyphSupport.mayContainColorGlyph(text: text, font: font)
    for (cellIndex, cluster) in text.enumerated() {
      let position = CGPoint(
        x: origin.x + CGFloat(cellIndex) * cellAdvance,
        y: baseline)
      if runWantsColor,
        ColorGlyphSupport.clusterMayBeColor(cluster),
        let colorFallback = colorGlyphInstance(
          cluster: cluster,
          font: font,
          boldFallback: variant.boldFallback,
          italicFallback: variant.italicFallback,
          position: CGPoint(x: position.x, y: origin.y))
      {
        colorGlyphs.append(colorFallback)
        continue
      }
      if let glyph = vectorGlyph(
        for: cluster,
        font: font,
        boldFallback: variant.boldFallback,
        italicFallback: variant.italicFallback),
        let resolved = resolveDrawMask(
          for: glyph,
          font: font,
          syntheticItalic: variant.italicFallback)
      {
        glyphs.append(
          glyphInstance(
            mask: resolved.mask, position: position, color: foreground,
            coverageExponent: coverageExponent, slide: resolved.slide))
      } else if let fallback = rasterFallbackInstance(
        cluster: cluster,
        font: font,
        boldFallback: variant.boldFallback,
        italicFallback: variant.italicFallback,
        position: CGPoint(x: position.x, y: origin.y),
        color: foreground,
        source: source)
      {
        if source == .sidebar {
          sidebarRasterGlyphs.append(fallback)
        } else {
          rasterGlyphs.append(fallback)
        }
      }
    }

    appendDecorations(
      text: text,
      origin: origin,
      attributes: attributes,
      underlineStyle: underlineStyle,
      underlineColor: underlineColor,
      atlas: atlas,
      foreground: foreground,
      solids: &solids)
  }

  private func appendDecorations(
    text: String,
    origin: CGPoint,
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32?,
    atlas: FontAtlas,
    foreground: UInt32,
    solids: inout [VectorSolidInstance]
  ) {
    guard
      let layout = TextDecorationLayout.make(
        origin: origin,
        cellCount: text.count,
        attributes: attributes,
        underlineStyle: underlineStyle,
        cellAdvance: atlas.cellSize.width,
        cellHeight: atlas.cellSize.height,
        descent: atlas.descent,
        scale: scale)
    else { return }

    let underlineRGBA = underlineColor ?? foreground
    for rect in layout.underlineRects {
      solids.append(solid(rect: rect, color: underlineRGBA))
    }
    if !layout.curlyUnderlinePoints.isEmpty {
      for (start, end) in zip(
        layout.curlyUnderlinePoints,
        layout.curlyUnderlinePoints.dropFirst())
      {
        solids.append(
          solid(
            rect: CGRect(
              x: start.x,
              y: min(start.y, end.y),
              width: max(end.x - start.x, layout.thickness),
              height: max(layout.thickness, abs(end.y - start.y))),
            color: underlineRGBA))
      }
    }
    if let rect = layout.strikethroughRect {
      solids.append(solid(rect: rect, color: foreground))
    }
    if let rect = layout.overlineRect {
      solids.append(solid(rect: rect, color: foreground))
    }
  }

  private func maskDescriptor(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool = false,
    phaseOffset: CGPoint = .zero
  ) -> VectorMaskDescriptor? {
    guard var outline = curveStore.outline(for: glyph, font: font) else { return nil }
    if syntheticItalic {
      outline = outline.applying(
        CGAffineTransform(a: 1, b: 0, c: Self.syntheticItalicShear, d: 1, tx: 0, ty: 0))
    }
    let bounds = outline.bounds.integral.insetBy(dx: -1, dy: -1)
    let width = max(1, Int(ceil(bounds.width * scale)))
    let height = max(1, Int(ceil(bounds.height * scale)))
    let origin = CGPoint(x: floor(bounds.minX), y: floor(bounds.minY))
    // `phaseOffset` selects which mask this descriptor addresses: `.zero` is the
    // single phase-0 mask (used by fluid mode and as crisp's always-resident
    // fallback); a non-zero offset is a per-phase mask (crisp mode bakes the
    // sub-cell scroll offset into the coverage). Static frames pass `.zero`.
    let phase = Self.quantizedPhase(pointOffset: phaseOffset, scale: scale)
    let key = VectorGlyphMaskAtlas.Key(
      font: ObjectIdentifier(font),
      glyph: glyph,
      width: width,
      height: height,
      originX: Int(origin.x),
      originY: Int(origin.y),
      syntheticItalic: syntheticItalic,
      quantizedOffsetX: phase.qx,
      quantizedOffsetY: phase.qy)
    return VectorMaskDescriptor(
      outline: outline,
      key: key,
      width: width,
      height: height,
      origin: origin,
      subpixelSampleOffset: phase.sampleOffset)
  }

  /// Quantize a point-space sub-cell offset to a device-pixel u0.8 phase. Returns
  /// the quantized key fields (1/256 device px, wrapped to one pixel) and the
  /// matching signed device-pixel sample offset the accumulate kernel biases by.
  /// The kernel's pixelBase is Y-down within the mask while FrameProducer point Y
  /// is Y-up, so the y sample offset is negated to keep bake and placement aligned.
  static func quantizedPhase(
    pointOffset: CGPoint,
    scale: CGFloat
  ) -> (qx: Int, qy: Int, sampleOffset: CGPoint) {
    // `pointOffset` is the *signed sub-pixel remainder* (the fraction the app
    // rounds away when snapping the scroll offset to whole device pixels), so the
    // quad stays pixel-aligned (crisp, texel↔pixel 1:1) and the mask carries the
    // sub-pixel shift. Quantize the signed device-pixel remainder directly (NOT
    // frac(), which would wrap a −0.3 px phase to +0.7 px) to a *coarse* step:
    // `phaseStepsPerPixel` distinct phases across a pixel. Coarse is deliberate —
    // a continuous scroll sweeps one shared offset per frame, so fine steps (e.g.
    // 1/256) would mint a fresh mask for every glyph every frame, thrashing the
    // atlas (O(n²) eviction) with zero reuse. A handful of phases repeat across
    // frames, so masks cache and the per-frame rasterization stays bounded.
    // Clamp to ±0.5 px: a larger value means the caller failed to snap.
    let step = 256 / Self.phaseStepsPerPixel  // u0.8 units per phase bucket
    func quantize(_ devicePixels: Double) -> (q: Int, frac: Double) {
      let clamped = min(0.5, max(-0.5, devicePixels))
      let raw = Int((clamped * 256).rounded())
      let snapped = Int((Double(raw) / Double(step)).rounded()) * step
      return (snapped, Double(snapped) / 256.0)
    }
    let px = quantize(Double(pointOffset.x) * Double(scale))
    let py = quantize(Double(pointOffset.y) * Double(scale))
    // Kernel pixelBase is Y-down within the mask; FrameProducer point Y is Y-up,
    // so the y sample bias is negated to keep bake and on-screen placement aligned.
    return (px.q, py.q, CGPoint(x: px.frac, y: -py.frac))
  }

  private func cachedMask(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool = false,
    phaseOffset: CGPoint = .zero
  ) -> VectorGlyphMaskAtlas.Entry? {
    guard
      let descriptor = maskDescriptor(
        for: glyph,
        font: font,
        syntheticItalic: syntheticItalic,
        phaseOffset: phaseOffset)
    else { return nil }
    return maskAtlas.entry(for: descriptor.key)
  }

  /// Resolve the mask to draw for the active mode, and whether the draw should
  /// apply the fluid sub-pixel slide. Crisp mode prefers a resident per-phase
  /// mask (placed pixel-aligned, no slide); when that phase isn't resident yet
  /// (budget spent this frame), it falls back to the phase-0 mask drawn with the
  /// fluid slide — so the glyph still moves sub-pixel, just without the per-phase
  /// AA refinement until a later frame bakes it. Fluid mode always slides phase-0.
  private func resolveDrawMask(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool
  ) -> (mask: VectorGlyphMaskAtlas.Entry, slide: Bool)? {
    if smoothScrollMode == .perPhase, scrollPhaseOffset != .zero,
      let phased = cachedMask(
        for: glyph, font: font, syntheticItalic: syntheticItalic, phaseOffset: scrollPhaseOffset)
    {
      return (phased, false)
    }
    guard
      let base = cachedMask(for: glyph, font: font, syntheticItalic: syntheticItalic)
    else { return nil }
    return (base, true)
  }

  private func ensureResidentMask(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool = false,
    phaseOffset: CGPoint = .zero,
    budgetGated: Bool = false,
    commandBuffer: MTLCommandBuffer
  ) -> VectorGlyphMaskAtlas.Entry? {
    guard
      let descriptor = maskDescriptor(
        for: glyph,
        font: font,
        syntheticItalic: syntheticItalic,
        phaseOffset: phaseOffset)
    else { return nil }
    guard
      let resolvedTexture = ensureAtlasTexture(),
      let accumTexture = ensureAccumTexture()
    else { return nil }

    let existing = maskAtlas.entry(for: descriptor.key)
    let sampleStart = existing.map { maskAtlas.sampleCount(for: $0) } ?? 0
    let scheduled =
      budgetGated
      ? Self.phasedSamplesThisFrame(
        sampleStart: sampleStart, budgetRemaining: remainingPhasedSampleBudget)
      : Self.accumulationSamplesThisFrame(
        sampleStart: sampleStart, maskPixels: descriptor.width * descriptor.height)
    // A brand-new entry occupies an atlas slot eviction may have just recycled, so
    // its pixels are stale until rasterized once. If we cannot afford even one
    // sample this frame (the per-frame phased budget is spent), do NOT reserve it:
    // return nil so the caller falls back to the always-resident phase-0 mask.
    // This both avoids showing a recycled slot AND bounds per-frame bake work, so
    // a phase-boundary frame can't bake the whole screen at once (the crisp p95/
    // p99 spike). Already-resident entries are reused regardless of budget.
    if existing == nil && scheduled <= 0 { return nil }

    guard
      let entry = existing
        ?? maskAtlas.reserve(
          key: descriptor.key,
          width: descriptor.width,
          height: descriptor.height,
          origin: descriptor.origin)
    else { return nil }

    // Referenced this frame: keep it alive through the keep-or-free sweep.
    maskAtlas.touch(entry)

    guard sampleStart < Self.accumulationSampleCap else { return entry }
    let sampleCount = min(Self.accumulationSampleCap - sampleStart, scheduled)
    guard sampleCount > 0 else { return entry }
    if budgetGated { remainingPhasedSampleBudget -= sampleCount }
    guard
      scratchRasterizer.encodeAccumulate(
        outline: descriptor.outline,
        width: descriptor.width,
        height: descriptor.height,
        origin: descriptor.origin,
        rasterScale: scale,
        targetX: entry.x,
        targetY: entry.y,
        sampleStart: sampleStart,
        sampleCount: sampleCount,
        seed: accumulationSeed(glyph: glyph, font: font, descriptor: descriptor),
        subpixelLayout: effectiveSubpixelLayout,
        subpixelOffset: descriptor.subpixelSampleOffset,
        accumTexture: accumTexture,
        resolvedTexture: resolvedTexture,
        commandBuffer: commandBuffer)
    else {
      maskAtlas.remove(entry)
      return nil
    }
    maskAtlas.setSampleCount(sampleStart + sampleCount, for: entry)
    return entry
  }

  /// Make a usable mask resident for the active smooth-scroll mode. Fluid mode
  /// uses one phase-0 mask per glyph (sub-pixel motion is the draw-time slide).
  /// Crisp mode keeps the phase-0 mask resident as a guaranteed fallback AND
  /// tries to bake the per-phase mask within the per-frame budget; if the budget
  /// is spent, the phase-0 mask + fluid slide carries the glyph this frame so the
  /// bake cost stays bounded (no screen-wide bake burst at a phase boundary).
  /// Returns non-nil when at least the phase-0 mask is resident.
  @discardableResult
  private func ensureResidentMaskForMode(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool = false,
    commandBuffer: MTLCommandBuffer
  ) -> VectorGlyphMaskAtlas.Entry? {
    let base = ensureResidentMask(
      for: glyph,
      font: font,
      syntheticItalic: syntheticItalic,
      phaseOffset: .zero,
      budgetGated: false,
      commandBuffer: commandBuffer)
    guard smoothScrollMode == .perPhase, scrollPhaseOffset != .zero else { return base }
    // Best-effort per-phase mask (budget-gated). Failure is fine: the resident
    // phase-0 mask renders with the fluid slide for this glyph this frame.
    _ = ensureResidentMask(
      for: glyph,
      font: font,
      syntheticItalic: syntheticItalic,
      phaseOffset: scrollPhaseOffset,
      budgetGated: true,
      commandBuffer: commandBuffer)
    return base
  }

  static func accumulationSamplesThisFrame(sampleStart: Int, maskPixels: Int) -> Int {
    if sampleStart == 0 {
      return Self.accumulationSampleCap
    }
    if sampleStart < 128 { return 16 }
    if sampleStart < 256 { return 8 }
    return 4
  }

  /// Samples to encode this frame for a *phased* (sub-pixel scroll) mask, given
  /// the remaining per-frame phased budget. Front-loads OSOR-style (8 → 4 → 2 → 1)
  /// instead of a full 512 first paint, so a frame that introduces many new phases
  /// stays bounded; clamps to the budget but never below 1 while samples remain,
  /// so every referenced phase becomes resident (lower quality, not missing) and
  /// converges to the cap over subsequent settled frames.
  static func phasedSamplesThisFrame(sampleStart: Int, budgetRemaining: Int) -> Int {
    guard budgetRemaining > 0 else { return 0 }
    let ideal: Int
    if sampleStart == 0 {
      ideal = 8
    } else if sampleStart < 32 {
      ideal = 4
    } else if sampleStart < 128 {
      ideal = 2
    } else {
      ideal = 1
    }
    return min(ideal, budgetRemaining)
  }

  private func accumulationSeed(
    glyph: CGGlyph,
    font: CTFont,
    descriptor: VectorMaskDescriptor
  ) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    func mix(_ value: UInt32) {
      hash ^= value
      hash &*= 16_777_619
    }
    mix(UInt32(glyph))
    mix(UInt32(max(0, descriptor.width)))
    mix(UInt32(max(0, descriptor.height)))
    mix(UInt32(bitPattern: Int32(descriptor.key.originX)))
    mix(UInt32(bitPattern: Int32(descriptor.key.originY)))
    mix(descriptor.key.syntheticItalic ? 1 : 0)
    mix(UInt32(bitPattern: Int32(descriptor.key.quantizedOffsetX)))
    mix(UInt32(bitPattern: Int32(descriptor.key.quantizedOffsetY)))
    let pointSize = UInt32(max(0, Int((CTFontGetSize(font) * 256).rounded())))
    mix(pointSize)
    return hash == 0 ? 1 : hash
  }

  private func rasterizedMaskForSnapshot(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool = false
  ) -> VectorGlyphMaskAtlas.Entry? {
    guard
      let descriptor = maskDescriptor(
        for: glyph,
        font: font,
        syntheticItalic: syntheticItalic)
    else { return nil }
    guard
      let bytes = scratchRasterizer.rasterize(
        outline: descriptor.outline,
        width: descriptor.width,
        height: descriptor.height,
        origin: descriptor.origin,
        rasterScale: scale),
      let entry = maskAtlas.store(
        key: descriptor.key,
        width: descriptor.width,
        height: descriptor.height,
        origin: descriptor.origin,
        bytes: bytes)
    else { return nil }
    uploadMask(bytes: bytes, entry: entry)
    return entry
  }

  private func uploadMask(bytes: [UInt8], entry: VectorGlyphMaskAtlas.Entry) {
    guard let texture = ensureAtlasTexture() else { return }
    var rgba = [UInt8](repeating: 255, count: bytes.count * 4)
    for index in bytes.indices {
      let offset = index * 4
      rgba[offset] = bytes[index]
      rgba[offset + 1] = bytes[index]
      rgba[offset + 2] = bytes[index]
    }
    rgba.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      texture.replace(
        region: MTLRegionMake2D(entry.x, entry.y, entry.width, entry.height),
        mipmapLevel: 0,
        withBytes: base,
        bytesPerRow: entry.width * 4)
    }
  }

  private func solid(rect: CGRect, color: UInt32) -> VectorSolidInstance {
    VectorSolidInstance(
      origin: SIMD2<Float>(Float(rect.minX * scale), Float(rect.minY * scale)),
      size: SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale)),
      color: vectorColor(color))
  }

  private func glyphInstance(
    mask: VectorGlyphMaskAtlas.Entry,
    position: CGPoint,
    color: UInt32,
    coverageExponent: Float,
    slide: Bool
  ) -> VectorGlyphInstance {
    let rect = CGRect(
      x: position.x + mask.origin.x,
      y: position.y + mask.origin.y,
      width: CGFloat(mask.width) / scale,
      height: CGFloat(mask.height) / scale)
    // `slide` true: this is a phase-0 mask drawn at the true fractional position
    // (fluid mode, or crisp's fallback when the per-phase mask isn't baked yet);
    // the bilinear sampler interpolates so motion is continuous. `slide` false: a
    // per-phase mask whose sub-pixel offset is baked in, kept pixel-aligned.
    let fluidDeviceOffsetY = slide ? CGFloat(scrollPhaseOffset.y) * scale : 0
    return VectorGlyphInstance(
      origin: SIMD2<Float>(
        Float(rect.minX * scale),
        Float(rect.minY * scale + fluidDeviceOffsetY)),
      size: SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale)),
      uvOrigin: SIMD2<Float>(
        Float(mask.x) / Float(maskAtlas.width),
        Float(mask.y) / Float(maskAtlas.height)),
      uvSize: SIMD2<Float>(
        Float(mask.width) / Float(maskAtlas.width),
        Float(mask.height) / Float(maskAtlas.height)),
      color: vectorColor(color),
      coverageExponent: coverageExponent)
  }

  /// Stem-darkening exponent for vector coverage so weight matches CoreText-based
  /// renderers (whose glyph masks bake in stem darkening). Geometric coverage is
  /// otherwise too thin, especially for dark text on a light background where
  /// thin strokes wash out. Returns an exponent `e` for `coverage^e`; `e < 1`
  /// thickens. A base boost applies to all text; an extra boost applies when the
  /// foreground is darker than the background (dark-on-light).
  static func coverageExponent(
    foreground: UInt32,
    background: UInt32,
    weight: Double
  ) -> Float {
    let w = Float(min(max(weight, 0), 1))
    guard w > 0 else { return 1 }
    let lf = relativeLuma(foreground)
    let lb = relativeLuma(background)
    let base: Float = 0.35
    let directional: Float = 1.25 * max(0, lb - lf)
    let gamma = 1 + w * (base + directional)
    return 1 / gamma
  }

  static func relativeLuma(_ rgba: UInt32) -> Float {
    let r = Float((rgba >> 24) & 0xFF) / 255
    let g = Float((rgba >> 16) & 0xFF) / 255
    let b = Float((rgba >> 8) & 0xFF) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  private func rasterFallbackInstance(
    cluster: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool,
    position: CGPoint,
    color: UInt32,
    source: FrameSource
  ) -> VectorGlyphInstance? {
    guard
      let (entry, atlas) = rasterFallbackEntry(
        cluster: cluster,
        font: font,
        boldFallback: boldFallback,
        italicFallback: italicFallback,
        source: source)
    else { return nil }
    let rect = CGRect(
      x: position.x + entry.logicalOriginX,
      y: position.y,
      width: CGFloat(entry.pixelWidth) / scale,
      height: CGFloat(entry.pixelHeight) / scale)
    let atlasSize = Float(atlas.textureSize)
    return VectorGlyphInstance(
      origin: SIMD2<Float>(Float(rect.minX * scale), Float(rect.minY * scale)),
      size: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
      uvOrigin: SIMD2<Float>(Float(entry.originX) / atlasSize, Float(entry.originY) / atlasSize),
      uvSize: SIMD2<Float>(
        Float(entry.pixelWidth) / atlasSize,
        Float(entry.pixelHeight) / atlasSize),
      color: vectorColor(color),
      coverageExponent: 1)
  }

  private func colorGlyphInstance(
    cluster: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool,
    position: CGPoint
  ) -> VectorGlyphInstance? {
    guard
      let (entry, atlas) = colorGlyphFallbackEntry(
        cluster: cluster,
        font: font,
        boldFallback: boldFallback,
        italicFallback: italicFallback)
    else { return nil }
    let rect = CGRect(
      x: position.x + entry.logicalOriginX,
      y: position.y,
      width: CGFloat(entry.pixelWidth) / scale,
      height: CGFloat(entry.pixelHeight) / scale)
    let atlasSize = Float(atlas.textureSize)
    return VectorGlyphInstance(
      origin: SIMD2<Float>(Float(rect.minX * scale), Float(rect.minY * scale)),
      size: SIMD2<Float>(Float(entry.pixelWidth), Float(entry.pixelHeight)),
      uvOrigin: SIMD2<Float>(Float(entry.originX) / atlasSize, Float(entry.originY) / atlasSize),
      uvSize: SIMD2<Float>(
        Float(entry.pixelWidth) / atlasSize,
        Float(entry.pixelHeight) / atlasSize),
      color: SIMD4<Float>(1, 1, 1, 1),
      coverageExponent: 1)
  }

  private func colorGlyphFallbackEntry(
    cluster: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> (entry: ColorGlyphAtlas.Entry, atlas: ColorGlyphAtlas)? {
    guard let atlas = colorGlyphAtlas,
      let entry = atlas.entry(
        character: cluster,
        font: font,
        boldFallback: boldFallback,
        italicFallback: italicFallback)
    else { return nil }
    return (entry, atlas)
  }

  private func rasterFallbackEntry(
    cluster: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool,
    source: FrameSource
  ) -> (entry: MetalGlyphAtlas.Entry, atlas: MetalGlyphAtlas)? {
    let atlas = source == .sidebar ? sidebarRasterAtlas : rasterAtlas
    guard let atlas,
      let entry = atlas.entry(
        character: cluster,
        font: font,
        boldFallback: boldFallback,
        italicFallback: italicFallback)
    else { return nil }
    return (entry, atlas)
  }

  private func vectorGlyph(
    for character: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> CGGlyph? {
    guard !boldFallback else { return nil }
    guard !usesRasterFallbackByPolicy(character) else { return nil }
    return simpleGlyph(for: character, font: font)
  }

  private func usesRasterFallbackByPolicy(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1,
      let scalar = character.unicodeScalars.first
    else { return true }
    switch scalar.value {
    case 0x2500...0x257F, 0x2580...0x259F, 0xE000...0xF8FF:
      return true
    default:
      return false
    }
  }

  private func isBlankCluster(_ character: Character) -> Bool {
    !character.unicodeScalars.isEmpty
      && character.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 0x20, 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
          return true
        default:
          return false
        }
      }
  }

  private func setScissor(_ clip: CGRect?, encoder: MTLRenderCommandEncoder) {
    guard let clip else {
      encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
      return
    }
    let minX = max(0, Int(floor(clip.minX * scale)))
    let maxX = min(pixelWidth, Int(ceil(clip.maxX * scale)))
    let minY = max(0, Int(floor(CGFloat(pixelHeight) - clip.maxY * scale)))
    let maxY = min(pixelHeight, Int(ceil(CGFloat(pixelHeight) - clip.minY * scale)))
    guard maxX > minX, maxY > minY else {
      encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: 1, height: 1))
      return
    }
    encoder.setScissorRect(
      MTLScissorRect(
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY))
  }

  private func encodeBlit(
    from source: MTLTexture,
    to destination: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
    blit.label = "laban.vector.present-blit"
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

  private func ensureTargetTexture() -> MTLTexture? {
    if let targetTexture,
      targetTexture.width == pixelWidth,
      targetTexture.height == pixelHeight
    {
      return targetTexture
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: layer.pixelFormat,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor)
    texture?.label = "laban.vector.target"
    targetTexture = texture
    return texture
  }

  private func ensureAtlasTexture() -> MTLTexture? {
    if let atlasTexture { return atlasTexture }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: maskAtlas.width,
      height: maskAtlas.height,
      mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor)
    texture?.label = "laban.vector.mask-atlas"
    atlasTexture = texture
    return texture
  }

  private func ensureAccumTexture() -> MTLTexture? {
    if let accumTexture { return accumTexture }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Uint,
      width: maskAtlas.width,
      height: maskAtlas.height,
      mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    let texture = device.makeTexture(descriptor: descriptor)
    texture?.label = "laban.vector.accum-atlas"
    accumTexture = texture
    return texture
  }

  private func styledFont(for attributes: TextAttributes, in atlas: FontAtlas) -> CTFont {
    styledFontVariant(for: attributes, in: atlas).font
  }

  private func styledFontVariant(
    for attributes: TextAttributes,
    in atlas: FontAtlas
  ) -> (font: CTFont, boldFallback: Bool, italicFallback: Bool) {
    let attrKey = UInt32(attributes.intersection([.bold, .italic]).rawValue)
    let atlasBit: UInt32 = (atlas === fontAtlas) ? 0 : 0x1_0000
    let key = attrKey | atlasBit
    if let cached = fontCache[key] { return cached }
    let variant = atlas.styledFontVariant(
      bold: attributes.contains(.bold),
      italic: attributes.contains(.italic)
    )
    fontCache[key] = variant
    return variant
  }

  private func simpleGlyph(for character: Character, font: CTFont) -> CGGlyph? {
    guard character.unicodeScalars.count == 1,
      let scalar = character.unicodeScalars.first,
      scalar.value <= UInt32(UInt16.max)
    else { return nil }

    var codeUnit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &codeUnit, &glyph, 1), glyph != 0 else {
      return nil
    }
    return glyph
  }

  private func vectorColor(_ rgba: UInt32) -> SIMD4<Float> {
    // Linearize RGB so colors stored into the sRGB target round-trip correctly
    // and blends happen in linear light. Alpha stays linear.
    SIMD4<Float>(
      Self.srgbToLinear(Float((rgba >> 24) & 0xFF) / 255),
      Self.srgbToLinear(Float((rgba >> 16) & 0xFF) / 255),
      Self.srgbToLinear(Float((rgba >> 8) & 0xFF) / 255),
      Float(rgba & 0xFF) / 255)
  }

  private static func srgbToLinear(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }
}

private func configureAlphaBlend(_ attachment: MTLRenderPipelineColorAttachmentDescriptor?) {
  guard let attachment else { return }
  attachment.isBlendingEnabled = true
  attachment.rgbBlendOperation = .add
  attachment.alphaBlendOperation = .add
  attachment.sourceRGBBlendFactor = .one
  attachment.sourceAlphaBlendFactor = .one
  attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
  attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
}

private func configureSubpixelCoverageBlend(
  _ attachment: MTLRenderPipelineColorAttachmentDescriptor?
) {
  guard let attachment else { return }
  attachment.isBlendingEnabled = true
  attachment.rgbBlendOperation = .add
  attachment.alphaBlendOperation = .add
  attachment.sourceRGBBlendFactor = .zero
  attachment.destinationRGBBlendFactor = .oneMinusSourceColor
  attachment.sourceAlphaBlendFactor = .zero
  attachment.destinationAlphaBlendFactor = .one
}

private func configureAdditiveRGBPreserveAlphaBlend(
  _ attachment: MTLRenderPipelineColorAttachmentDescriptor?
) {
  guard let attachment else { return }
  attachment.isBlendingEnabled = true
  attachment.rgbBlendOperation = .add
  attachment.alphaBlendOperation = .add
  attachment.sourceRGBBlendFactor = .one
  attachment.destinationRGBBlendFactor = .one
  attachment.sourceAlphaBlendFactor = .zero
  attachment.destinationAlphaBlendFactor = .one
}
