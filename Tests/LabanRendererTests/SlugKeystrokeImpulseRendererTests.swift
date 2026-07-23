import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// GPU contract for the keystroke-impulse type-in (kind 1): an expired stamp
/// must render bit-identical to no effect (the shader early-returns before
/// any transform arithmetic), and an active stamp must visibly transform the
/// glyph (compressed at arrival → fewer covered pixels) while reporting
/// liveness. Mirrors the `SlugSpinnerMotionRendererTests` harness.
final class SlugKeystrokeImpulseRendererTests: XCTestCase {
  private func makeRenderer() throws -> SlugGlyphRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 24),
        pixelWidth: 160,
        pixelHeight: 80,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.glyphEffectsEnabled = true
    return renderer
  }

  private func commands(stamp: Double?) -> [FrameCommand] {
    [
      .rect(
        CGRect(x: 0, y: 0, width: 160, height: 80),
        color: 0x0000_00FF,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 40, y: 20),
        text: "A",
        foreground: 0xFFFF_FFFF,
        background: 0x0000_0000,
        attributes: [],
        source: .terminal,
        outputTimestampSeconds: stamp),
    ]
  }

  private func nonBackgroundPixelCount(in image: RGBAImage) -> Int {
    var count = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = image.pixel(x: x, y: y)
        if pixel.r != 0 || pixel.g != 0 || pixel.b != 0 {
          count += 1
        }
      }
    }
    return count
  }

  func testExpiredKeystrokeImpulseRendersIdenticalToNoEffect() throws {
    // Age 8 s ≫ 0.130 s decay: the stamp is long settled, so the shader must
    // early-return and produce exactly the kind-0 pixels — this is the
    // contract that lets the 300 ms stamp-retention horizon outlive the
    // 130 ms visual effect without rounding drift.
    let expired = try makeRenderer()
    expired.glyphEffectClock = { 9.0 }
    XCTAssertTrue(expired.render(commands(stamp: 1.0), damage: .full))
    XCTAssertEqual(
      expired.glyphEffectLiveCount, 0,
      "an expired impulse must not count as a live effect")

    let plain = try makeRenderer()
    plain.glyphEffectClock = { 9.0 }
    XCTAssertTrue(plain.render(commands(stamp: nil), damage: .full))

    let expiredImage = try decodeRGBA(try XCTUnwrap(expired.pngData))
    let plainImage = try decodeRGBA(try XCTUnwrap(plain.pngData))
    XCTAssertEqual(expiredImage.width, plainImage.width)
    XCTAssertEqual(expiredImage.height, plainImage.height)
    XCTAssertEqual(
      expiredImage.bytes, plainImage.bytes,
      "expired kind-1 must be pixel-identical to kind 0")
  }

  func testActiveKeystrokeImpulseCompressesCoverageAndReportsLive() throws {
    let active = try makeRenderer()
    active.glyphEffectClock = { 1.0 }
    XCTAssertTrue(active.render(commands(stamp: 1.0), damage: .full))
    XCTAssertEqual(active.glyphEffectLiveCount, 1)
    XCTAssertEqual(active.lastGlyphEffectKind, SlugGlyphRenderer.glyphEffectKindKeystrokeImpulse)
    XCTAssertGreaterThan(active.glyphEffectAnimatingRemainingSeconds, 0)

    let settled = try makeRenderer()
    settled.glyphEffectClock = { 1.0 }
    XCTAssertTrue(settled.render(commands(stamp: nil), damage: .full))

    let activeImage = try decodeRGBA(try XCTUnwrap(active.pngData))
    let settledImage = try decodeRGBA(try XCTUnwrap(settled.pngData))
    let activeCount = nonBackgroundPixelCount(in: activeImage)
    let settledCount = nonBackgroundPixelCount(in: settledImage)
    XCTAssertGreaterThan(activeCount, 0, "the glyph must still render at arrival")
    XCTAssertLessThan(
      activeCount, settledCount,
      "arrival compression (scaleX 0.55) must cover fewer pixels than settled")
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
      let offset = (y * width + x) * 4
      return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw XCTSkip("failed to decode renderer PNG") }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: bitmapInfo)
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RGBAImage(width: width, height: height, bytes: bytes)
  }
}
