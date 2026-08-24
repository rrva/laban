import Metal
import XCTest

@testable import LabanRenderer

/// `VectorGlyphRenderer.render` returns `false` when it cannot draw. The host
/// reads `lastRenderFailureReason` to tell GPU backpressure (wait for the
/// pipeline) from a real failure (retry); when the reason is missing, every
/// refusal looks like a real failure and gets retried immediately and
/// unboundedly, blocking the main thread for up to 16 ms per attempt in
/// `MetalDrawableScheduler.beginFrame`. A live reproduction on 2026-08-24
/// recorded 291 consecutive refusals of one frame across five seconds this way.
final class VectorRenderFailureReasonTests: XCTestCase {

  private func makeRenderer() throws -> VectorGlyphRenderer {
    try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
    return try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14), pixelWidth: 64, pixelHeight: 64))
  }

  private var frame: [FrameCommand] {
    [.rect(CGRect(x: 0, y: 0, width: 64, height: 64), color: 0x1020_30FF, source: .terminal)]
  }

  /// Drive the same overload the host calls (`TerminalBitmapView`'s
  /// `renderSurfaceFrame`), which reaches `render(_:damage:)` through the
  /// `RendererBackend` extension — the reason must survive that hop.
  private func hostRender(_ renderer: VectorGlyphRenderer, damage: RenderDamage) -> Bool {
    renderer.render(frame, cellPayload: nil, damage: damage, rendererFallbackReason: nil)
  }

  func testSuccessfulRenderReportsNoFailureReason() throws {
    let renderer = try makeRenderer()
    XCTAssertTrue(hostRender(renderer, damage: .full))
    XCTAssertNil(renderer.lastRenderFailureReason)
  }

  /// Back-to-back frames saturate the one-frame-in-flight scheduler, which is
  /// the refusal the live reproduction hit. Every refusal must carry a reason,
  /// and a frame that succeeds must clear the previous one — a stale reason
  /// would misclassify the next failure.
  func testEveryRefusalCarriesAReasonAndSuccessClearsIt() throws {
    let renderer = try makeRenderer()
    var refusals = 0
    for _ in 0..<400 {
      // Opt into drop-don't-block so a busy pipeline refuses instead of waiting
      // out the 16 ms budget, the same flag the host sets for scroll frames.
      renderer.dropNextFrameWhenBusy = true
      if hostRender(renderer, damage: .partial(yRanges: [DirtyYRange(y: 0, height: 64)])) {
        XCTAssertNil(renderer.lastRenderFailureReason, "a rendered frame must clear the reason")
      } else {
        refusals += 1
        XCTAssertEqual(
          renderer.lastRenderFailureReason, .previousFrameInFlight,
          "a frame refused by the in-flight scheduler must report backpressure")
      }
    }
    XCTAssertGreaterThan(
      refusals, 0, "400 back-to-back frames should saturate the one-frame-in-flight scheduler")
  }
}
