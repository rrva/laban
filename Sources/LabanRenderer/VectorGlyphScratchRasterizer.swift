import CoreGraphics
import Foundation
import Metal

public final class VectorGlyphScratchRasterizer {
  private struct GPUCurve {
    var p0: SIMD2<Float>
    var p1: SIMD2<Float>
    var p2: SIMD2<Float>
  }

  private struct GPUParams {
    var curveCount: UInt32
    var width: UInt32
    var height: UInt32
    var _pad0: UInt32 = 0
    var origin: SIMD2<Float>
    var boundsMin: SIMD2<Float>
    var boundsMax: SIMD2<Float>
    var rasterScale: Float
    var _pad1: Float = 0
  }

  private struct GPUAccumParams {
    var curveCount: UInt32
    var width: UInt32
    var height: UInt32
    var sampleStart: UInt32
    var sampleCount: UInt32
    var seed: UInt32
    var targetOrigin: SIMD2<UInt32>
    var origin: SIMD2<Float>
    var boundsMin: SIMD2<Float>
    var boundsMax: SIMD2<Float>
    var rasterScale: Float
    var _pad0: Float = 0
    var subpixelRBounds: SIMD4<Float>
    var subpixelGBounds: SIMD4<Float>
    var subpixelBBounds: SIMD4<Float>
    var subpixelOffset: SIMD2<Float>
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let scratchPipeline: MTLComputePipelineState
  private let accumPipeline: MTLComputePipelineState

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
      let scratchFunction = library.makeFunction(name: "vectorGlyphRasterizeScratch"),
      let accumFunction = library.makeFunction(name: "vectorGlyphAccumulateAtlas"),
      let scratchPipeline = try? device.makeComputePipelineState(function: scratchFunction),
      let accumPipeline = try? device.makeComputePipelineState(function: accumFunction)
    else { return nil }

    self.device = device
    self.queue = queue
    self.scratchPipeline = scratchPipeline
    self.accumPipeline = accumPipeline
  }

  public func rasterize(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint,
    rasterScale: CGFloat = 1
  ) -> [UInt8]? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm,
      width: width,
      height: height,
      mipmapped: false)
    descriptor.usage = [.shaderWrite, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
    guard
      encodeRasterize(
        outline: outline,
        width: width,
        height: height,
        origin: origin,
        rasterScale: rasterScale,
        targetX: 0,
        targetY: 0,
        into: texture,
        commandBuffer: commandBuffer)
    else { return nil }
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.error == nil else { return nil }

    var bytes = [UInt8](repeating: 0, count: width * height)
    bytes.withUnsafeMutableBytes { raw in
      if let base = raw.baseAddress {
        texture.getBytes(
          base,
          bytesPerRow: width,
          from: MTLRegionMake2D(0, 0, width, height),
          mipmapLevel: 0)
      }
    }
    return bytes
  }

  @discardableResult
  public func encodeRasterize(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint,
    rasterScale: CGFloat = 1,
    targetX: Int,
    targetY: Int,
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) -> Bool {
    guard width > 0, height > 0 else { return false }
    let resolvedScale = max(rasterScale, 1)
    guard resolvedScale.isFinite else { return false }
    guard width <= UInt32.max, height <= UInt32.max else { return false }
    guard targetX >= 0, targetY >= 0 else { return false }
    guard targetX + width <= texture.width, targetY + height <= texture.height else {
      return false
    }
    guard !outline.curves.isEmpty else { return false }
    guard let curveBuffer = makeCurveBuffer(outline: outline) else { return false }

    var params = GPUParams(
      curveCount: UInt32(outline.curves.count),
      width: UInt32(width),
      height: UInt32(height),
      origin: SIMD2<Float>(Float(origin.x), Float(origin.y)),
      boundsMin: SIMD2<Float>(Float(outline.bounds.minX), Float(outline.bounds.minY)),
      boundsMax: SIMD2<Float>(Float(outline.bounds.maxX), Float(outline.bounds.maxY)),
      rasterScale: Float(resolvedScale))
    var targetOrigin = SIMD2<UInt32>(UInt32(targetX), UInt32(targetY))

    guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
    encoder.label = "laban.vector-glyph-rasterize"
    encoder.setComputePipelineState(scratchPipeline)
    encoder.setBuffer(curveBuffer, offset: 0, index: 0)
    encoder.setBytes(&params, length: MemoryLayout<GPUParams>.stride, index: 1)
    encoder.setBytes(&targetOrigin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
    encoder.setTexture(texture, index: 0)

    let threadsPerGroup = MTLSize(
      width: min(16, scratchPipeline.threadExecutionWidth),
      height: max(1, min(16, scratchPipeline.maxTotalThreadsPerThreadgroup / 16)),
      depth: 1)
    let threads = MTLSize(width: width, height: height, depth: 1)
    encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
    encoder.endEncoding()
    return true
  }

  @discardableResult
  public func encodeAccumulate(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint,
    rasterScale: CGFloat = 1,
    targetX: Int,
    targetY: Int,
    sampleStart: Int,
    sampleCount: Int,
    seed: UInt32,
    subpixelLayout: VectorSubpixelLayout = .grayscale,
    subpixelOffset: CGPoint = .zero,
    accumTexture: MTLTexture,
    resolvedTexture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) -> Bool {
    guard width > 0, height > 0 else { return false }
    let resolvedScale = max(rasterScale, 1)
    guard resolvedScale.isFinite else { return false }
    guard width <= UInt32.max, height <= UInt32.max else { return false }
    guard targetX >= 0, targetY >= 0 else { return false }
    guard targetX + width <= accumTexture.width, targetY + height <= accumTexture.height else {
      return false
    }
    guard accumTexture.width == resolvedTexture.width,
      accumTexture.height == resolvedTexture.height
    else { return false }
    guard sampleStart >= 0, sampleCount > 0 else { return false }
    guard sampleStart <= UInt32.max, sampleCount <= UInt32.max else { return false }
    guard !outline.curves.isEmpty else { return false }
    guard let curveBuffer = makeCurveBuffer(outline: outline) else { return false }

    var params = GPUAccumParams(
      curveCount: UInt32(outline.curves.count),
      width: UInt32(width),
      height: UInt32(height),
      sampleStart: UInt32(sampleStart),
      sampleCount: UInt32(sampleCount),
      seed: seed,
      targetOrigin: SIMD2<UInt32>(UInt32(targetX), UInt32(targetY)),
      origin: SIMD2<Float>(Float(origin.x), Float(origin.y)),
      boundsMin: SIMD2<Float>(Float(outline.bounds.minX), Float(outline.bounds.minY)),
      boundsMax: SIMD2<Float>(Float(outline.bounds.maxX), Float(outline.bounds.maxY)),
      rasterScale: Float(resolvedScale),
      subpixelRBounds: subpixelLayout.rBounds,
      subpixelGBounds: subpixelLayout.gBounds,
      subpixelBBounds: subpixelLayout.bBounds,
      subpixelOffset: SIMD2<Float>(Float(subpixelOffset.x), Float(subpixelOffset.y)))

    guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
    encoder.label = "laban.vector-glyph-accumulate"
    encoder.setComputePipelineState(accumPipeline)
    encoder.setBuffer(curveBuffer, offset: 0, index: 0)
    encoder.setBytes(&params, length: MemoryLayout<GPUAccumParams>.stride, index: 1)
    encoder.setTexture(accumTexture, index: 0)
    encoder.setTexture(resolvedTexture, index: 1)

    let threadsPerGroup = MTLSize(
      width: min(16, accumPipeline.threadExecutionWidth),
      height: max(1, min(16, accumPipeline.maxTotalThreadsPerThreadgroup / 16)),
      depth: 1)
    let threads = MTLSize(width: width, height: height, depth: 1)
    encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
    encoder.endEncoding()
    return true
  }

  private func makeCurveBuffer(outline: GlyphCurveOutline) -> MTLBuffer? {
    let gpuCurves = outline.curves.map { curve in
      GPUCurve(
        p0: SIMD2<Float>(Float(curve.p0.x), Float(curve.p0.y)),
        p1: SIMD2<Float>(Float(curve.p1.x), Float(curve.p1.y)),
        p2: SIMD2<Float>(Float(curve.p2.x), Float(curve.p2.y)))
    }
    let curveBytes = gpuCurves.count * MemoryLayout<GPUCurve>.stride
    return gpuCurves.withUnsafeBytes {
      guard let base = $0.baseAddress else { return nil }
      return device.makeBuffer(bytes: base, length: curveBytes, options: .storageModeShared)
    }
  }
}
