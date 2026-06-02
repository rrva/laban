import CoreGraphics
import Foundation
import Metal

final class MetalReadback {
  var captureMode = false

  private let device: MTLDevice
  private let pixelFormat: MTLPixelFormat
  private var texture: MTLTexture?

  init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
    self.device = device
    self.pixelFormat = pixelFormat
  }

  func invalidate() {
    texture = nil
  }

  func encodeIfNeeded(
    from source: MTLTexture,
    commandBuffer: MTLCommandBuffer,
    counterSampleBuffer: MTLCounterSampleBuffer?,
    counterBlitSupported: Bool
  ) -> Bool {
    guard captureMode else { return false }
    guard let destination = ensureTexture(width: source.width, height: source.height) else {
      return false
    }

    let descriptor = MTLBlitPassDescriptor()
    if counterBlitSupported, let counterSampleBuffer,
      let attachment = descriptor.sampleBufferAttachments[0]
    {
      attachment.sampleBuffer = counterSampleBuffer
      attachment.startOfEncoderSampleIndex = 6
      attachment.endOfEncoderSampleIndex = 7
    }

    guard let blit = commandBuffer.makeBlitCommandEncoder(descriptor: descriptor) else {
      return false
    }
    blit.label = "readback-blit"
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
    return true
  }

  @available(macOS 26, *)
  func renderTargetTexture(width: Int, height: Int) -> MTLTexture? {
    guard captureMode else { return nil }
    return ensureTexture(width: width, height: height)
  }

  func pngData(waitingFor commandBuffer: MTLCommandBuffer?) -> Data? {
    guard let texture else { return nil }
    // Capture / screenshot callers can read pngData any time; the GPU might
    // not have finished the most recent render yet. Block until it has so
    // we never serialize a stale frame.
    commandBuffer?.waitUntilCompleted()

    let width = texture.width
    let height = texture.height
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    bytes.withUnsafeMutableBytes { ptr in
      if let base = ptr.baseAddress {
        texture.getBytes(
          base,
          bytesPerRow: bytesPerRow,
          from: MTLRegionMake2D(0, 0, width, height),
          mipmapLevel: 0)
      }
    }

    let bitmapInfo: UInt32 =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard
      let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: width,
        height: height,
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

  private func ensureTexture(width: Int, height: Int) -> MTLTexture? {
    if let texture, texture.width == width, texture.height == height {
      return texture
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    texture = device.makeTexture(descriptor: descriptor)
    texture?.label = "readback"
    return texture
  }
}
