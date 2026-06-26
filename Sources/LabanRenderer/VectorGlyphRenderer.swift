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
  private let scratchRasterizer: VectorGlyphScratchRasterizer
  private let curveStore = GlyphCurveStore()

  private var pixelWidth: Int
  private var pixelHeight: Int
  private var scale: CGFloat
  private var targetTexture: MTLTexture?
  private var atlasTexture: MTLTexture?
  private var accumTexture: MTLTexture?
  public private(set) var subpixelLayout: VectorSubpixelLayout = .grayscale
  public private(set) var lastRasterFallbackGlyphs = 0
  private var lastCommandBuffer: MTLCommandBuffer?
  private var fontCache: [UInt32: (font: CTFont, boldFallback: Bool, italicFallback: Bool)] = [:]
  private var maskAtlas = VectorGlyphMaskAtlas()
  private var rasterAtlas: MetalGlyphAtlas?
  private var sidebarRasterAtlas: MetalGlyphAtlas?
  private var colorGlyphAtlas: ColorGlyphAtlas?
  private var emojiRenderingMode: EmojiRenderingMode = EmojiRenderingSettings.current()

  public var onFrameCompleted: (() -> Void)?
  public var rendererStatus: RendererStatus {
    RendererStatus(
      configuredRenderer: RendererSelection.vectorGlyph.rawValue,
      effectiveRenderer: RendererSelection.vectorGlyph.rawValue,
      rasterFallbackGlyphs: lastRasterFallbackGlyphs,
      vectorSubpixelLayout: subpixelLayout.name)
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
    layer.pixelFormat = .bgra8Unorm
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
      let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
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
    subpixelLayout = layout
    maskAtlas = VectorGlyphMaskAtlas()
    atlasTexture = nil
    accumTexture = nil
  }

  public func refreshEmojiRenderingMode() {
    emojiRenderingMode = EmojiRenderingSettings.current()
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
    lastRasterFallbackGlyphs = prepareGlyphResources(
      commands: commands,
      commandBuffer: commandBuffer)
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
          encoder.setFragmentSamplerState(sampler, index: 0)
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
        let origin, let text, let foreground, _, let attributes, let source,
        let underlineStyle, let underlineColor, _
      ):
        let atlas = source == .sidebar ? sidebarFontAtlas : fontAtlas
        appendGlyphRun(
          text,
          origin: origin,
          foreground: foreground,
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
          ensureResidentMask(
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
        let mask = cachedMask(
          for: glyph,
          font: font,
          syntheticItalic: variant.italicFallback)
      {
        glyphs.append(glyphInstance(mask: mask, position: position, color: foreground))
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
    syntheticItalic: Bool = false
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
    let key = VectorGlyphMaskAtlas.Key(
      font: ObjectIdentifier(font),
      glyph: glyph,
      width: width,
      height: height,
      originX: Int(origin.x),
      originY: Int(origin.y),
      syntheticItalic: syntheticItalic)
    return VectorMaskDescriptor(
      outline: outline,
      key: key,
      width: width,
      height: height,
      origin: origin)
  }

  private func cachedMask(
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
    return maskAtlas.entry(for: descriptor.key)
  }

  private func ensureResidentMask(
    for glyph: CGGlyph,
    font: CTFont,
    syntheticItalic: Bool = false,
    commandBuffer: MTLCommandBuffer
  ) -> VectorGlyphMaskAtlas.Entry? {
    guard
      let descriptor = maskDescriptor(
        for: glyph,
        font: font,
        syntheticItalic: syntheticItalic)
    else { return nil }
    guard
      let resolvedTexture = ensureAtlasTexture(),
      let accumTexture = ensureAccumTexture(),
      let entry = maskAtlas.entry(for: descriptor.key)
        ?? maskAtlas.reserve(
          key: descriptor.key,
          width: descriptor.width,
          height: descriptor.height,
          origin: descriptor.origin)
    else { return nil }

    let sampleStart = maskAtlas.sampleCount(for: entry)
    guard sampleStart < Self.accumulationSampleCap else { return entry }
    let sampleCount = min(
      Self.accumulationSampleCap - sampleStart,
      accumulationSamplesThisFrame(sampleStart: sampleStart))
    guard sampleCount > 0 else { return entry }
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
        subpixelLayout: subpixelLayout,
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

  private func accumulationSamplesThisFrame(sampleStart: Int) -> Int {
    if sampleStart == 0 { return 8 }
    if sampleStart < 64 { return 4 }
    if sampleStart < 256 { return 2 }
    return 1
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
    color: UInt32
  ) -> VectorGlyphInstance {
    let rect = CGRect(
      x: position.x + mask.origin.x,
      y: position.y + mask.origin.y,
      width: CGFloat(mask.width) / scale,
      height: CGFloat(mask.height) / scale)
    return VectorGlyphInstance(
      origin: SIMD2<Float>(Float(rect.minX * scale), Float(rect.minY * scale)),
      size: SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale)),
      uvOrigin: SIMD2<Float>(
        Float(mask.x) / Float(maskAtlas.width),
        Float(mask.y) / Float(maskAtlas.height)),
      uvSize: SIMD2<Float>(
        Float(mask.width) / Float(maskAtlas.width),
        Float(mask.height) / Float(maskAtlas.height)),
      color: vectorColor(color))
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
      color: vectorColor(color))
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
      color: SIMD4<Float>(1, 1, 1, 1))
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
    SIMD4<Float>(
      Float((rgba >> 24) & 0xFF) / 255,
      Float((rgba >> 16) & 0xFF) / 255,
      Float((rgba >> 8) & 0xFF) / 255,
      Float(rgba & 0xFF) / 255)
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
