import Metal
import XCTest
@testable import LabanRenderer

final class SlugSpinnerMotionBench: XCTestCase {
  func testSixteenAnalyticMotionGlyphsUseOneMotionInstanceEach() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: 256,
        pixelHeight: 32,
        scale: 1))
    renderer.waitForFrameCompletion = true

    let start = SRGBRenderTargetColor.linearizedStraightRGBA(0xFF0000FF)
    let target: UInt32 = 0x0000FFFF
    let transition = GlyphForegroundTransition(
      startLinearRGBA: start,
      startTimestampSeconds: 1.0,
      durationSeconds: 0.5)
    let text = Array(repeating: "A", count: 16).joined()
    let commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: 256, height: 32),
        color: 0x000000FF,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 0, y: 0),
        text: text,
        foreground: target,
        background: 0x00000000,
        attributes: [],
        source: .terminal,
        foregroundTransition: transition),
    ]

    renderer.glyphEffectClock = { 1.0 }
    XCTAssertTrue(renderer.render(commands, damage: .full))
    XCTAssertEqual(renderer.lastFrameMotionGlyphsCount, 16)
    XCTAssertEqual(renderer.lastFrameSlugGlyphsCount, 0)
    XCTAssertEqual(renderer.glyphEffectLiveCount, 1)

    renderer.glyphEffectClock = { 1.25 }
    XCTAssertTrue(renderer.render(commands, damage: .full))
    XCTAssertEqual(renderer.lastFrameMotionGlyphsCount, 16)
    XCTAssertEqual(renderer.lastFrameSlugGlyphsCount, 0)
    XCTAssertEqual(renderer.glyphEffectAnimatingRemainingSeconds, 0.25, accuracy: 0.01)

    _ = renderer.pngData
  }
}
