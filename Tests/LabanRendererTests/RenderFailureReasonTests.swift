import XCTest

@testable import LabanRenderer

/// `isGPUBackpressure` decides whether a failed GPU frame should be paced to the
/// next display-link tick (backpressure: the display hasn't drained a drawable,
/// or the previous frame is still in flight) instead of retried immediately on
/// the same main-loop turn. Immediate retry on backpressure spins against the
/// stall and amplifies one drawable-drain wait into a burst of failed frames.
final class RenderFailureReasonTests: XCTestCase {
  func testBackpressureReasonsArePaced() {
    XCTAssertTrue(MetalRenderer.RenderFailureReason.drawableUnavailable.isGPUBackpressure)
    XCTAssertTrue(MetalRenderer.RenderFailureReason.previousFrameInFlight.isGPUBackpressure)
  }

  func testTransientReasonsRetryImmediately() {
    XCTAssertFalse(MetalRenderer.RenderFailureReason.drawableSizeMismatch.isGPUBackpressure)
    XCTAssertFalse(MetalRenderer.RenderFailureReason.fullRedrawProducedNoContent.isGPUBackpressure)
    XCTAssertFalse(MetalRenderer.RenderFailureReason.commandBufferUnavailable.isGPUBackpressure)
    XCTAssertFalse(MetalRenderer.RenderFailureReason.targetTextureUnavailable.isGPUBackpressure)
  }

  /// Every case must be classified — a new failure reason should force a
  /// deliberate pace-or-retry decision here rather than silently defaulting.
  func testEveryReasonIsClassified() {
    let all: [MetalRenderer.RenderFailureReason] = [
      .previousFrameInFlight, .commandBufferUnavailable, .targetTextureUnavailable,
      .fullRedrawProducedNoContent, .drawableUnavailable, .drawableSizeMismatch,
    ]
    let paced = all.filter { $0.isGPUBackpressure }
    XCTAssertEqual(Set(paced), [.previousFrameInFlight, .drawableUnavailable])
  }
}
