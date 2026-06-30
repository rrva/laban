import XCTest

@testable import LabanRenderer

/// The blank-screen-on-launch and stuck-tab-switch bug: the vector present link
/// is parked by the host idle policy in the same turn a frame is published, so
/// the freshly rendered frame never reaches the screen until the next keystroke.
/// `PresentParkDecision` defers the park until the pending frame presents. These
/// gates pin that logic (the link itself needs a GPU; the decision is pure).
final class PresentParkDecisionTests: XCTestCase {
  /// The exact failure shape: content is published, then the host idle policy
  /// asks to park (a tab switch / initial frame produces no scroll/output). The
  /// link must NOT park until the frame has presented.
  func testParkIsDeferredUntilPublishedFramePresents() {
    var d = PresentParkDecision(budgetCallbacks: 4)
    d.setHostRunning(true)  // active while rendering
    d.contentPublished()  // a frame was just published
    d.setHostRunning(false)  // idle policy now wants to park (no follow-on output)

    XCTAssertFalse(d.wantsPaused, "must keep running while a published frame is unpresented")

    // The next vsync presents it; now the deferred park is honored.
    d.didCallback(presented: true)
    XCTAssertTrue(d.wantsPaused, "park once the pending frame has actually presented")
  }

  /// A normal idle terminal (no pending frame) parks immediately — the zero-CPU
  /// idle win is preserved.
  func testParksImmediatelyWhenNothingPending() {
    var d = PresentParkDecision(budgetCallbacks: 4)
    d.setHostRunning(true)
    XCTAssertFalse(d.wantsPaused)
    d.setHostRunning(false)
    XCTAssertTrue(d.wantsPaused, "no pending frame -> park at once")
  }

  /// Bound: if the frame never presents (e.g. drawable-size mismatch after a
  /// resize so onPresent keeps returning false), the deferral must expire so the
  /// link cannot spin forever.
  func testPendingDeferralIsBounded() {
    var d = PresentParkDecision(budgetCallbacks: 4)
    d.setHostRunning(false)
    d.contentPublished()
    XCTAssertFalse(d.wantsPaused, "deferred while pending")
    for i in 1...4 {
      XCTAssertFalse(d.wantsPaused, "still within budget at callback \(i - 1)")
      d.didCallback(presented: false)
    }
    XCTAssertTrue(d.wantsPaused, "budget exhausted -> honor park even though never presented")
  }

  /// Host going active mid-deferral keeps it running regardless of pending.
  func testHostActiveOverridesPending() {
    var d = PresentParkDecision(budgetCallbacks: 4)
    d.setHostRunning(false)
    d.contentPublished()
    d.setHostRunning(true)
    XCTAssertFalse(d.wantsPaused)
    // Even after the frame presents, an active host keeps it running.
    d.didCallback(presented: true)
    XCTAssertFalse(d.wantsPaused)
  }
}
