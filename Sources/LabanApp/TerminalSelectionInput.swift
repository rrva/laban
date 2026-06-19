import AppKit
import Foundation
import LabanCore
import LabanTerminalCore

/// One end of a view selection. The captured viewport offset is libghostty's
/// authoritative scroll position at the time of the click or drag update, so
/// rendered selection rows can track the terminal content through scrolling.
struct TerminalSelectionPoint: Equatable {
  var row: Int
  var col: Int
  var viewportOffsetAtCapture: Int

  func visibleRow(currentViewportOffset: Int) -> Int {
    row + (viewportOffsetAtCapture - currentViewportOffset)
  }
}

enum TerminalSelectionMode {
  case char
  case word
  case line
}

enum TerminalSelectionInput {
  struct GridGeometry {
    var boundsWidth: CGFloat
    var boundsHeight: CGFloat
    var sidebarWidth: CGFloat
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var rows: Int
    var insets: NSEdgeInsets

    var clampedRows: Int { max(rows, 1) }

    var cols: Int {
      guard cellWidth > 0 else { return 1 }
      return max(1, Int((boundsWidth - sidebarWidth - insets.left - insets.right) / cellWidth))
    }

    var gridOriginY: CGFloat {
      TerminalSurfaceController.terminalGridOriginY(
        viewportHeight: boundsHeight,
        rows: clampedRows,
        cellHeight: cellHeight,
        insets: TerminalSurfaceInsets(
          top: insets.top,
          left: insets.left,
          bottom: insets.bottom,
          right: insets.right
        ))
    }
  }

  static func terminalCell(
    at point: NSPoint,
    geometry: GridGeometry
  ) -> TerminalCellCoordinate? {
    let x = point.x - geometry.sidebarWidth - geometry.insets.left
    guard geometry.cellWidth > 0, geometry.cellHeight > 0 else { return nil }
    let yLocal = point.y - geometry.gridOriginY
    guard x >= 0, yLocal >= 0 else { return nil }

    let col = Int(x / geometry.cellWidth)
    let row = geometry.clampedRows - 1 - Int(yLocal / geometry.cellHeight)
    guard row >= 0, row < geometry.clampedRows, col >= 0 else { return nil }

    return TerminalCellCoordinate(row: row, col: col)
  }

  static func clampedPoint(
    at point: NSPoint,
    geometry: GridGeometry,
    viewportOffset: Int
  ) -> TerminalSelectionPoint {
    guard geometry.cellWidth > 0, geometry.cellHeight > 0 else {
      return TerminalSelectionPoint(row: 0, col: 0, viewportOffsetAtCapture: viewportOffset)
    }
    let x = max(0, point.x - geometry.sidebarWidth - geometry.insets.left)
    let yLocal = point.y - geometry.gridOriginY
    let col = min(geometry.cols - 1, max(0, Int(x / geometry.cellWidth)))
    let unclampedRow = geometry.clampedRows - 1 - Int(yLocal / geometry.cellHeight)
    let row = min(max(0, unclampedRow), geometry.clampedRows - 1)
    return TerminalSelectionPoint(row: row, col: col, viewportOffsetAtCapture: viewportOffset)
  }

  static func terminalSelection(
    sessionId: Session.ID,
    anchor: TerminalSelectionPoint?,
    focus: TerminalSelectionPoint?,
    currentViewportOffset: Int
  ) -> TerminalSelection? {
    guard let anchor, let focus else { return nil }
    return TerminalSelection(
      sessionId: sessionId,
      anchor: TerminalCellCoordinate(
        row: anchor.visibleRow(currentViewportOffset: currentViewportOffset),
        col: anchor.col),
      focus: TerminalCellCoordinate(
        row: focus.visibleRow(currentViewportOffset: currentViewportOffset),
        col: focus.col)
    )
  }

  /// Anchor/focus that select the entire buffer — every scrollback row, full
  /// width — independent of the current scroll position. A point's absolute
  /// row is `row + viewportOffsetAtCapture`, so capturing at offset 0 pins the
  /// anchor to absolute row 0 and the focus to the last row no matter where the
  /// viewport is scrolled when the user invokes Select All. Returns nil for an
  /// empty buffer.
  static func selectAllPoints(
    totalRows: Int,
    cols: Int
  ) -> (anchor: TerminalSelectionPoint, focus: TerminalSelectionPoint)? {
    guard totalRows > 0, cols > 0 else { return nil }
    return (
      TerminalSelectionPoint(row: 0, col: 0, viewportOffsetAtCapture: 0),
      TerminalSelectionPoint(row: totalRows - 1, col: cols - 1, viewportOffsetAtCapture: 0)
    )
  }

  static func wordBounds(
    row: Int,
    col: Int,
    in snapshot: LabanSnapshot
  ) -> (start: Int, end: Int) {
    let cols = Int(snapshot.cols)
    guard row >= 0,
      row < Int(snapshot.rows),
      col >= 0,
      col < cols,
      let cells = snapshot.cells,
      let storage = snapshot.utf8_storage
    else { return (col, col) }

    var startCol = col
    var endCol = col
    while startCol > 0,
      isWord(cellScalar(at: startCol - 1, row: row, cols: cols, cells: cells, storage: storage))
    {
      startCol -= 1
    }
    while endCol < cols - 1,
      isWord(cellScalar(at: endCol + 1, row: row, cols: cols, cells: cells, storage: storage))
    {
      endCol += 1
    }
    return (startCol, endCol)
  }

  private static func cellScalar(
    at col: Int,
    row: Int,
    cols: Int,
    cells: UnsafePointer<LabanCell>,
    storage: UnsafePointer<CChar>
  ) -> Unicode.Scalar? {
    let cell = cells[row * cols + col]
    guard cell.utf8_length > 0 else { return nil }
    let buffer = UnsafeBufferPointer<UInt8>(
      start: UnsafeRawPointer(storage)
        .advanced(by: Int(cell.utf8_offset))
        .assumingMemoryBound(to: UInt8.self),
      count: Int(cell.utf8_length))
    let text = String(bytes: buffer, encoding: .utf8) ?? ""
    return text.unicodeScalars.first
  }

  private static func isWord(_ scalar: Unicode.Scalar?) -> Bool {
    guard let scalar else { return false }
    if CharacterSet.alphanumerics.contains(scalar) { return true }
    return "-_./:~@".unicodeScalars.contains(scalar)
  }
}
