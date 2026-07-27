import XCTest

@testable import LabanApp

final class TerminalAttentionDamageTests: XCTestCase {
  // The attention pulse must never reach terminal damage: a pulse-only frame
  // repaints via the renderer's dedicated sidebar-strip pass, so
  // `shouldForceFullDamage` has no attention input at all. With every other
  // trigger quiet, a clean frame stays `.partial([])` — full-surface repaints
  // at the 120 Hz output link rate were the "typing is molasses whenever a
  // tab needs me" regression. The strip pass itself is covered by
  // MetalRendererSmokeTests.testSidebarStripRepaintPaintsStripWithoutTerminalDamage.
  func testCleanFrameDoesNotForceFullDamage() {
    XCTAssertFalse(
      TerminalBitmapView.shouldForceFullDamage(
        renderInvalidated: false,
        tabChanged: false,
        scrollAnimating: false,
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
        fractionalScrollOffset: true))
  }

  func testHoverPreviewForcesFullDamageForItsScaledProjection() {
    XCTAssertTrue(
      TerminalBitmapView.shouldForceFullDamage(
        renderInvalidated: false,
        tabChanged: false,
        scrollAnimating: false,
        fractionalScrollOffset: false,
        hoverPreviewShowing: true),
      "preview rows live at different coordinates than the main terminal dirty-row bands")
  }

  func testEligibleButAbsentHoverPreviewDoesNotForceFullDamage() {
    XCTAssertFalse(
      TerminalBitmapView.shouldForceFullDamage(
        renderInvalidated: false,
        tabChanged: false,
        scrollAnimating: false,
        fractionalScrollOffset: false,
        hoverPreviewShowing: false),
      "persistent optional-preview failure must not defeat active-terminal row damage")
  }
}
