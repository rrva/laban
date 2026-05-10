import AppKit
import LabanCore

enum TerminalTextInputGeometry {
  static func cursorRect(
    rows: Int,
    cursorRow: Int,
    cursorCol: Int,
    sidebarWidth: CGFloat,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    boundsHeight: CGFloat,
    insets: NSEdgeInsets
  ) -> NSRect {
    let clampedRows = max(rows, 1)
    let row = min(max(cursorRow, 0), clampedRows - 1)
    let col = max(cursorCol, 0)
    let gridOriginY = TerminalSurfaceController.terminalGridOriginY(
      viewportHeight: boundsHeight,
      rows: clampedRows,
      cellHeight: cellHeight,
      insets: TerminalSurfaceInsets(
        top: insets.top,
        left: insets.left,
        bottom: insets.bottom,
        right: insets.right
      ))

    return NSRect(
      x: sidebarWidth + insets.left + CGFloat(col) * cellWidth,
      y: gridOriginY + CGFloat(clampedRows - 1 - row) * cellHeight,
      width: cellWidth,
      height: cellHeight
    )
  }
}
