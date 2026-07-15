import Metal
import XCTest

@testable import LabanRenderer

final class MetalRendererTransparencyTests: XCTestCase {
  func testClassicAndGPUDrivenKeepPartialDamageAtSeventyPercentAlpha() throws {
    for selection in [RendererSelection.classic, .gpuDriven] {
      let backend = try RendererTransparencyTestSupport.makeBackend(selection)
      _ = try RendererTransparencyTestSupport.renderImage(
        backend,
        commands: RendererTransparencyTestSupport.commands(),
        damage: .full)
      var image: TestRGBAImage?
      for _ in 0..<100 {
        image = try RendererTransparencyTestSupport.renderImage(
          backend,
          commands: RendererTransparencyTestSupport.commands(),
          damage: .partial(yRanges: [DirtyYRange(y: 0, height: 8)]))
      }
      RendererTransparencyTestSupport.assertSemanticAlpha(try XCTUnwrap(image))
    }
  }

  func testScrollStyleBlitPreservesPremultipliedAlphaBytes() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: 2,
      height: 1,
      mipmapped: false)
    descriptor.usage = [.shaderRead, .renderTarget]
    descriptor.storageMode = .shared
    let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    // BGRA premultiplied bytes; alpha is the 70% contract value.
    let sourceBytes: [UInt8] = [0x30, 0x20, 0x10, 179, 0x60, 0x40, 0x20, 179]
    sourceBytes.withUnsafeBytes { bytes in
      source.replace(
        region: MTLRegionMake2D(0, 0, 2, 1),
        mipmapLevel: 0,
        withBytes: bytes.baseAddress!,
        bytesPerRow: 8)
    }
    let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
    let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
    blit.copy(
      from: source,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: 2, height: 1, depth: 1),
      to: destination,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var copied = [UInt8](repeating: 0, count: 8)
    copied.withUnsafeMutableBytes { bytes in
      destination.getBytes(
        bytes.baseAddress!,
        bytesPerRow: 8,
        from: MTLRegionMake2D(0, 0, 2, 1),
        mipmapLevel: 0)
    }
    XCTAssertEqual(copied, sourceBytes)
  }
}
