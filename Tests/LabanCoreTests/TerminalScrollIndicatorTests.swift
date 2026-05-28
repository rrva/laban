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
}
