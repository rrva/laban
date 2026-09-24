import CoreGraphics
import Foundation
import XCTest

@testable import LabanRenderer

/// `SoftwareRenderer` draws `texturedQuad`s from `FrameImageStore`
/// (execplans/active/kitty-graphics-rendering.md, Milestone 2).
final class SoftwareRendererImageTests: XCTestCase {
  /// Unique per test run so the shared store never collides with sessions.
  private var resourceId: UInt64 = 0

  override func setUp() {
    super.setUp()
    resourceId = UInt64.random(in: (1 << 62)...(UInt64.max - 1))
    // 2x2 straight RGBA: red, green / blue, white (top row first).
    let pixels: [UInt8] = [
      0xFF, 0, 0, 0xFF, 0, 0xFF, 0, 0xFF,
      0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    ]
    FrameImageStore.shared.put(
      FrameImage(width: 2, height: 2, rgba: Data(pixels)), for: resourceId)
  }

  override func tearDown() {
    FrameImageStore.shared.remove([resourceId])
    super.tearDown()
  }

  func testQuadDrawsImageUprightIntoRect() {
    let (surface, renderer) = makeRenderer()
    renderer.render([
      .texturedQuad(
        rect: CGRect(x: 0, y: 0, width: 40, height: 40), resourceId: resourceId,
        source: .image, layer: .aboveText, sourceRect: CGRect(x: 0, y: 0, width: 2, height: 2))
    ])
    // Surface pixels are bottom-left origin: the image's top row is at y 20...40.
    assertPixel(surface, x: 10, y: 30, is: 0xFF00_00FF)  // red, top-left
    assertPixel(surface, x: 30, y: 30, is: 0x00FF_00FF)  // green, top-right
    assertPixel(surface, x: 10, y: 10, is: 0x0000_FFFF)  // blue, bottom-left
    assertPixel(surface, x: 30, y: 10, is: 0xFFFF_FFFF)  // white, bottom-right
    assertPixel(surface, x: 50, y: 10, is: 0x0000_00FF)  // outside: untouched black
  }

  func testSourceRectCropsTheImage() {
    let (surface, renderer) = makeRenderer()
    // Only the image's top-right pixel (green), stretched over the rect.
    renderer.render([
      .texturedQuad(
        rect: CGRect(x: 0, y: 0, width: 40, height: 40), resourceId: resourceId,
        source: .image, layer: .aboveText, sourceRect: CGRect(x: 1, y: 0, width: 1, height: 1))
    ])
    assertPixel(surface, x: 5, y: 35, is: 0x00FF_00FF)
    assertPixel(surface, x: 35, y: 5, is: 0x00FF_00FF)
  }

  func testMissingImageDrawsNothing() {
    let (surface, renderer) = makeRenderer()
    renderer.render([
      .texturedQuad(
        rect: CGRect(x: 0, y: 0, width: 40, height: 40), resourceId: resourceId &+ 1,
        source: .image, layer: .aboveText, sourceRect: .null)
    ])
    assertPixel(surface, x: 20, y: 20, is: 0x0000_00FF)
  }

  private func makeRenderer() -> (BitmapSurface, SoftwareRenderer) {
    let surface = BitmapSurface(width: 64, height: 48)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 12))
    renderer.resetCanvas(to: 0x0000_00FF)
    return (surface, renderer)
  }

  private func assertPixel(
    _ surface: BitmapSurface, x: Int, y: Int, is expected: UInt32,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let actual = surface.pixel(x: x, y: y) else {
      return XCTFail("no pixel at \(x),\(y)", file: file, line: line)
    }
    let channels = { (v: UInt32) in [24, 16, 8, 0].map { Int((v >> UInt32($0)) & 0xFF) } }
    let delta = zip(channels(actual), channels(expected)).map { abs($0 - $1) }.max() ?? 0
    XCTAssertLessThanOrEqual(
      delta, 8,
      "pixel \(x),\(y) is \(String(format: "%08X", actual)), expected \(String(format: "%08X", expected))",
      file: file, line: line)
  }
}
