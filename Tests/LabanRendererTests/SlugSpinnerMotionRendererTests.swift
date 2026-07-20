import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

final class SlugSpinnerMotionRendererTests: XCTestCase {
  func testMotionMidpointIsLinearLightMix() throws {
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

    let startPacked: UInt32 = 0xFF00_00FF
    let targetPacked: UInt32 = 0x0000_FFFF
    let transition = GlyphForegroundTransition(
      startLinearRGBA: SRGBRenderTargetColor.linearizedStraightRGBA(startPacked),
      startTimestampSeconds: 1.0,
      durationSeconds: 1.0)
    let commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: 160, height: 80),
        color: 0x0000_00FF,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 40, y: 20),
        text: "A",
        foreground: targetPacked,
        background: 0x0000_0000,
        attributes: [],
        source: .terminal,
        foregroundTransition: transition),
    ]

    renderer.glyphEffectClock = { 1.0 }
    XCTAssertTrue(renderer.render(commands, damage: .full))
    XCTAssertEqual(renderer.glyphEffectLiveCount, 1)
    XCTAssertEqual(renderer.lastFrameMotionGlyphsCount, 1)
    XCTAssertGreaterThan(renderer.glyphEffectAnimatingRemainingSeconds, 1.0 - 0.01)

    renderer.glyphEffectClock = { 1.5 }
    XCTAssertTrue(renderer.render(commands, damage: .full))
    XCTAssertEqual(renderer.glyphEffectLiveCount, 1)
    XCTAssertEqual(renderer.lastFrameMotionGlyphsCount, 1)
    XCTAssertEqual(renderer.glyphEffectAnimatingRemainingSeconds, 0.5, accuracy: 0.01)

    let image = try decodeRGBA(try XCTUnwrap(renderer.pngData))
    guard let covered = firstFullyCoveredPixel(in: image) else {
      XCTFail("no fully covered glyph pixel found")
      return
    }

    // Linear-light 50/50 red+blue is (0.5, 0, 0.5, 1), which encodes to
    // approximately 0xBC00BCFF — not the encoded-channel midpoint 0x800080FF.
    XCTAssertEqual(Int(covered.r), 0xBC, accuracy: 3)
    XCTAssertEqual(Int(covered.g), 0x00, accuracy: 3)
    XCTAssertEqual(Int(covered.b), 0xBC, accuracy: 3)
    XCTAssertEqual(Int(covered.a), 0xFF, accuracy: 3)
    XCTAssertNotEqual(Int(covered.r), 0x80, "midpoint must not be an encoded-channel mix")
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

  private func firstFullyCoveredPixel(in image: RGBAImage) -> (
    r: UInt8, g: UInt8, b: UInt8, a: UInt8
  )? {
    var best: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)?
    var bestSum: Int = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let pixel = image.pixel(x: x, y: y)
        if pixel.a == 0xFF, pixel.g < 0x20 {
          let sum = Int(pixel.r) + Int(pixel.b)
          if sum > bestSum {
            bestSum = sum
            best = pixel
          }
        }
      }
    }
    return best
  }
}
