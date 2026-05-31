import XCTest

@testable import LabanApp

/// Policy tests for the main-thread watchdog's stall-vs-artifact decision.
/// These exercise `MainThreadWatchdog.decide` directly so the false-positive
/// guards are verified without a real stall or `/usr/bin/sample`.
final class MainThreadWatchdogTests: XCTestCase {

  private func decide(
    heartbeatAgeMs: Int,
    selfGapMs: Int = 50,
    sinceLastCaptureMs: Int = 10_000,
    thresholdMs: Int = 200,
    pauseGapMs: Int = 1000,
    cooldownMs: Int = 5000,
    maxStallMs: Int = 60_000
  ) -> MainThreadWatchdog.Decision {
    MainThreadWatchdog.decide(
      heartbeatAgeMs: heartbeatAgeMs,
      selfGapMs: selfGapMs,
      sinceLastCaptureMs: sinceLastCaptureMs,
      thresholdMs: thresholdMs,
      pauseGapMs: pauseGapMs,
      cooldownMs: cooldownMs,
      maxStallMs: maxStallMs)
  }

  func testBelowThresholdDoesNotCapture() {
    XCTAssertEqual(decide(heartbeatAgeMs: 100), .belowThreshold)
  }

  func testGenuineStallCaptures() {
    XCTAssertEqual(decide(heartbeatAgeMs: 350), .capture(stalledForMs: 350))
  }

  func testCooldownSuppressesRapidRecapture() {
    XCTAssertEqual(
      decide(heartbeatAgeMs: 350, sinceLastCaptureMs: 1000), .cooldown)
  }

  /// A multi-hour heartbeat gap that coincides with the watchdog timer *itself*
  /// being deferred (system sleep / App Nap) is an artifact, not a stall. This
  /// is the overnight-sleep false positive that dominated historical captures.
  func testPausedProcessIsNotAStall() {
    XCTAssertEqual(
      decide(heartbeatAgeMs: 9_999_162, selfGapMs: 9_999_000), .paused)
  }

  /// The pause guard wins even over the ceiling: a paused process must reset
  /// the baseline, not be silently dropped, so the next real stall is measured
  /// from a fresh heartbeat.
  func testPauseGuardTakesPrecedenceOverCeiling() {
    XCTAssertEqual(
      decide(heartbeatAgeMs: 10_000_000, selfGapMs: 5000), .paused)
  }

  /// The display link can stop on occlusion while the watchdog keeps ticking on
  /// its own queue (small self-gap). The ceiling drops the oversized gap.
  func testOversizedGapWithHealthyTimerHitsCeiling() {
    XCTAssertEqual(
      decide(heartbeatAgeMs: 120_000, selfGapMs: 50), .aboveCeiling)
  }

  func testCeilingDisabledAllowsLargeCapture() {
    XCTAssertEqual(
      decide(heartbeatAgeMs: 120_000, selfGapMs: 50, maxStallMs: 0),
      .capture(stalledForMs: 120_000))
  }

  /// Self-gap exactly at tolerance is not "paused": a real stall while the
  /// watchdog stayed on schedule still captures.
  func testSelfGapAtToleranceStillCaptures() {
    XCTAssertEqual(
      decide(heartbeatAgeMs: 800, selfGapMs: 1000), .capture(stalledForMs: 800))
  }
}
