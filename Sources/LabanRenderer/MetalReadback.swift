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

  func pixelSnapshot(waitingFor commandBuffer: MTLCommandBuffer?) -> RenderedPixelSnapshot? {
    guard let texture else { return nil }
    // Capture / screenshot callers can read pixels any time; the GPU might
    // not have finished the most recent render yet. Block until it has so
    // we never serialize a stale frame. Only the copy happens here — the PNG
    // deflate is left to the caller, which can run it off the main thread.
    commandBuffer?.waitUntilCompleted()
    return RenderedPixelSnapshot.read(from: texture)
  }

  func pngData(waitingFor commandBuffer: MTLCommandBuffer?) -> Data? {
    pixelSnapshot(waitingFor: commandBuffer)?.encodePNG()
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
