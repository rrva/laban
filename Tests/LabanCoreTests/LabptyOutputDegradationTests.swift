import XCTest

@testable import LabanCore

final class LabptyOutputDegradationTests: XCTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

  func testUnmarkedTabIsNotDegraded() {
    let tracker = LabptyOutputDegradation(cooldown: 4)
    XCTAssertFalse(tracker.isDegraded("tab", now: t0))
  }

  func testRecencyWindowSelfClearsAfterCooldown() {
    var tracker = LabptyOutputDegradation(cooldown: 4)
    tracker.recordSkip("tab", at: t0)
    // Visible at the drop and through the cooldown...
    XCTAssertTrue(tracker.isDegraded("tab", now: t0))
    XCTAssertTrue(tracker.isDegraded("tab", now: t0.addingTimeInterval(3.9)))
    // ...then retires itself once the cooldown elapses, with no view required.
    XCTAssertFalse(tracker.isDegraded("tab", now: t0.addingTimeInterval(4)))
    XCTAssertFalse(tracker.isDegraded("tab", now: t0.addingTimeInterval(60)))
  }

  func testFreshSkipReArmsFromTheLatestDrop() {
    var tracker = LabptyOutputDegradation(cooldown: 4)
    tracker.recordSkip("tab", at: t0)
    // A second drop 3s into the window extends the live span from the new drop,
    // not the first — this is what keeps the badge steady during a burst.
    tracker.recordSkip("tab", at: t0.addingTimeInterval(3))
    XCTAssertTrue(tracker.isDegraded("tab", now: t0.addingTimeInterval(6.9)))
    XCTAssertFalse(tracker.isDegraded("tab", now: t0.addingTimeInterval(7)))
  }

  func testExplicitClearRetiresImmediatelyRegardlessOfCooldown() {
    var tracker = LabptyOutputDegradation(cooldown: 4)
    tracker.recordSkip("tab", at: t0)
    XCTAssertTrue(tracker.isDegraded("tab", now: t0))
    // The user views the tab: gone now, not after the cooldown.
    tracker.clear("tab")
    XCTAssertFalse(tracker.isDegraded("tab", now: t0))
  }

  func testTabsAreTrackedIndependently() {
    var tracker = LabptyOutputDegradation(cooldown: 4)
    tracker.recordSkip("a", at: t0)
    XCTAssertTrue(tracker.isDegraded("a", now: t0))
    // A skip on one tab must not light up a sibling.
    XCTAssertFalse(tracker.isDegraded("b", now: t0))
  }

  func testPruneDropsOnlyFullyElapsedEntries() {
    var tracker = LabptyOutputDegradation(cooldown: 4)
    tracker.recordSkip("stale", at: t0)
    tracker.recordSkip("fresh", at: t0.addingTimeInterval(3))
    // Prune at t0+5: "stale" (5s old) is gone, "fresh" (2s old) survives.
    tracker.pruneExpired(now: t0.addingTimeInterval(5))
    XCTAssertFalse(tracker.isDegraded("stale", now: t0.addingTimeInterval(3.5)))
    XCTAssertTrue(tracker.isDegraded("fresh", now: t0.addingTimeInterval(5)))
  }
}
