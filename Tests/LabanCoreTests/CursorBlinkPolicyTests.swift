import XCTest

@testable import LabanCore

/// Truth-table tests for `CursorBlinkPolicy.timerShouldRun`.
///
/// The timer must run only when ALL three gates are true. Any single gate
/// being false must stop the timer.
final class CursorBlinkPolicyTests: XCTestCase {

  // MARK: - Timer off when blink disabled

  func testTimerOffWhenBlinkDisabled() {
    XCTAssertFalse(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: false,
        windowVisibleToUser: true,
        cursorVisible: true),
      "timer must not run when blink is disabled, even with visible window and cursor")
  }

  // MARK: - Timer off when window not visible

  func testTimerOffWhenWindowNotVisible() {
    XCTAssertFalse(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: true,
        windowVisibleToUser: false,
        cursorVisible: true),
      "timer must not run when window is not visible to the user")
  }

  // MARK: - Timer off when cursor not visible

  func testTimerOffWhenCursorNotVisible() {
    XCTAssertFalse(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: true,
        windowVisibleToUser: true,
        cursorVisible: false),
      "timer must not run when the cursor is not visible")
  }

  // MARK: - All gates false

  func testTimerOffWhenAllGatesFalse() {
    XCTAssertFalse(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: false,
        windowVisibleToUser: false,
        cursorVisible: false),
      "timer must not run when all gates are false")
  }

  // MARK: - Timer on only when all gates true

  func testTimerOnWhenAllGatesTrue() {
    XCTAssertTrue(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: true,
        windowVisibleToUser: true,
        cursorVisible: true),
      "timer must run when blink is active, window is visible, and cursor is visible")
  }

  // MARK: - Two-gate partial combinations still off

  func testTimerOffWhenOnlyBlinkAndWindowTrue() {
    XCTAssertFalse(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: true,
        windowVisibleToUser: true,
        cursorVisible: false),
      "timer must not run when cursor gate is false")
  }

  func testTimerOffWhenOnlyBlinkAndCursorTrue() {
    XCTAssertFalse(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: true,
        windowVisibleToUser: false,
        cursorVisible: true),
      "timer must not run when window-visible gate is false")
  }

  func testTimerOffWhenOnlyWindowAndCursorTrue() {
    XCTAssertFalse(
      CursorBlinkPolicy.timerShouldRun(
        blinkActive: false,
        windowVisibleToUser: true,
        cursorVisible: true),
      "timer must not run when blink gate is false")
  }

  // MARK: - blinkInterval sanity

  func testBlinkIntervalIsHalfSecond() {
    XCTAssertEqual(
      CursorBlinkPolicy.blinkInterval, 0.5,
      "blink interval must be 0.5 seconds (2 Hz)")
  }
}
