import XCTest
@testable import LabanApp

/// Unit tests for `CursorBlinkDriver`.
///
/// All work runs on the main queue via `XCTestExpectation` + `DispatchQueue.main.async`
/// because the driver requires main-queue access.
@MainActor
final class CursorBlinkDriverTests: XCTestCase {

  // MARK: - Initial state

  func testInitialPhaseIsVisible() {
    let driver = CursorBlinkDriver()
    XCTAssertTrue(driver.phaseVisible, "cursor must be solid at creation")
  }

  func testInitialTimerNotRunning() {
    let driver = CursorBlinkDriver()
    XCTAssertFalse(driver.timerRunning, "timer must not be running before first sync")
  }

  func testInitialPendingFlipFalse() {
    let driver = CursorBlinkDriver()
    XCTAssertFalse(driver.consumePendingFlip(),
      "no pending flip before any timer tick")
  }

  // MARK: - sync: timer starts when all gates true

  func testSyncStartsTimerWhenAllGatesTrue() {
    let driver = CursorBlinkDriver()
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    XCTAssertTrue(driver.timerRunning, "timer must start when all three gates are true")
  }

  // MARK: - sync: timer does not start when blinkActive=false

  func testSyncDoesNotStartTimerWhenBlinkDisabled() {
    let driver = CursorBlinkDriver()
    driver.sync(blinkActive: false, windowVisibleToUser: true, cursorVisible: true)
    XCTAssertFalse(driver.timerRunning, "timer must not start when blink is disabled")
  }

  // MARK: - sync: timer stops when a gate opens

  func testSyncStopsTimerWhenBlinkDisabled() {
    let driver = CursorBlinkDriver()
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    XCTAssertTrue(driver.timerRunning)

    driver.sync(blinkActive: false, windowVisibleToUser: true, cursorVisible: true)
    XCTAssertFalse(driver.timerRunning,
      "timer must stop when blinkActive gate opens")
  }

  func testSyncStopsTimerWhenWindowHides() {
    let driver = CursorBlinkDriver()
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    XCTAssertTrue(driver.timerRunning)

    driver.sync(blinkActive: true, windowVisibleToUser: false, cursorVisible: true)
    XCTAssertFalse(driver.timerRunning,
      "timer must stop when window-visible gate opens")
  }

  // MARK: - sync stop resets phase to visible

  func testSyncStopResetsPhaseToVisible() {
    let driver = CursorBlinkDriver()
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    driver.simulateTimerFireForTesting()  // reach the hidden phase deterministically
    XCTAssertFalse(driver.phaseVisible)
    driver.sync(blinkActive: false, windowVisibleToUser: true, cursorVisible: true)
    XCTAssertTrue(driver.phaseVisible,
      "phase must reset to visible (solid cursor) when timer stops")
  }

  // MARK: - sync stop mid-off-phase must request a repaint

  /// Regression (review finding): resigning key while the cursor is in the
  /// hidden half of the blink cycle must repaint a solid cursor. The display
  /// link parks on resign, so the stop path itself has to fire `onPhaseFlip`
  /// (which the view wires to `advanceFrame()`) and leave a pending flip so
  /// that frame's guard passes — otherwise the non-key window keeps showing
  /// a hidden cursor until refocus, violating spec.md §23's "always solid
  /// when the terminal is not key".
  func testSyncStopMidHiddenPhaseFiresRepaintAndResetsVisible() {
    let driver = CursorBlinkDriver()
    var flips = 0
    driver.onPhaseFlip = { flips += 1 }
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    driver.simulateTimerFireForTesting()
    XCTAssertFalse(driver.phaseVisible, "test precondition: cursor hidden mid-off-phase")
    XCTAssertEqual(flips, 1)
    _ = driver.consumePendingFlip()  // the off-phase frame already painted

    // Window resigns key: visibility gate opens, timer must stop.
    driver.sync(blinkActive: true, windowVisibleToUser: false, cursorVisible: true)

    XCTAssertTrue(driver.phaseVisible, "phase must reset to visible on stop")
    XCTAssertFalse(driver.timerRunning, "timer must stop when window not visible")
    XCTAssertEqual(flips, 2, "stopping mid-off-phase must fire onPhaseFlip to repaint")
    XCTAssertTrue(driver.consumePendingFlip(),
      "the repaint frame must see a pending flip so advanceFrame's guard passes")
  }

  func testSyncStopMidVisiblePhaseDoesNotRepaint() {
    let driver = CursorBlinkDriver()
    var flips = 0
    driver.onPhaseFlip = { flips += 1 }
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    // Phase is visible (no timer fire); stopping must not request a repaint —
    // the on-screen cursor is already solid.
    driver.sync(blinkActive: true, windowVisibleToUser: false, cursorVisible: true)
    XCTAssertTrue(driver.phaseVisible)
    XCTAssertEqual(flips, 0, "stopping while already solid must not waste a repaint")
    XCTAssertFalse(driver.consumePendingFlip())
  }

  // MARK: - Test hook is gated on a running timer

  func testSimulateTimerFireIsNoOpWhenTimerStopped() {
    let driver = CursorBlinkDriver()
    driver.simulateTimerFireForTesting()
    XCTAssertTrue(driver.phaseVisible,
      "the hook must mirror the real handler, which cannot fire with no timer")
    XCTAssertFalse(driver.consumePendingFlip())
  }

  // MARK: - noteInput forces phase visible and cancels pending flip

  func testNoteInputForcesPhaseVisible() {
    let driver = CursorBlinkDriver()
    // Start the timer so noteInput has something to restart
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    // Phase starts visible, but let's call noteInput directly to ensure it is still visible
    driver.noteInput()
    XCTAssertTrue(driver.phaseVisible,
      "noteInput must force phase to visible")
  }

  func testNoteInputClearsPendingFlip() {
    let driver = CursorBlinkDriver()
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)
    driver.noteInput()
    XCTAssertFalse(driver.consumePendingFlip(),
      "noteInput must clear any pending flip so the next frame doesn't see a stale flip")
  }

  // MARK: - Timer fires: phase toggles and pendingFlip set

  func testTimerFlipsPhaseAndSetsPendingFlip() {
    let driver = CursorBlinkDriver()
    let flipExpectation = expectation(description: "onPhaseFlip fires")
    var flipCount = 0
    driver.onPhaseFlip = {
      flipCount += 1
      if flipCount == 1 {
        flipExpectation.fulfill()
      }
    }
    driver.sync(blinkActive: true, windowVisibleToUser: true, cursorVisible: true)

    wait(for: [flipExpectation], timeout: 2.0)
    // After the first flip, phase must have toggled (false) and pendingFlip set
    XCTAssertFalse(driver.phaseVisible,
      "phase must toggle to hidden on first timer tick")
    XCTAssertTrue(driver.consumePendingFlip(),
      "pendingFlip must be set after timer fires")
  }

  // MARK: - consumePendingFlip is idempotent

  func testConsumePendingFlipIsIdempotent() {
    let driver = CursorBlinkDriver()
    _ = driver.consumePendingFlip()
    XCTAssertFalse(driver.consumePendingFlip(),
      "consumePendingFlip must return false on second call without an intervening flip")
  }
}
