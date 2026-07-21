import CoreGraphics
import LabanRenderer
import XCTest

@testable import LabanCore

/// Block elements (U+2580..U+259F) must render as procedural integer-aligned
/// rectangles in BOTH FrameProducer overloads. The local overload (libghostty
/// snapshot pointer) closed this gap years ago; this test pins the same
/// behaviour for the remote overload (`LabandSnapshotResponse`), which is the
/// path background-session mode uses.
///
/// Without the fix, the Claude Code crab mascot — drawn with adjacent
/// `U+2588 FULL BLOCK` cells — renders as font glyphs and hairline seams
/// appear between cells whenever the font's glyph extent does not exactly
/// fill the terminal cell.
final class FrameProducerRemoteBlockElementTests: XCTestCase {

  private let cellW = 8
  private let cellH = 16

  private func snapshot(
    rows: Int,
    cols: Int,
    cells: [LabandSnapshotCell]
  ) -> LabandSnapshotResponse {
    LabandSnapshotResponse(
      logicalSessionId: "test",
      incarnationId: "1",
      rows: rows,
      cols: cols,
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: false,
      visibleText: "",
      cells: cells
    )
  }

  private func cell(
    row: Int,
    col: Int,
    text: String,
    fg: UInt32 = 0xFFFF_FFFF,
    bg: UInt32 = 0x0000_0000
  ) -> LabandSnapshotCell {
    LabandSnapshotCell(
      row: row, col: col, text: text, flags: 0,
      foregroundRGBA: fg, backgroundRGBA: bg)
  }

  func testAdjacentFullBlocksEmitProceduralRectsNotGlyphRuns() {
    // Two adjacent U+2588 FULL BLOCK cells: this is the canonical
    // crab-mascot row.
    let snapshot = snapshot(
      rows: 1, cols: 2,
      cells: [
        cell(row: 0, col: 0, text: "\u{2588}"),
        cell(row: 0, col: 1, text: "\u{2588}"),
      ])

    let producer = FrameProducer(cellWidth: cellW, cellHeight: cellH)
    let cmds = producer.commands(from: snapshot)

    var glyphsContainBlock = false
    var rectAtCol0 = false
    var rectAtCol1 = false
    for cmd in cmds {
      switch cmd {
      case .glyphRun(_, let text, _, _, _, let src, _, _, _, _, _, _, _) where src == .terminal:
        if text.contains("\u{2588}") { glyphsContainBlock = true }
      case .rect(let rect, _, let src, _) where src == .terminal:
        // The default-background rect spans cols*cw wide; ignore it.
        if rect.size.width == CGFloat(cellW * 2) { continue }
        if rect.origin.x == 0 { rectAtCol0 = true }
        if rect.origin.x == CGFloat(cellW) { rectAtCol1 = true }
      default:
        continue
      }
    }

    XCTAssertFalse(
      glyphsContainBlock,
      "U+2588 must not flow through the font glyph path — that is the bug")
    XCTAssertTrue(
      rectAtCol0 && rectAtCol1,
      "both adjacent full-block cells must emit procedural .rect commands")
  }

  func testProceduralRectsTileGapFree() {
    // Two adjacent half-block cells. The boundary between them must be at an
    // integer pixel so they tile without a seam.
    let snapshot = snapshot(
      rows: 1, cols: 2,
      cells: [
        cell(row: 0, col: 0, text: "\u{2580}"),  // UPPER HALF BLOCK
        cell(row: 0, col: 1, text: "\u{2580}"),
      ])

    let cmds = FrameProducer(cellWidth: cellW, cellHeight: cellH)
      .commands(from: snapshot)

    let blockRects: [CGRect] = cmds.compactMap { cmd in
      guard case .rect(let rect, _, let src, _) = cmd, src == .terminal,
        rect.size.width == CGFloat(cellW)  // exclude the wide bg rect
      else { return nil }
      return rect
    }
    XCTAssertEqual(
      blockRects.count, 2,
      "two adjacent block cells must yield two cell-sized procedural rects")

    let xs = blockRects.map { $0.minX }.sorted()
    XCTAssertEqual(xs[0], 0)
    XCTAssertEqual(xs[1], CGFloat(cellW))
    XCTAssertEqual(
      blockRects[0].maxX, blockRects[1].minX,
      "left rect's right edge must meet right rect's left edge with no gap")
  }
}
