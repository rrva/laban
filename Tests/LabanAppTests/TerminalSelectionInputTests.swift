import AppKit
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class TerminalSelectionInputTests: XCTestCase {
  func testTerminalCellUsesTopDownGrid() {
    let cell = TerminalSelectionInput.terminalCell(
      at: NSPoint(x: 241, y: 386),
      geometry: geometry()
    )

    XCTAssertEqual(cell, TerminalCellCoordinate(row: 2, col: 3))
  }

  func testTerminalCellRejectsSidebarAndOutsideGrid() {
    XCTAssertNil(
      TerminalSelectionInput.terminalCell(
        at: NSPoint(x: 199, y: 386),
        geometry: geometry()
      ))
    XCTAssertNil(
      TerminalSelectionInput.terminalCell(
        at: NSPoint(x: 241, y: 460),
        geometry: geometry()
      ))
  }

  func testZeroCellWidthAndHeightReturnDefaultSelectionGeometry() {
    let geometry = TerminalSelectionInput.GridGeometry(
      boundsWidth: 100,
      boundsHeight: 80,
      sidebarWidth: 16,
      cellWidth: 0,
      cellHeight: 0,
      rows: 5,
      insets: NSEdgeInsets(top: 2, left: 3, bottom: 4, right: 5))

    XCTAssertEqual(geometry.cols, 1)
    XCTAssertNil(
      TerminalSelectionInput.terminalCell(
        at: NSPoint(x: 20, y: 20),
        geometry: geometry))

    XCTAssertEqual(
      TerminalSelectionInput.clampedPoint(
        at: NSPoint(x: 20, y: 20),
        geometry: geometry,
        viewportOffset: 7),
      TerminalSelectionPoint(row: 0, col: 0, viewportOffsetAtCapture: 7))
  }

  func testClampedPointCapturesViewportOffsetAndClampsToEdges() {
    let bottomLeft = TerminalSelectionInput.clampedPoint(
      at: NSPoint(x: 0, y: 0),
      geometry: geometry(),
      viewportOffset: 7
    )
    XCTAssertEqual(bottomLeft, TerminalSelectionPoint(row: 23, col: 0, viewportOffsetAtCapture: 7))

    let topRight = TerminalSelectionInput.clampedPoint(
      at: NSPoint(x: 999, y: 999),
      geometry: geometry(),
      viewportOffset: 9
    )
    XCTAssertEqual(topRight, TerminalSelectionPoint(row: 0, col: 29, viewportOffsetAtCapture: 9))
  }

  func testTerminalSelectionTranslatesCapturedViewportOffsets() {
    let selection = TerminalSelectionInput.terminalSelection(
      sessionId: "session-1",
      anchor: TerminalSelectionPoint(row: 5, col: 2, viewportOffsetAtCapture: 10),
      focus: TerminalSelectionPoint(row: 6, col: 4, viewportOffsetAtCapture: 10),
      currentViewportOffset: 8
    )

    XCTAssertEqual(
      selection,
      TerminalSelection(
        sessionId: "session-1",
        anchor: TerminalCellCoordinate(row: 7, col: 2),
        focus: TerminalCellCoordinate(row: 8, col: 4)
      ))
  }

  func testTerminalSelectionRequiresAnchorAndFocus() {
    XCTAssertNil(
      TerminalSelectionInput.terminalSelection(
        sessionId: "session-1",
        anchor: TerminalSelectionPoint(row: 5, col: 2, viewportOffsetAtCapture: 10),
        focus: nil,
        currentViewportOffset: 8
      ))
  }

  func testWordBoundsStopsAtSpacesAndIncludesPathGlue() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(Array("cd /tmp/foo-bar baz\r\n".utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let bounds = TerminalSelectionInput.wordBounds(row: 0, col: 4, in: snap.pointee)
    XCTAssertEqual(bounds.start, 3)
    XCTAssertEqual(bounds.end, 14)
  }

  func testWordBoundsIncludesCJKEmojiAndWideSpacerTail() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(Array("go 中👩\u{200D}💻dev now\r\n".utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let headBounds = TerminalSelectionInput.wordBounds(row: 0, col: 3, in: snap.pointee)
    XCTAssertEqual(headBounds.start, 3)
    XCTAssertEqual(headBounds.end, 11)
    let tailBounds = TerminalSelectionInput.wordBounds(row: 0, col: 4, in: snap.pointee)
    XCTAssertEqual(
      [tailBounds.start, tailBounds.end],
      [headBounds.start, headBounds.end],
      "clicking a wide glyph spacer tail must select the same word as its head cell")
    let emojiBounds = TerminalSelectionInput.wordBounds(row: 0, col: 5, in: snap.pointee)
    XCTAssertEqual(
      [emojiBounds.start, emojiBounds.end],
      [headBounds.start, headBounds.end],
      "clicking an emoji head cell must keep the CJK/emoji word together")
  }

  private func geometry() -> TerminalSelectionInput.GridGeometry {
    TerminalSelectionInput.GridGeometry(
      boundsWidth: 500,
      boundsHeight: 476,
      sidebarWidth: 200,
      cellWidth: 9,
      cellHeight: 18,
      rows: 24,
      insets: NSEdgeInsets(top: 36, left: 14, bottom: 8, right: 8)
    )
  }
}
