import XCTest

@testable import LabanApp
@testable import LabanRenderer

/// A GPU frame's completion handler does three things: it publishes the frame to
/// the present link, it releases the one-frame-in-flight slot, and it wakes the
/// frame loop.
///
/// Without the wake a slow frame does not merely arrive late — it freezes the
/// window. Frames refused meanwhile (`previousFrameInFlight`) are never retried
/// on their own, and since the publish also happens in that completion handler,
/// the screen keeps showing whatever was presented *before* the slow frame until
/// some unrelated wake fires. With the display link parked that can be seconds.
/// Observed 2026-08-24: a tab-switch frame executed for 9.67 s and the window
/// kept showing the previous tab.
final class FrameCompletionWakeTests: XCTestCase {

  func testRefusedFramesWakeWhenCapacityFrees() {
    XCTAssertTrue(
      TerminalRenderGate.shouldWakeFrameLoopOnCompletion(consecutiveBackendRenderFailures: 1))
    XCTAssertTrue(
      TerminalRenderGate.shouldWakeFrameLoopOnCompletion(consecutiveBackendRenderFailures: 12))
  }

  /// The gate must be false when nothing was refused. A healthy pipeline
  /// completes a frame every tick, so an ungated wake would schedule another
  /// frame from every completion — an idle terminal spinning at GPU cadence,
  /// which is the no-progress loop this investigation started from.
  func testHealthyPipelineDoesNotRetrigger() {
    XCTAssertFalse(
      TerminalRenderGate.shouldWakeFrameLoopOnCompletion(consecutiveBackendRenderFailures: 0))
  }

  /// The counter the gate reads is cleared by any frame that renders, which is
  /// what makes the loop impossible: refuse → wake → render → counter clears →
  /// the next completion is silent.
  func testWakeIsSelfLimiting() {
    var failures = 3
    XCTAssertTrue(
      TerminalRenderGate.shouldWakeFrameLoopOnCompletion(consecutiveBackendRenderFailures: failures)
    )
    failures = 0  // a frame rendered
    XCTAssertFalse(
      TerminalRenderGate.shouldWakeFrameLoopOnCompletion(consecutiveBackendRenderFailures: failures)
    )
  }
}
