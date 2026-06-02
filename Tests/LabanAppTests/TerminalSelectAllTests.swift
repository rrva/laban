import LabanCore
import XCTest

@testable import LabanApp

/// Select All must cover the entire buffer — every scrollback row, full width —
/// regardless of where the viewport happens to be scrolled when invoked.
final class TerminalSelectAllTests: XCTestCase {
  func testSelectAllPointsSpanWholeBufferAtAbsoluteOrigin() throws {
    let points = try XCTUnwrap(
      TerminalSelectionInput.selectAllPoints(totalRows: 100, cols: 80))
    // Absolute row = row + viewportOffsetAtCapture. Capturing at offset 0 pins
    // the anchor to absolute row 0 and the focus to the last row.
    XCTAssertEqual(points.anchor.row + points.anchor.viewportOffsetAtCapture, 0)
    XCTAssertEqual(points.anchor.col, 0)
    XCTAssertEqual(points.focus.row + points.focus.viewportOffsetAtCapture, 99)
    XCTAssertEqual(points.focus.col, 79)
  }

  func testSelectAllReturnsNilForEmptyBuffer() {
    XCTAssertNil(TerminalSelectionInput.selectAllPoints(totalRows: 0, cols: 80))
    XCTAssertNil(TerminalSelectionInput.selectAllPoints(totalRows: 100, cols: 0))
  }

  /// When mapped through the same translation the copy path uses, the resulting
  /// selection covers absolute rows 0…totalRows-1 for any scroll offset.
  func testSelectAllMapsToWholeBufferForAnyViewportOffset() throws {
    let totalRows = 250
    let cols = 120
    let points = try XCTUnwrap(
      TerminalSelectionInput.selectAllPoints(totalRows: totalRows, cols: cols))
    for offset in [0, 1, 42, totalRows - 1] {
      let selection = try XCTUnwrap(
        TerminalSelectionInput.terminalSelection(
          sessionId: "session-1",
          anchor: points.anchor,
          focus: points.focus,
          currentViewportOffset: offset))
      // The selection stores viewport-relative rows; adding the offset back
      // recovers the absolute span the copy path resolves against.
      XCTAssertEqual(selection.anchor.row + offset, 0)
      XCTAssertEqual(selection.anchor.col, 0)
      XCTAssertEqual(selection.focus.row + offset, totalRows - 1)
      XCTAssertEqual(selection.focus.col, cols - 1)
    }
  }
}
