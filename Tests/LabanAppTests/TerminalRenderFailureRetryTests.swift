import XCTest

@testable import LabanApp
@testable import LabanCore

/// A frame the backend refuses is retried on the next main-loop turn, and every
/// non-scroll attempt can block the main thread for up to 16 ms inside
/// `MetalDrawableScheduler.beginFrame`. An unpaced retry of a failure that keeps
/// failing therefore leaves the main thread unavailable ~16 ms out of every
/// 17 ms — the shape observed in a live reproduction (2026-08-24), where the
/// render journal recorded 291 consecutive `backendRenderReturnedFalse` entries
/// for one frame across five seconds at ~57 attempts/second while tab clicks
/// took seconds to be serviced. `renderFailureRetryDelay` keeps the fast retry
/// for a transient miss and slows a repeating one to the parked link's cadence.
final class TerminalRenderFailureRetryTests: XCTestCase {

  func testTransientFailureRetriesOnNextMainLoopTurn() {
    XCTAssertEqual(TerminalRenderGate.renderFailureRetryDelay(consecutiveFailures: 1), 0)
    XCTAssertEqual(TerminalRenderGate.renderFailureRetryDelay(consecutiveFailures: 2), 0)
  }

  func testRepeatingFailureDropsToIdleCadence() {
    let paced = TerminalRenderGate.pacedRenderFailureRetrySeconds
    XCTAssertGreaterThan(paced, 0)
    XCTAssertEqual(TerminalRenderGate.renderFailureRetryDelay(consecutiveFailures: 3), paced)
    XCTAssertEqual(TerminalRenderGate.renderFailureRetryDelay(consecutiveFailures: 291), paced)
  }

  /// The paced cadence is the parked display link's own floor, so a stuck render
  /// costs about what an idle window costs rather than a busy main thread.
  func testPacedCadenceMatchesTheIdleDisplayLinkFloor() {
    XCTAssertEqual(
      TerminalRenderGate.pacedRenderFailureRetrySeconds,
      1.0 / TimeInterval(TerminalIdlePolicy.idleDisplayLinkFramesPerSecond))
  }

  /// A counter that never reset would slow every later frame to 8 Hz, so the
  /// boundary between "still immediate" and "now paced" must be exactly the
  /// documented threshold.
  func testImmediateWindowIsBoundedAndContiguous() {
    let threshold = TerminalRenderGate.immediateRenderFailureRetries
    XCTAssertGreaterThan(threshold, 0)
    for failures in 1...threshold {
      XCTAssertEqual(
        TerminalRenderGate.renderFailureRetryDelay(consecutiveFailures: failures), 0,
        "failure \(failures) should still retry immediately")
    }
    XCTAssertGreaterThan(
      TerminalRenderGate.renderFailureRetryDelay(consecutiveFailures: threshold + 1), 0)
  }
}
