import XCTest

@testable import LabanApp

final class PresentCadenceCheckTests: XCTestCase {
  /// Feed `seconds` of main ticks at `mainHz` while the present link adds
  /// `presentHz` callbacks a second; returns every verdict that was not `.keep`.
  private func run(
    _ check: inout PresentCadenceCheck, from start: TimeInterval = 0, seconds: Double,
    mainHz: Double = 120, presentHz: Double, presentBase: Int = 0, running: Bool = true
  ) -> [PresentCadenceCheck.Verdict] {
    var verdicts: [PresentCadenceCheck.Verdict] = []
    let ticks = Int(seconds * mainHz)
    for i in 0..<ticks {
      let t = start + Double(i) / mainHz
      let callbacks = presentBase + Int(Double(i) / mainHz * presentHz)
      let verdict = check.tick(at: t, presentCallbacks: callbacks, linksRunning: running)
      if verdict != .keep { verdicts.append(verdict) }
    }
    return verdicts
  }

  func testUnarmedNeverRefreshes() {
    var check = PresentCadenceCheck()
    XCTAssertEqual(run(&check, seconds: 10, presentHz: 30), [])
  }

  func testHealthyCadenceDisarmsWithoutRefreshing() {
    var check = PresentCadenceCheck()
    check.arm()
    XCTAssertEqual(run(&check, seconds: 5, presentHz: 120), [])
    XCTAssertFalse(check.armed)
  }

  /// The measured failure: main link 120/s, present link stuck at 60/s.
  func testHalfRatePresentLinkRefreshes() {
    var check = PresentCadenceCheck()
    check.arm()
    let verdicts = run(&check, seconds: 2.5, presentHz: 60)
    XCTAssertEqual(verdicts.count, 1)
    guard case .refresh(let ratio)? = verdicts.first else { return XCTFail("no refresh") }
    XCTAssertEqual(ratio, 0.5, accuracy: 0.02)
  }

  /// A present link slow for some other reason (not healed by a refresh) gets
  /// at most two refreshes, never a loop.
  func testStaysSlowGivesUpAfterTwoRefreshes() {
    var check = PresentCadenceCheck()
    check.arm()
    let verdicts = run(&check, seconds: 30, presentHz: 60)
    XCTAssertEqual(verdicts.count, PresentCadenceCheck.maximumRefreshes)
    XCTAssertFalse(check.armed)
  }

  /// A refreshed renderer brings a new link whose count restarts at zero;
  /// healthy after that, the check disarms.
  func testRecoveryAfterRefreshDisarms() {
    var check = PresentCadenceCheck()
    check.arm()
    XCTAssertEqual(run(&check, seconds: 2.5, presentHz: 60).count, 1)
    XCTAssertEqual(run(&check, from: 3, seconds: 5, presentHz: 120, presentBase: 0), [])
    XCTAssertFalse(check.armed)
    XCTAssertEqual(check.refreshesThisArming, 1)
  }

  /// Parked links or a hidden window are not evidence either way.
  func testParkedLinksNeverRefresh() {
    var check = PresentCadenceCheck()
    check.arm()
    XCTAssertEqual(run(&check, seconds: 10, presentHz: 0, running: false), [])
    XCTAssertTrue(check.armed, "still waiting for a real measurement")
  }

  /// A main link throttled by policy (e.g. 30 Hz) is not a fair comparison.
  func testSlowMainLinkIsNotJudged() {
    var check = PresentCadenceCheck()
    check.arm()
    XCTAssertEqual(run(&check, seconds: 10, mainHz: 8, presentHz: 4), [])
    XCTAssertTrue(check.armed)
  }
}
