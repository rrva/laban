import XCTest

@testable import LabanRenderer

/// `isGPUBackpressure` decides whether a failed GPU frame should be paced to the
/// next display-link tick (backpressure: the display hasn't drained a drawable,
/// or the previous frame is still in flight) instead of retried immediately on
/// the same main-loop turn. Immediate retry on backpressure spins against the
/// stall and amplifies one drawable-drain wait into a burst of failed frames.
final class RenderFailureReasonTests: XCTestCase {
  func testBackpressureReasonsArePaced() {
    XCTAssertTrue(RenderFailureReason.drawableUnavailable.isGPUBackpressure)
    XCTAssertTrue(RenderFailureReason.previousFrameInFlight.isGPUBackpressure)
  }

  func testTransientReasonsRetryImmediately() {
    XCTAssertFalse(RenderFailureReason.drawableSizeMismatch.isGPUBackpressure)
    XCTAssertFalse(RenderFailureReason.fullRedrawProducedNoContent.isGPUBackpressure)
    XCTAssertFalse(RenderFailureReason.commandBufferUnavailable.isGPUBackpressure)
    XCTAssertFalse(RenderFailureReason.targetTextureUnavailable.isGPUBackpressure)
  }

  /// Every GPU backend must report a failure reason. The host reads it through
  /// `RenderFailureReporting` to tell backpressure (wait) from a real failure
  /// (retry); a backend that reports nothing looks like a real failure and gets
  /// retried immediately and unboundedly, blocking the main thread in
  /// `MetalDrawableScheduler.beginFrame`'s 16 ms wait on every attempt. This is
  /// a type-level check on purpose: it fails the moment a new backend is added
  /// without adopting the protocol, with no Metal device required.
  func testEveryGPUBackendReportsFailureReasons() {
    let backends: [(String, Any.Type)] = [
      ("MetalRenderer", MetalRenderer.self),
      ("SlugGlyphRenderer", SlugGlyphRenderer.self),
      ("VectorGlyphRenderer", VectorGlyphRenderer.self),
    ]
    for (name, type) in backends {
      XCTAssertTrue(
        type is RenderFailureReporting.Type,
        "\(name) must conform to RenderFailureReporting")
    }
  }

  /// The software backend must NOT conform. `GPURenderFreezeDetector`'s gate is
  /// `backend is RenderFailureReporting`, so conformance is what decides which
  /// backends the no-progress detector watches; a synchronous CPU backend never
  /// exhibits the loop and would only add noise. This also proves the
  /// conformance check above discriminates rather than passing vacuously.
  func testSoftwareBackendDoesNotReportGPUFailureReasons() {
    XCTAssertFalse(
      (SoftwareBackend.self as Any.Type) is RenderFailureReporting.Type,
      "SoftwareBackend must stay outside the GPU no-progress detector's gate")
  }

  /// Every case must be classified — a new failure reason should force a
  /// deliberate pace-or-retry decision here rather than silently defaulting.
  func testEveryReasonIsClassified() {
    let all: [RenderFailureReason] = [
      .previousFrameInFlight, .commandBufferUnavailable, .targetTextureUnavailable,
      .fullRedrawProducedNoContent, .drawableUnavailable, .drawableSizeMismatch,
    ]
    let paced = all.filter { $0.isGPUBackpressure }
    XCTAssertEqual(Set(paced), [.previousFrameInFlight, .drawableUnavailable])
  }
}
