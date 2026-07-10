import XCTest

@testable import LabanApp

final class WindowTitleThrottleTests: XCTestCase {
  private let intervalNs: UInt64 = 200_000_000

  func testIdenticalTitleIsNoOp() {
    var throttle = WindowTitleThrottle(minimumIntervalNs: intervalNs)
    XCTAssertEqual(throttle.decide(title: "laban", nowNs: 0), .apply)
    throttle.markApplied(title: "laban", nowNs: 0)

    XCTAssertEqual(throttle.decide(title: "laban", nowNs: 10), .none)
    XCTAssertEqual(throttle.decide(title: "laban", nowNs: intervalNs * 5), .none)
  }

  func testFirstChangeAppliesImmediately() {
    var throttle = WindowTitleThrottle(minimumIntervalNs: intervalNs)
    XCTAssertNil(throttle.lastAppliedTitle)
    XCTAssertEqual(throttle.decide(title: "laban", nowNs: 1_000), .apply)
  }

  func testBurstWithinIntervalCollapsesToLeadingApplyAndOneDefer() {
    var throttle = WindowTitleThrottle(minimumIntervalNs: intervalNs)

    // Leading edge: first title in the burst applies immediately.
    XCTAssertEqual(throttle.decide(title: "a", nowNs: 0), .apply)
    throttle.markApplied(title: "a", nowNs: 0)

    // Second title arrives 50ms later, well within the 200ms interval:
    // holds it and schedules a trailing apply for the remaining 150ms.
    let decision2 = throttle.decide(title: "b", nowNs: 50_000_000)
    XCTAssertEqual(decision2, .defer(afterNs: 150_000_000))

    // A third title arrives before the trailing apply has fired: a defer is
    // already pending, so this is a no-op. The pending trailing apply will
    // pick up whatever the caller recomposes as "current" when it fires;
    // the throttle itself never sees "c" here (recomposition is the view's
    // job), which is exactly why a second defer must not be scheduled.
    let decision3 = throttle.decide(title: "c", nowNs: 60_000_000)
    XCTAssertEqual(decision3, .none)
  }

  func testDeferPendingSuppressesFurtherDefers() {
    var throttle = WindowTitleThrottle(minimumIntervalNs: intervalNs)
    throttle.markApplied(title: "a", nowNs: 0)

    XCTAssertEqual(throttle.decide(title: "b", nowNs: 10_000_000), .defer(afterNs: 190_000_000))
    // Repeated changes while the defer is outstanding all collapse to .none,
    // regardless of how much (still-within-interval) time passes.
    XCTAssertEqual(throttle.decide(title: "c", nowNs: 20_000_000), .none)
    XCTAssertEqual(throttle.decide(title: "d", nowNs: 100_000_000), .none)
    XCTAssertEqual(throttle.decide(title: "a", nowNs: 150_000_000), .none)
  }

  func testPostIntervalChangeAppliesImmediatelyAgain() {
    var throttle = WindowTitleThrottle(minimumIntervalNs: intervalNs)
    throttle.markApplied(title: "a", nowNs: 0)

    // The trailing apply fired (simulated here directly via markApplied,
    // the way the view's asyncAfter handler would after recomposing).
    throttle.markApplied(title: "b", nowNs: intervalNs)

    // A title change a full interval after the last apply must not lag.
    XCTAssertEqual(throttle.decide(title: "c", nowNs: intervalNs * 2), .apply)
  }

  func testMarkAppliedUpdatesStateSoNextIdenticalTitleIsNone() {
    var throttle = WindowTitleThrottle(minimumIntervalNs: intervalNs)
    XCTAssertEqual(throttle.decide(title: "laban", nowNs: 0), .apply)
    throttle.markApplied(title: "laban", nowNs: 0)
    XCTAssertEqual(throttle.lastAppliedTitle, "laban")
    XCTAssertEqual(throttle.lastApplyNs, 0)

    // markApplied also clears any pending-defer latch, so a subsequent
    // distinct change inside the interval defers again rather than being
    // silently swallowed by a stale pending flag.
    let decision = throttle.decide(title: "laban — ● REC", nowNs: 10_000_000)
    XCTAssertEqual(decision, .defer(afterNs: 190_000_000))
    throttle.markApplied(title: "laban — ● REC", nowNs: 10_000_000)

    XCTAssertEqual(throttle.decide(title: "laban — ● REC", nowNs: 10_000_001), .none)
  }
}
