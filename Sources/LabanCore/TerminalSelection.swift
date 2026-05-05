import CoreGraphics
import Foundation
import LabanTerminalCore

public struct TerminalCellCoordinate: Codable, Equatable, Sendable {
  public var row: Int
  public var col: Int

  public init(row: Int, col: Int) {
    self.row = row
    self.col = col
  }
}

public struct TerminalSelection: Codable, Equatable, Sendable {
  public var sessionId: Session.ID
  public var anchor: TerminalCellCoordinate
  public var focus: TerminalCellCoordinate

  public init(sessionId: Session.ID, anchor: TerminalCellCoordinate, focus: TerminalCellCoordinate)
  {
    self.sessionId = sessionId
    self.anchor = anchor
    self.focus = focus
  }

  // Normalized start/end (start <= end in row-major order).
  private func startEnd(cols: Int) -> (start: TerminalCellCoordinate, end: TerminalCellCoordinate) {
    let anchorLinear = anchor.row * cols + anchor.col
    let focusLinear = focus.row * cols + focus.col
    return anchorLinear <= focusLinear
      ? (anchor, focus)
      : (focus, anchor)
  }

  // Returns (row, startCol, endColExclusive) tuples.
  public func segments(rows: Int, cols: Int) -> [(row: Int, startCol: Int, endCol: Int)] {
    guard rows > 0, cols > 0 else { return [] }
    let (start, end) = startEnd(cols: cols)
    // Clamp both endpoints to the viewport. Either may be off the
    // viewport (negative or >= rows) when the caller is rendering a
    // scroll-anchored selection whose original cell has scrolled out
    // of view. We render only the visible portion. Without this guard
    // a negative `row` becomes a negative index into `cells` in
    // `selectedText` and crashes the app.
    let startRow = max(0, start.row)
    let endRow = min(rows - 1, end.row)
    guard startRow <= endRow else { return [] }

    if startRow == endRow {
      // Single visible row. If the original (unclamped) start/end were
      // both on this row, use their cols; otherwise use full-row span
      // because we're rendering a clipped slice of a multi-row select.
      let sCol = (start.row == startRow) ? min(start.col, cols - 1) : 0
      let eCol = (end.row == endRow) ? min(end.col + 1, cols) : cols
      guard eCol > sCol else { return [] }
      return [(row: startRow, startCol: sCol, endCol: eCol)]
    }

    var segs: [(row: Int, startCol: Int, endCol: Int)] = []
    let firstStartCol = (start.row == startRow) ? start.col : 0
    segs.append((row: startRow, startCol: firstStartCol, endCol: cols))
    for r in (startRow + 1)..<endRow {
      segs.append((row: r, startCol: 0, endCol: cols))
    }
    let lastEndCol = (end.row == endRow) ? end.col + 1 : cols
    segs.append((row: endRow, startCol: 0, endCol: lastEndCol))
    return segs
  }

  public func cgRects(
    rows: Int,
    cols: Int,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    originX: CGFloat,
    originY: CGFloat
  ) -> [CGRect] {
    segments(rows: rows, cols: cols).map { seg in
      let x = originX + CGFloat(seg.startCol) * cellWidth
      let y = originY + CGFloat(rows - 1 - seg.row) * cellHeight
      let w = CGFloat(seg.endCol - seg.startCol) * cellWidth
      return CGRect(x: x, y: y, width: w, height: cellHeight)
    }
  }

  public func selectedText(from snap: LabanSnapshot) -> String {
    let rows = Int(snap.rows)
    let cols = Int(snap.cols)
    guard let cells = snap.cells, let storage = snap.utf8_storage else { return "" }

    var lines: [String] = []
    for seg in segments(rows: rows, cols: cols) {
      var line = ""
      for col in seg.startCol..<seg.endCol {
        let cell = cells[seg.row * cols + col]
        guard cell.utf8_length > 0 else {
          line += " "
          continue
        }
        let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length)
        )
        if let text = String(bytes: buf, encoding: .utf8) {
          line += text
        } else {
          line += " "
        }
      }
      // Per-row right-trim only (preserve interior spaces).
      let trimmed = line.replacingOccurrences(
        of: "\\s+$", with: "", options: .regularExpression)
      lines.append(trimmed)
    }
    return lines.joined(separator: "\n")
  }
}
