import XCTest

@testable import LabanApp

final class TerminalAttentionDamageTests: XCTestCase {
  // A pulse-only frame: the terminal is clean (nothing invalidated, no tab
  // change, no scroll), only a background tab's attention marker is animating.
  // It must force a full repaint — otherwise a clean terminal yields
  // `.partial([])` damage and the renderer skips the whole content pass, so the
  // sidebar attention marker freezes mid-pulse.
  func testAttentionAnimatingForcesFullDamageOnCleanTerminal() {
    XCTAssertTrue(
      TerminalBitmapView.shouldForceFullDamage(
        renderInvalidated: false,
        tabChanged: false,
        scrollAnimating: false,
        attentionAnimating: true,
        fractionalScrollOffset: false))
  }

  // A frame produced while rows sit at a sub-cell scroll offset (precise
  // gesture paused mid-fraction, settle pending) must force a full repaint:
  // the offset shifts every row, so partial damage would composite damaged
  // rows against stale pixels everywhere else.
  func testFractionalScrollOffsetForcesFullDamage() {
    XCTAssertTrue(
      TerminalBitmapView.shouldForceFullDamage(
        renderInvalidated: false,
        tabChanged: false,
        scrollAnimating: false,
        attentionAnimating: false,
        fractionalScrollOffset: true))
  }

  // An otherwise-idle clean frame must NOT force full damage, so the render loop
  // can still park and honour the idle-CPU budget.
  func testCleanIdleFrameDoesNotForceFullDamage() {
    XCTAssertFalse(
      TerminalBitmapView.shouldForceFullDamage(
        renderInvalidated: false,
        tabChanged: false,
        scrollAnimating: false,
        attentionAnimating: false,
        fractionalScrollOffset: false))
  }
}
