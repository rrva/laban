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

  // MARK: - Retention cap

  /// `dates[i]` is item `i`'s mtime; larger = newer. Returns the ids the policy
  /// would delete, sorted for stable comparison.
  private func prune(_ dates: [Int], keep: Int) -> [Int] {
    let captures = dates.enumerated().map {
      ($0.offset, Date(timeIntervalSince1970: TimeInterval($0.element)))
    }
    return MainThreadWatchdog.capturesToPrune(captures, keep: keep).sorted()
  }

  func testNothingPrunedWhenUnderCap() {
    XCTAssertEqual(prune([10, 20, 30], keep: 200), [])
  }

  func testNothingPrunedExactlyAtCap() {
    XCTAssertEqual(prune([10, 20, 30], keep: 3), [])
  }

  /// Oldest captures (smallest mtime) are deleted; the `keep` newest survive.
  func testPrunesOldestBeyondCap() {
    // ids 0..4 with mtimes 10,20,30,40,50 → keep 2 newest (ids 4,3),
    // delete ids 0,1,2.
    XCTAssertEqual(prune([10, 20, 30, 40, 50], keep: 2), [0, 1, 2])
  }

  func testKeepZeroDisablesPruning() {
    XCTAssertEqual(prune([10, 20, 30], keep: 0), [])
  }

  func testKeepOneRetainsOnlyNewest() {
    // newest is id 1 (mtime 99); everything else is pruned.
    XCTAssertEqual(prune([5, 99, 7, 3], keep: 1), [0, 2, 3])
  }
}
