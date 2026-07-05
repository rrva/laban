import CoreGraphics
import Foundation
import LabanRenderer
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
    func clampCol(_ point: TerminalCellCoordinate) -> TerminalCellCoordinate {
      TerminalCellCoordinate(row: point.row, col: min(max(point.col, 0), cols - 1))
    }

    let clampedAnchor = clampCol(anchor)
    let clampedFocus = clampCol(focus)
    let anchorLinear = clampedAnchor.row * cols + clampedAnchor.col
    let focusLinear = clampedFocus.row * cols + clampedFocus.col
    return anchorLinear <= focusLinear
      ? (clampedAnchor, clampedFocus)
      : (clampedFocus, clampedAnchor)
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

    let segs = segments(rows: rows, cols: cols)
    var result = ""
    for (index, seg) in segs.enumerated() {
      let isLast = index == segs.count - 1
      // libghostty marks a row soft-wrapped when its text ran past the right
      // margin and continued onto the next row with no newline from the
      // program. Rejoin those rows into one logical line: keep the wrapped
      // row's trailing cells (they are real content, not display padding) and
      // emit no separator before the continuation row. A row that ends at a
      // real line break still gets a "\n".
      let wrapped = !isLast && Self.rowIsSoftWrapped(snap, row: seg.row)
      result += Self.snapshotLineText(
        from: snap,
        row: seg.row,
        startCol: seg.startCol,
        endCol: seg.endCol,
        trimTrailing: !wrapped
      )
      if !isLast && !wrapped {
        result += "\n"
      }
    }
    return result
  }

  private static func rowIsSoftWrapped(_ snap: LabanSnapshot, row: Int) -> Bool {
    guard row >= 0, let flags = snap.wrapped_rows, row < snap.wrapped_row_count
    else { return false }
    return flags[row] != 0
  }

  public func selectedText(
    from session: Session,
    viewportSnapshot snap: LabanSnapshot,
    viewportState: ViewportState
  ) -> String {
    let rows = Int(snap.rows)
    let cols = Int(snap.cols)
    guard rows > 0, cols > 0 else { return "" }

    let segments = absoluteSegments(
      totalRows: viewportState.totalRows,
      viewportOffset: viewportState.viewportOffset,
      cols: cols
    )
    guard !segments.isEmpty else { return "" }

    if segments.allSatisfy({ segment in
      let viewportRow = segment.row - viewportState.viewportOffset
      return viewportRow >= 0 && viewportRow < rows
    }) {
      return selectedText(from: snap)
    }

    guard let firstRow = segments.first?.row, let lastRow = segments.last?.row,
      let scrollback = session.scrollbackBlock(
        rowOffset: firstRow,
        maxRows: lastRow - firstRow + 1
      )
    else {
      return selectedText(from: snap)
    }

    let scrollbackBytes = Array(scrollback.text.utf8)
    var lines: [String] = []
    for segment in segments {
      let viewportRow = segment.row - viewportState.viewportOffset
      if viewportRow >= 0 && viewportRow < rows {
        lines.append(
          Self.snapshotLineText(
            from: snap,
            row: viewportRow,
            startCol: segment.startCol,
            endCol: segment.endCol
          ))
      } else if let line = Self.scrollbackLineText(
        from: scrollback,
        bytes: scrollbackBytes,
        row: segment.row - firstRow
      ) {
        let rowIndex = segment.row - firstRow
        let clusters = scrollback.graphemeWidths.flatMap {
          rowIndex >= 0 && rowIndex < $0.count ? $0[rowIndex] : nil
        }
        lines.append(
          Self.plainLineText(
            from: line,
            startCol: segment.startCol,
            endCol: segment.endCol,
            clusters: clusters
          ))
      } else {
        lines.append("")
      }
    }
    return lines.joined(separator: "\n")
  }

  private func absoluteSegments(
    totalRows: Int,
    viewportOffset: Int,
    cols: Int
  ) -> [(row: Int, startCol: Int, endCol: Int)] {
    guard totalRows > 0, cols > 0 else { return [] }
    let (start, end) = startEnd(cols: cols)
    let startRow = viewportOffset + start.row
    let endRow = viewportOffset + end.row
    let clippedStartRow = max(0, startRow)
    let clippedEndRow = min(totalRows - 1, endRow)
    guard clippedStartRow <= clippedEndRow else { return [] }

    if clippedStartRow == clippedEndRow {
      let sCol = (startRow == clippedStartRow) ? min(start.col, cols - 1) : 0
      let eCol = (endRow == clippedEndRow) ? min(end.col + 1, cols) : cols
      guard eCol > sCol else { return [] }
      return [(row: clippedStartRow, startCol: sCol, endCol: eCol)]
    }

    var segs: [(row: Int, startCol: Int, endCol: Int)] = []
    let firstStartCol = (startRow == clippedStartRow) ? start.col : 0
    segs.append((row: clippedStartRow, startCol: firstStartCol, endCol: cols))
    for row in (clippedStartRow + 1)..<clippedEndRow {
      segs.append((row: row, startCol: 0, endCol: cols))
    }
    let lastEndCol = (endRow == clippedEndRow) ? end.col + 1 : cols
    segs.append((row: clippedEndRow, startCol: 0, endCol: lastEndCol))
    return segs
  }

  private static func snapshotLineText(
    from snap: LabanSnapshot,
    row: Int,
    startCol: Int,
    endCol: Int,
    trimTrailing: Bool = true
  ) -> String {
    let rows = Int(snap.rows)
    let cols = Int(snap.cols)
    guard row >= 0, row < rows, startCol >= 0, endCol > startCol,
      let cells = snap.cells,
      let storage = snap.utf8_storage
    else { return "" }

    var line = ""
    for col in startCol..<min(endCol, cols) {
      let cell = cells[row * cols + col]
      if cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL) {
        continue
      }
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
    return trimTrailing ? rightTrim(line) : line
  }

  private static func scrollbackLineText(
    from scrollback: ScrollbackBlock,
    bytes: [UInt8],
    row: Int
  ) -> String? {
    guard row >= 0, row < scrollback.rowOffsets.count else { return nil }
    let start = max(0, min(scrollback.rowOffsets[row], bytes.count))
    var end: Int
    if row + 1 < scrollback.rowOffsets.count {
      end = max(start, min(scrollback.rowOffsets[row + 1], bytes.count))
      if end > start, bytes[end - 1] == 0x0A { end -= 1 }
    } else {
      end = bytes.count
    }
    while end > start, bytes[end - 1] == 0x0A || bytes[end - 1] == 0 {
      end -= 1
    }
    return String(decoding: bytes[start..<end], as: UTF8.self)
  }

  private static func plainLineText(
    from row: String,
    startCol: Int,
    endCol: Int,
    clusters: [ScrollbackBlock.ClusterWidth]? = nil
  ) -> String {
    guard endCol > startCol else { return "" }

    // Engine-width path: walk the row by the engine's carried cluster byte
    // boundaries and widths, so a wide cluster that mode 2027 collapsed to two
    // columns is selected by its two-column span — not the scalar table's
    // re-derivation. Falls back to the scalar walk if the carried boundaries do
    // not tile the row bytes.
    if let clusters,
      let engineLine = plainLineTextFromClusters(
        row: row, startCol: startCol, endCol: endCol, clusters: clusters)
    {
      return engineLine
    }

    var col = 0
    var line = ""
    for character in row {
      let nextCol = col + TerminalDisplayWidth.cells(of: character)
      if col >= startCol && col < endCol {
        line.append(character)
      }
      col = nextCol
      if col >= endCol { break }
    }
    return rightTrim(line)
  }

  private static func plainLineTextFromClusters(
    row: String,
    startCol: Int,
    endCol: Int,
    clusters: [ScrollbackBlock.ClusterWidth]
  ) -> String? {
    let bytes = Array(row.utf8)
    var byteIndex = 0
    var col = 0
    var selected: [UInt8] = []
    for cluster in clusters {
      if byteIndex >= bytes.count { break }
      guard cluster.byteLength > 0, byteIndex + cluster.byteLength <= bytes.count else {
        return nil
      }
      let nextCol = col + cluster.columns
      if col >= startCol && col < endCol {
        selected.append(contentsOf: bytes[byteIndex..<(byteIndex + cluster.byteLength)])
      }
      byteIndex += cluster.byteLength
      col = nextCol
      if col >= endCol { break }
    }
    // The carried clusters must tile the row bytes up to wherever the column
    // window ended. Per-cluster overrun is rejected above. Here we also reject
    // *under*-tiling: if the clusters ran out before the selection window ended
    // (`col < endCol`) yet row bytes remain undescribed (`byteIndex <
    // bytes.count`), the carried widths do not cover the columns we still needed,
    // so the layout is inconsistent and we defer to the scalar fallback rather
    // than return a partial line. (When `col >= endCol` we stopped at the window
    // edge, so leftover row bytes beyond it are expected and fine; when the row
    // is fully tiled but shorter than `endCol`, that is also fine.)
    if col < endCol && byteIndex < bytes.count { return nil }
    return rightTrim(String(decoding: selected, as: UTF8.self))
  }

  private static func rightTrim(_ text: String) -> String {
    text.replacingOccurrences(
      of: "[\\t\\n\\r \\f\\v]+$",
      with: "",
      options: .regularExpression
    )
  }
}
