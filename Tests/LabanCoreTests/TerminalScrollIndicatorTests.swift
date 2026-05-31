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
      .init(
        viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: false,
        isAltScreen: true))
    XCTAssertEqual(out, .hidden)
  }

  func testAltScreenStaysHiddenEvenWhenHovering() {
    let out = TerminalScrollIndicator.decide(
      .init(
        viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: true,
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
      .init(
        viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: false,
        isAltScreen: false, isMouseTracking: true))
    XCTAssertEqual(out, .hidden)
  }

  func testMouseTrackingStaysHiddenEvenWhenHovering() {
    let out = TerminalScrollIndicator.decide(
      .init(
        viewportOffset: 200, totalRows: 1000, viewportRows: 24, isHoverEdge: true,
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

  // MARK: - Drag-to-scrub history fraction

  /// Track spans y ∈ [bottom 12, top 588] (height 600, topInset 12); a 100pt
  /// thumb travels over availableTravel = (588-12) - 100 = 476pt.
  private func fraction(thumbTopY: Double) -> Double {
    TerminalScrollIndicator.historyFraction(
      thumbTopY: thumbTopY, trackTop: 588, trackBottom: 12, thumbHeight: 100)
  }

  func testHistoryFractionThumbAtTrackTopIsOldestHistory() {
    // Thumb top pinned to the track top -> oldest scrollback (fraction 0).
    XCTAssertEqual(fraction(thumbTopY: 588), 0, accuracy: 1e-9)
  }

  func testHistoryFractionThumbAtTrackBottomIsLiveBottom() {
    // Thumb top a full travel below the track top -> live bottom (fraction 1).
    XCTAssertEqual(fraction(thumbTopY: 588 - 476), 1, accuracy: 1e-9)
  }

  func testHistoryFractionMidTravelIsHalf() {
    XCTAssertEqual(fraction(thumbTopY: 588 - 238), 0.5, accuracy: 1e-9)
  }

  func testHistoryFractionClampsBeyondTrackEnds() {
    XCTAssertEqual(fraction(thumbTopY: 9999), 0, accuracy: 1e-9, "above the top clamps to oldest")
    XCTAssertEqual(fraction(thumbTopY: -9999), 1, accuracy: 1e-9, "below the bottom clamps to live")
  }

  func testHistoryFractionDegenerateTrackReturnsLiveBottom() {
    // Thumb as tall as the track (no travel) can only mean the live bottom.
    let f = TerminalScrollIndicator.historyFraction(
      thumbTopY: 100, trackTop: 588, trackBottom: 12, thumbHeight: 9999)
    XCTAssertEqual(f, 1, accuracy: 1e-9)
  }
}
