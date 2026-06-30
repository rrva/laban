import CoreGraphics
import CoreText
import Foundation
import Metal

public final class SlugGlyphSpike {
  public enum SlugSpikeMode: String, CaseIterable {
    case banded
    case unbanded
  }

  public struct SlugSpikePreparedFrame {
    fileprivate let spikeTarget: MTLTexture
    fileprivate let spikeInstanceBuffer: MTLBuffer
    public let spikeInstanceCount: Int
    public let spikePointSize: CGFloat
    public let spikePixelWidth: Int
    public let spikePixelHeight: Int
  }

  public struct SlugSpikeRenderSample {
    public let spikeCPUMilliseconds: Double
    public let spikeWallMilliseconds: Double
  }

  private struct SlugSpikeGPUCurve {
    var p0: SIMD2<Float>
    var p1: SIMD2<Float>
    var p2: SIMD2<Float>
  }

  private struct SlugSpikeGPUGlyph {
    var boundsMin: SIMD2<Float>
    var boundsMax: SIMD2<Float>
    var curveStart: UInt32
    var curveCount: UInt32
    var bandStart: UInt32
    var bandCount: UInt32
  }

  private struct SlugSpikeGPUBand {
    var indexStart: UInt32
    var indexCount: UInt32
  }

  private struct SlugSpikeGPUInstance {
    var originPx: SIMD2<Float>
    var sizePx: SIMD2<Float>
    var localMin: SIMD2<Float>
    var localMax: SIMD2<Float>
    var color: SIMD4<Float>
    var glyphIndex: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
  }

  private struct SlugSpikeGPUUniforms {
    var surfaceSizePixels: SIMD2<Float>
  }

  private struct SlugSpikeGlyphEntry {
    var scalarValue: UInt32
    var outline: GlyphCurveOutline
    var glyphIndex: Int
  }

  private static let spikeBandCount = 32
  private static let spikeReferencePointSize: CGFloat = 14

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let spikeBandedPipeline: MTLRenderPipelineState
  private let spikeUnbandedPipeline: MTLRenderPipelineState
  private let referenceFont: CTFont
  private let curveStore = GlyphCurveStore()

  private var spikeEntriesByScalar: [UInt32: SlugSpikeGlyphEntry] = [:]
  private var spikeCurves: [SlugSpikeGPUCurve] = []
  private var spikeGlyphs: [SlugSpikeGPUGlyph] = []
  private var spikeBands: [SlugSpikeGPUBand] = []
  private var spikeBandIndices: [UInt32] = []

  private var spikeCurveBuffer: MTLBuffer?
  private var spikeGlyphBuffer: MTLBuffer?
  private var spikeBandBuffer: MTLBuffer?
  private var spikeBandIndexBuffer: MTLBuffer?
  private var spikeBuffersDirty = false

  public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    guard let device else { return nil }
    guard let queue = device.makeCommandQueue() else { return nil }

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
      let vertex = library.makeFunction(name: "slugGlyphVertexSpike"),
      let banded = library.makeFunction(name: "slugGlyphBandFragmentSpike"),
      let unbanded = library.makeFunction(name: "slugGlyphNoBandFragmentSpike"),
      let spikeBandedPipeline = Self.spikeMakePipeline(
        device: device,
        vertex: vertex,
        fragment: banded,
        label: "laban.slug-spike.banded"),
      let spikeUnbandedPipeline = Self.spikeMakePipeline(
        device: device,
        vertex: vertex,
        fragment: unbanded,
        label: "laban.slug-spike.unbanded")
    else { return nil }

    self.device = device
    self.queue = queue
    self.spikeBandedPipeline = spikeBandedPipeline
    self.spikeUnbandedPipeline = spikeUnbandedPipeline
    self.referenceFont = FontAtlas(pointSize: Self.spikeReferencePointSize, fontName: nil).font
  }

  public static func spikeASCIIText(cols: Int, rows: Int) -> [String] {
    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    let doubled = ascii + ascii + ascii
    var lines: [String] = []
    lines.reserveCapacity(rows)
    for row in 0..<rows {
      let start = (row * 7) % ascii.count
      let from = doubled.index(doubled.startIndex, offsetBy: start)
      lines.append(String(doubled[from...].prefix(cols)))
    }
    return lines
  }

  public func spikeReferenceOutline(for scalar: Unicode.Scalar) -> GlyphCurveOutline? {
    spikeEnsureGlyph(for: scalar)?.outline
  }

  public func makeSpikePreparedFrame(
    rows textRows: [String],
    pointSize: CGFloat,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    scale: CGFloat,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> SlugSpikePreparedFrame? {
    guard pointSize > 0, cellWidth > 0, cellHeight > 0, scale > 0 else { return nil }
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }

    let atlas = FontAtlas(pointSize: pointSize, fontName: nil)
    let pointScale = pointSize / Self.spikeReferencePointSize
    let baselineOffset = max(CGFloat(0), (cellHeight - atlas.cellSize.height) / 2) + atlas.descent

    var instances: [SlugSpikeGPUInstance] = []
    instances.reserveCapacity(textRows.reduce(0) { $0 + $1.unicodeScalars.count })

    for (rowIndex, row) in textRows.enumerated() {
      var colIndex = 0
      for scalar in row.unicodeScalars {
        defer { colIndex += 1 }
        guard let entry = spikeEnsureGlyph(for: scalar) else { continue }
        let bounds = entry.outline.bounds
        let cellOriginX = CGFloat(colIndex) * cellWidth
        let baselineY = CGFloat(rowIndex) * cellHeight + baselineOffset
        let localMin = SIMD2<Float>(Float(bounds.minX), Float(bounds.minY))
        let localMax = SIMD2<Float>(Float(bounds.maxX), Float(bounds.maxY))
        let origin = SIMD2<Float>(
          Float((cellOriginX + bounds.minX * pointScale) * scale),
          Float((baselineY + bounds.minY * pointScale) * scale))
        let size = SIMD2<Float>(
          max(0, Float(bounds.width * pointScale * scale)),
          max(0, Float(bounds.height * pointScale * scale)))
        guard size.x > 0, size.y > 0 else { continue }
        instances.append(
          SlugSpikeGPUInstance(
            originPx: origin,
            sizePx: size,
            localMin: localMin,
            localMax: localMax,
            color: SIMD4<Float>(0.92, 0.92, 0.92, 1),
            glyphIndex: UInt32(entry.glyphIndex)))
      }
    }

    guard !instances.isEmpty else { return nil }
    guard spikeEnsureBuffers() else { return nil }
    guard let instanceBuffer = spikeMakeBuffer(instances) else { return nil }
    guard
      let texture = spikeMakeTexture(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        storageMode: .private)
    else { return nil }

    return SlugSpikePreparedFrame(
      spikeTarget: texture,
      spikeInstanceBuffer: instanceBuffer,
      spikeInstanceCount: instances.count,
      spikePointSize: pointSize,
      spikePixelWidth: pixelWidth,
      spikePixelHeight: pixelHeight)
  }

  public func renderSpikeFrame(
    _ frame: SlugSpikePreparedFrame,
    mode: SlugSpikeMode,
    waitUntilCompleted: Bool = true,
    clearAlpha: Double = 1
  ) -> SlugSpikeRenderSample? {
    guard frame.spikeInstanceCount > 0 else { return nil }
    guard
      let commandBuffer = queue.makeCommandBuffer(),
      let curveBuffer = spikeCurveBuffer,
      let glyphBuffer = spikeGlyphBuffer,
      let bandBuffer = spikeBandBuffer,
      let bandIndexBuffer = spikeBandIndexBuffer
    else { return nil }

    let start = DispatchTime.now().uptimeNanoseconds
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = frame.spikeTarget
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: 0.02,
      green: 0.02,
      blue: 0.02,
      alpha: clearAlpha)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      return nil
    }
    encoder.label = "laban.slug-spike.render"
    encoder.setRenderPipelineState(mode == .banded ? spikeBandedPipeline : spikeUnbandedPipeline)
    encoder.setVertexBuffer(frame.spikeInstanceBuffer, offset: 0, index: 0)
    var uniforms = SlugSpikeGPUUniforms(
      surfaceSizePixels: SIMD2<Float>(
        Float(frame.spikePixelWidth),
        Float(frame.spikePixelHeight)))
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<SlugSpikeGPUUniforms>.stride, index: 1)
    encoder.setFragmentBuffer(curveBuffer, offset: 0, index: 0)
    encoder.setFragmentBuffer(glyphBuffer, offset: 0, index: 1)
    if mode == .banded {
      encoder.setFragmentBuffer(bandBuffer, offset: 0, index: 2)
      encoder.setFragmentBuffer(bandIndexBuffer, offset: 0, index: 3)
    }
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: 6,
      instanceCount: frame.spikeInstanceCount)
    encoder.endEncoding()
    commandBuffer.commit()
    let committed = DispatchTime.now().uptimeNanoseconds
    if waitUntilCompleted {
      commandBuffer.waitUntilCompleted()
      guard commandBuffer.error == nil else { return nil }
    }
    let end = DispatchTime.now().uptimeNanoseconds
    return SlugSpikeRenderSample(
      spikeCPUMilliseconds: Double(committed - start) / 1_000_000,
      spikeWallMilliseconds: Double(end - start) / 1_000_000)
  }

  public func spikeCoverageMask(
    for scalar: Unicode.Scalar,
    origin: CGPoint,
    width: Int,
    height: Int,
    mode: SlugSpikeMode = .banded
  ) -> [UInt8]? {
    guard width > 0, height > 0 else { return nil }
    guard let entry = spikeEnsureGlyph(for: scalar) else { return nil }
    guard spikeEnsureBuffers() else { return nil }
    guard
      let texture = spikeMakeTexture(
        pixelWidth: width,
        pixelHeight: height,
        storageMode: .shared)
    else { return nil }

    let instance = SlugSpikeGPUInstance(
      originPx: .zero,
      sizePx: SIMD2<Float>(Float(width), Float(height)),
      localMin: SIMD2<Float>(Float(origin.x), Float(origin.y)),
      localMax: SIMD2<Float>(Float(origin.x + CGFloat(width)), Float(origin.y + CGFloat(height))),
      color: SIMD4<Float>(1, 1, 1, 1),
      glyphIndex: UInt32(entry.glyphIndex))
    guard let instanceBuffer = spikeMakeBuffer([instance]) else { return nil }
    let frame = SlugSpikePreparedFrame(
      spikeTarget: texture,
      spikeInstanceBuffer: instanceBuffer,
      spikeInstanceCount: 1,
      spikePointSize: Self.spikeReferencePointSize,
      spikePixelWidth: width,
      spikePixelHeight: height)
    guard renderSpikeFrame(frame, mode: mode, waitUntilCompleted: true, clearAlpha: 0) != nil
    else { return nil }

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
      if let base = raw.baseAddress {
        texture.getBytes(
          base,
          bytesPerRow: width * 4,
          from: MTLRegionMake2D(0, 0, width, height),
          mipmapLevel: 0)
      }
    }
    var alpha = [UInt8](repeating: 0, count: width * height)
    for index in alpha.indices {
      alpha[index] = bytes[index * 4 + 3]
    }
    return alpha
  }

  private static func spikeMakePipeline(
    device: MTLDevice,
    vertex: MTLFunction,
    fragment: MTLFunction,
    label: String
  ) -> MTLRenderPipelineState? {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = label
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    spikeConfigureAlphaBlend(descriptor.colorAttachments[0])
    return try? device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func spikeConfigureAlphaBlend(
    _ attachment: MTLRenderPipelineColorAttachmentDescriptor?
  ) {
    guard let attachment else { return }
    attachment.isBlendingEnabled = true
    attachment.rgbBlendOperation = .add
    attachment.alphaBlendOperation = .add
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
  }

  private func spikeEnsureGlyph(for scalar: Unicode.Scalar) -> SlugSpikeGlyphEntry? {
    if let entry = spikeEntriesByScalar[scalar.value] { return entry }
    guard scalar.value <= UInt32(UInt16.max) else { return nil }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(referenceFont, &unit, &glyph, 1), glyph != 0 else {
      return nil
    }
    guard let outline = curveStore.outline(for: glyph, font: referenceFont) else { return nil }
    guard !outline.curves.isEmpty else { return nil }

    let glyphIndex = spikeGlyphs.count
    let curveStart = spikeCurves.count
    for curve in outline.curves {
      spikeCurves.append(
        SlugSpikeGPUCurve(
          p0: SIMD2<Float>(Float(curve.p0.x), Float(curve.p0.y)),
          p1: SIMD2<Float>(Float(curve.p1.x), Float(curve.p1.y)),
          p2: SIMD2<Float>(Float(curve.p2.x), Float(curve.p2.y))))
    }

    let bandStart = spikeBands.count
    spikeAppendBands(outline: outline, curveStart: curveStart)
    spikeGlyphs.append(
      SlugSpikeGPUGlyph(
        boundsMin: SIMD2<Float>(Float(outline.bounds.minX), Float(outline.bounds.minY)),
        boundsMax: SIMD2<Float>(Float(outline.bounds.maxX), Float(outline.bounds.maxY)),
        curveStart: UInt32(curveStart),
        curveCount: UInt32(outline.curves.count),
        bandStart: UInt32(bandStart),
        bandCount: UInt32(Self.spikeBandCount)))

    let entry = SlugSpikeGlyphEntry(
      scalarValue: scalar.value,
      outline: outline,
      glyphIndex: glyphIndex)
    spikeEntriesByScalar[scalar.value] = entry
    spikeBuffersDirty = true
    return entry
  }

  private func spikeAppendBands(outline: GlyphCurveOutline, curveStart: Int) {
    let minY = outline.bounds.minY
    let height = max(outline.bounds.height, .ulpOfOne)
    for band in 0..<Self.spikeBandCount {
      let bandMinY = minY + height * CGFloat(band) / CGFloat(Self.spikeBandCount)
      let bandMaxY = minY + height * CGFloat(band + 1) / CGFloat(Self.spikeBandCount)
      let indexStart = spikeBandIndices.count
      for (localIndex, curve) in outline.curves.enumerated()
      where spikeCurveIntersectsBand(curve, minY: bandMinY, maxY: bandMaxY) {
        spikeBandIndices.append(UInt32(curveStart + localIndex))
      }
      spikeBands.append(
        SlugSpikeGPUBand(
          indexStart: UInt32(indexStart),
          indexCount: UInt32(spikeBandIndices.count - indexStart)))
    }
  }

  private func spikeCurveIntersectsBand(
    _ curve: GlyphQuadraticCurve,
    minY: CGFloat,
    maxY: CGFloat
  ) -> Bool {
    let curveMinY = min(curve.p0.y, curve.p1.y, curve.p2.y)
    let curveMaxY = max(curve.p0.y, curve.p1.y, curve.p2.y)
    return curveMinY <= maxY && curveMaxY >= minY
  }

  private func spikeEnsureBuffers() -> Bool {
    guard spikeBuffersDirty || spikeCurveBuffer == nil else { return true }
    guard !spikeCurves.isEmpty, !spikeGlyphs.isEmpty else { return false }
    guard
      let curveBuffer = spikeMakeBuffer(spikeCurves),
      let glyphBuffer = spikeMakeBuffer(spikeGlyphs),
      let bandBuffer = spikeMakeBuffer(spikeBands),
      let bandIndexBuffer = spikeMakeBuffer(
        spikeBandIndices.isEmpty ? [UInt32(0)] : spikeBandIndices)
    else { return false }
    spikeCurveBuffer = curveBuffer
    spikeGlyphBuffer = glyphBuffer
    spikeBandBuffer = bandBuffer
    spikeBandIndexBuffer = bandIndexBuffer
    spikeBuffersDirty = false
    return true
  }

  private func spikeMakeBuffer<T>(_ values: [T]) -> MTLBuffer? {
    guard !values.isEmpty else { return nil }
    var copy = values
    let length = copy.count * MemoryLayout<T>.stride
    return copy.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return nil }
      return device.makeBuffer(bytes: base, length: length, options: .storageModeShared)
    }
  }

  private func spikeMakeTexture(
    pixelWidth: Int,
    pixelHeight: Int,
    storageMode: MTLStorageMode
  ) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = storageMode
    return device.makeTexture(descriptor: descriptor)
  }
}
