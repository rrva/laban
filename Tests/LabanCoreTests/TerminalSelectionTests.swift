import CoreGraphics
import LabanTerminalCore
import XCTest

@testable import LabanCore

// Escape-sequence bytes matching the colored-boxes fixture:
//   Row 0: ┌────────────┐
//   Row 1: │ hello mvp  │  (│=col0, ' '=col1, h=col2..p=col10, ' '=col11, ' '=col12, │=col13)
//   Row 2: └────────────┘
private let selectionFixtureBytes: [UInt8] = Array(
  ("\u{1B}[38;2;255;204;0m┌────────────┐\u{1B}[0m\r\n"
    + "\u{1B}[38;2;116;199;236m│ hello mvp  │\u{1B}[0m\r\n"
    + "\u{1B}[38;2;255;204;0m└────────────┘\u{1B}[0m\r\n").utf8)

final class TerminalSelectionTests: XCTestCase {

  // MARK: - Segments: single row

  func testSingleRowSegmentForwardDirection() {
    let sel = TerminalSelection(
      sessionId: "s",
      anchor: TerminalCellCoordinate(row: 0, col: 2),
      focus: TerminalCellCoordinate(row: 0, col: 5)
    )
    let segs = sel.segments(rows: 5, cols: 80)
    XCTAssertEqual(segs.count, 1)
    XCTAssertEqual(segs[0].row, 0)
    XCTAssertEqual(segs[0].startCol, 2)
    XCTAssertEqual(segs[0].endCol, 6)  // focus col + 1
  }

  func testSingleRowSegmentReversedDirection() {
    // anchor after focus — should normalize
    let sel = TerminalSelection(
      sessionId: "s",
      anchor: TerminalCellCoordinate(row: 0, col: 5),
      focus: TerminalCellCoordinate(row: 0, col: 2)
    )
    let segs = sel.segments(rows: 5, cols: 80)
    XCTAssertEqual(segs.count, 1)
    XCTAssertEqual(segs[0].startCol, 2)
    XCTAssertEqual(segs[0].endCol, 6)
  }

  func testSingleCellSelection() {
    let sel = TerminalSelection(
      sessionId: "s",
      anchor: TerminalCellCoordinate(row: 2, col: 4),
      focus: TerminalCellCoordinate(row: 2, col: 4)
    )
    let segs = sel.segments(rows: 5, cols: 80)
    XCTAssertEqual(segs.count, 1)
    XCTAssertEqual(segs[0].endCol - segs[0].startCol, 1)
  }

  // MARK: - Segments: multi-row

  func testMultiRowSegmentsProduceCorrectBoundaries() {
    let sel = TerminalSelection(
      sessionId: "s",
      anchor: TerminalCellCoordinate(row: 1, col: 3),
      focus: TerminalCellCoordinate(row: 3, col: 5)
    )
    let segs = sel.segments(rows: 10, cols: 20)
    XCTAssertEqual(segs.count, 3)
    // First row: startCol → end of row
    XCTAssertEqual(segs[0].row, 1)
    XCTAssertEqual(segs[0].startCol, 3)
    XCTAssertEqual(segs[0].endCol, 20)
    // Middle row: full width
    XCTAssertEqual(segs[1].row, 2)
    XCTAssertEqual(segs[1].startCol, 0)
    XCTAssertEqual(segs[1].endCol, 20)
    // Last row: 0 → focusCol + 1
    XCTAssertEqual(segs[2].row, 3)
    XCTAssertEqual(segs[2].startCol, 0)
    XCTAssertEqual(segs[2].endCol, 6)
  }

  func testMultiRowReversedAnchorFocusNormalizes() {
    let sel = TerminalSelection(
      sessionId: "s",
      anchor: TerminalCellCoordinate(row: 3, col: 5),
      focus: TerminalCellCoordinate(row: 1, col: 3)
    )
    let segs = sel.segments(rows: 10, cols: 20)
    XCTAssertEqual(segs.count, 3)
    XCTAssertEqual(segs[0].row, 1)
    XCTAssertEqual(segs[2].row, 3)
  }

  // MARK: - cgRects

  func testCgRectsCountMatchesSegmentCount() {
    let sel = TerminalSelection(
      sessionId: "s",
      anchor: TerminalCellCoordinate(row: 0, col: 2),
      focus: TerminalCellCoordinate(row: 2, col: 4)
    )
    let segs = sel.segments(rows: 10, cols: 20)
    let rects = sel.cgRects(
      rows: 10, cols: 20, cellWidth: 8, cellHeight: 16, originX: 0, originY: 0)
    XCTAssertEqual(rects.count, segs.count)
  }

  func testCgRectCoordinatesForFirstRowSelection() {
    // Row 0, cols 2..4 (3 cells). With CG origin at bottom-left:
    // y = originY + (rows-1-0) * ch = 0 + 9*16 = 144
    let sel = TerminalSelection(
      sessionId: "s",
      anchor: TerminalCellCoordinate(row: 0, col: 2),
      focus: TerminalCellCoordinate(row: 0, col: 4)
    )
    let rects = sel.cgRects(
      rows: 10, cols: 20, cellWidth: 8, cellHeight: 16, originX: 0, originY: 0)
    XCTAssertEqual(rects.count, 1)
    let r = rects[0]
    XCTAssertEqual(r.origin.x, 16, "x = startCol * cellWidth = 2*8")
    XCTAssertEqual(r.origin.y, 144, "y = (rows-1-row) * cellHeight = 9*16")
    XCTAssertEqual(r.size.width, 24, "width = 3 cells * 8")
    XCTAssertEqual(r.size.height, 16)
  }

  // MARK: - selectedText from fixture snapshot

  func testSelectedTextHelloMvpFromFixture() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(selectionFixtureBytes)
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    // Row 1, cols 2..10 → "hello mvp"
    let sel = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: 1, col: 2),
      focus: TerminalCellCoordinate(row: 1, col: 10)
    )

    let text = sel.selectedText(from: snap.pointee)
    XCTAssertEqual(text, "hello mvp", "selected text must be 'hello mvp'; got '\(text)'")
  }

  func testSelectedTextRightTrimTrailingSpaces() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(selectionFixtureBytes)
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    // Row 1, cols 2..12 — "hello mvp  " has trailing spaces; right-trim gives "hello mvp"
    let sel = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: 1, col: 2),
      focus: TerminalCellCoordinate(row: 1, col: 12)
    )
    let text = sel.selectedText(from: snap.pointee)
    XCTAssertEqual(text, "hello mvp", "trailing spaces must be right-trimmed; got '\(text)'")
  }

  func testSelectionFrameCommandsAppearsInProducerOutput() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(selectionFixtureBytes)
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let sel = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: 1, col: 2),
      focus: TerminalCellCoordinate(row: 1, col: 10)
    )

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap), selection: sel)

    let selectionCmds = cmds.filter {
      if case .selection = $0 { return true }
      return false
    }
    XCTAssertEqual(
      selectionCmds.count, 1, "single-row selection must produce one selection command")
  }

  func testSelectionCommandsAppearBetweenBgAndGlyphs() throws {
    // Verify render order: BG rects → selection rects → glyph runs.
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(selectionFixtureBytes)
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let sel = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: 0, col: 0),
      focus: TerminalCellCoordinate(row: 0, col: 5)
    )

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap), selection: sel)

    var lastBgIndex = -1
    var firstSelIndex = Int.max
    var lastSelIndex = -1
    var firstGlyphIndex = Int.max

    for (i, cmd) in cmds.enumerated() {
      switch cmd {
      case .rect(_, _, let src) where src == .terminal:
        lastBgIndex = i
      case .selection:
        firstSelIndex = min(firstSelIndex, i)
        lastSelIndex = max(lastSelIndex, i)
      case .glyphRun(_, _, _, _, _, let src, _, _, _) where src == .terminal:
        firstGlyphIndex = min(firstGlyphIndex, i)
      default:
        break
      }
    }

    if lastBgIndex >= 0 && firstSelIndex < Int.max {
      XCTAssertGreaterThan(firstSelIndex, lastBgIndex, "selection must appear after all bg rects")
    }
    if firstSelIndex < Int.max && firstGlyphIndex < Int.max {
      XCTAssertLessThan(
        lastSelIndex, firstGlyphIndex, "selection must appear before all glyph runs")
    }
  }
}
