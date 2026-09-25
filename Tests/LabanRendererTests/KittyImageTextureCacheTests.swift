import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// GPU textures follow the CPU image store: once the publisher retires an
/// image, renderers drop its texture instead of keeping it for the full
/// retention window (execplans/active/kitty-graphics-rendering.md).
final class KittyImageTextureCacheTests: XCTestCase {
  func testTextureIsDroppedOnceItsImageLeavesTheStore() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    let id = UInt64.random(in: (1 << 62)...(UInt64.max - 1))
    FrameImageStore.shared.put(
      FrameImage(width: 1, height: 1, rgba: Data([0xFF, 0, 0, 0xFF])), for: id)
    defer { FrameImageStore.shared.remove([id]) }
    let cache = KittyImageTextureCache(device: device)

    XCTAssertNotNil(cache.texture(for: id))
    FrameImageStore.shared.remove([id])
    cache.endFrame()
    XCTAssertEqual(cache.count, 1, "kept through the frame that used it")
    cache.endFrame()
    XCTAssertEqual(cache.count, 0, "dropped once unused and gone from the store")
  }

  func testUnusedTextureOfAStoredImageStaysForTheRetentionWindow() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    let id = UInt64.random(in: (1 << 62)...(UInt64.max - 1))
    FrameImageStore.shared.put(
      FrameImage(width: 1, height: 1, rgba: Data([0xFF, 0, 0, 0xFF])), for: id)
    defer { FrameImageStore.shared.remove([id]) }
    let cache = KittyImageTextureCache(device: device)

    XCTAssertNotNil(cache.texture(for: id))
    for _ in 0...KittyImageTextureCache.retentionFrames { cache.endFrame() }
    XCTAssertEqual(cache.count, 1)
    cache.endFrame()
    XCTAssertEqual(cache.count, 0)
  }
}
