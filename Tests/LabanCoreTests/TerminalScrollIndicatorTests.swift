import LabanCore
import XCTest

final class TerminalScrollIndicatorTests: XCTestCase {

  // MARK: - Hidden cases

  func testNoScrollbackProducesHiddenOutput() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 0, totalRows: 24, viewportRows: 24, isHoverEdge: false))
    XCTAssertEqual(out, .hidden)
  }

  func testZeroViewportRowsProducesHiddenOutput() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 0, totalRows: 1000, viewportRows: 0, isHoverEdge: false))
    XCTAssertEqual(out, .hidden)
  }

  func testAltScreenProducesHiddenOutput() {
    // A full-screen TUI (e.g. Claude Code's fullscreen renderer) owns the
    // screen and its own scrollback. Even with a large scrollback total and an
    // offset that reads as scrolled-back, the overlay must stay hidden.
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: false,
        isAltScreen: true))
    XCTAssertEqual(out, .hidden)
  }

  func testAltScreenStaysHiddenEvenWhenHovering() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: true,
        isAltScreen: true))
    XCTAssertEqual(out, .hidden)
  }

  func testMouseTrackingProducesHiddenOutput() {
    // Claude Code's fullscreen renderer runs under mouse tracking on the
    // primary screen with scrollback above, so the viewport reads as
    // scrolled-back. Laban forwards the wheel to the app as mouse events, so
    // that scrollback isn't user-navigable — the overlay must stay hidden
    // rather than pin on permanently.
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: false,
        isAltScreen: false, isMouseTracking: true))
    XCTAssertEqual(out, .hidden)
  }

  func testMouseTrackingStaysHiddenEvenWhenHovering() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: true,
        isAltScreen: false, isMouseTracking: true))
    XCTAssertEqual(out, .hidden)
  }

  func testAtLiveBottomDoesNotHoldButThumbStillSized() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 976, totalRows: 1000, viewportRows: 24, isHoverEdge: false))
    XCTAssertFalse(out.shouldHold)
    XCTAssertFalse(out.pillVisible)
    XCTAssertGreaterThan(out.thumbFraction, 0)
  }

  // MARK: - Scrolled-back cases

  func testScrolledBackHoldsAndShowsPillWithLinesBack() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 500, totalRows: 1000, viewportRows: 24, isHoverEdge: false))
    XCTAssertTrue(out.shouldHold)
    XCTAssertTrue(out.pillVisible)
    // bottomOffset = 976, viewportOffset = 500 -> linesBack = 476.
    XCTAssertEqual(out.pillText, "476 / 976")
  }

  func testHoverAtBottomHoldsButHidesPill() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 976, totalRows: 1000, viewportRows: 24, isHoverEdge: true))
    XCTAssertTrue(out.shouldHold)
    XCTAssertFalse(out.pillVisible)
  }

  // MARK: - Thumb geometry

  func testThumbFractionFloorPreventsInvisibleThumb() {
    // 24 / 5000 ≈ 0.0048 — clamps up to the minimum floor.
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 0, totalRows: 5000, viewportRows: 24, isHoverEdge: false))
    XCTAssertEqual(out.thumbFraction, TerminalScrollIndicator.minThumbFraction, accuracy: 1e-9)
  }

  func testThumbOffsetTracksViewportOffset() {
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 250, totalRows: 1000, viewportRows: 100, isHoverEdge: false))
    XCTAssertEqual(out.thumbOffsetFraction, 0.25, accuracy: 1e-9)
    XCTAssertEqual(out.thumbFraction, 0.1, accuracy: 1e-9)
  }

  func testThumbOffsetClampsBelowOne() {
    // Pathological: offset claims to be past the end. Output must stay in
    // valid track range so the view doesn't paint outside its bounds.
    let out = TerminalScrollIndicator.decide(
      .init(viewportOffset: 10_000, totalRows: 1000, viewportRows: 100, isHoverEdge: false))
    XCTAssertLessThanOrEqual(out.thumbOffsetFraction, 1 - out.thumbFraction + 1e-9)
  }

  // MARK: - linesBack

  func testLinesBackZeroAtLiveBottom() {
    XCTAssertEqual(
      TerminalScrollIndicator.linesBack(
        .init(viewportOffset: 976, totalRows: 1000, viewportRows: 24, isHoverEdge: false)),
      0)
  }

  func testLinesBackCountsRowsIntoHistory() {
    XCTAssertEqual(
      TerminalScrollIndicator.linesBack(
        .init(viewportOffset: 500, totalRows: 1000, viewportRows: 24, isHoverEdge: false)),
      476)
  }

  // MARK: - Idle-hide arming

  func testScrolledBackHoldsAndCancelsAnyPendingHide() {
    let action = TerminalScrollIndicator.idleHideAction(
      shouldHold: true, linesBack: 5, previousLinesBack: 0,
      isVisible: true, hidePending: true)
    XCTAssertEqual(action, .hold)
  }

  func testReturnToBottomArmsHide() {
    // linesBack moved 3 -> 0: genuine scroll back to the live bottom.
    let action = TerminalScrollIndicator.idleHideAction(
      shouldHold: false, linesBack: 0, previousLinesBack: 3,
      isVisible: true, hidePending: false)
    XCTAssertEqual(action, .armHide)
  }

  func testStreamingOutputAtBottomDoesNotRearmPendingHide() {
    // Already at the bottom with a hide already counting down; output grew the
    // buffer but the viewport stayed pinned (linesBack unchanged at 0). The
    // countdown must keep running rather than restart, so the indicator can
    // still fade while output flows.
    let action = TerminalScrollIndicator.idleHideAction(
      shouldHold: false, linesBack: 0, previousLinesBack: 0,
      isVisible: true, hidePending: true)
    XCTAssertEqual(action, .keep)
  }

  func testVisibleAtBottomWithNoTimerArmsHide() {
    // Defensive: visible at the bottom but nothing is scheduled — arm so a
    // stuck indicator can never linger forever.
    let action = TerminalScrollIndicator.idleHideAction(
      shouldHold: false, linesBack: 0, previousLinesBack: 0,
      isVisible: true, hidePending: false)
    XCTAssertEqual(action, .armHide)
  }

  func testHiddenIndicatorStaysHidden() {
    let action = TerminalScrollIndicator.idleHideAction(
      shouldHold: false, linesBack: 0, previousLinesBack: 0,
      isVisible: false, hidePending: false)
    XCTAssertEqual(action, .keep)
  }
}
