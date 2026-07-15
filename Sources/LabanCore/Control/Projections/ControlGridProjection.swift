import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore

public enum ControlGridProjection {
  public static func rgbaArray(_ color: UInt32) -> [Int] {
    [
      Int((color >> 24) & 0xFF),
      Int((color >> 16) & 0xFF),
      Int((color >> 8) & 0xFF),
      Int(color & 0xFF),
    ]
  }

  public static func rectResponse(_ rect: CGRect) -> RectResponse {
    RectResponse(
      x: Int(rect.origin.x), y: Int(rect.origin.y),
      width: Int(rect.size.width), height: Int(rect.size.height)
    )
  }

  public static func sessionGridResponse(
    from snapshot: LabandSnapshotResponse,
    maxCells: Int
  ) -> SessionGridResponse {
    var result: [SessionGridCellResponse] = []
    result.reserveCapacity(min(snapshot.cells.count, maxCells))
    var truncated = false
    for cell in snapshot.cells where !cell.text.isEmpty {
      if result.count >= maxCells {
        truncated = true
        break
      }
      result.append(
        SessionGridCellResponse(
          row: cell.row,
          col: cell.col,
          text: cell.text,
          foreground: rgbaArray(cell.foregroundRGBA),
          background: rgbaArray(cell.backgroundRGBA),
          attributes: TextAttributes(cellFlags: cell.flags).names,
          wide: "narrow",
          hyperlink: nil
        ))
    }
    return SessionGridResponse(
      rows: snapshot.rows,
      cols: snapshot.cols,
      cells: result,
      truncated: truncated
    )
  }

  public static func sessionGridResponse(
    from snapshotPointer: UnsafePointer<LabanSnapshot>,
    maxCells: Int
  ) -> SessionGridResponse {
    let snapshot = snapshotPointer.pointee
    let rows = max(Int(snapshot.rows), 1)
    let cols = max(Int(snapshot.cols), 1)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else {
      return SessionGridResponse(rows: rows, cols: cols, cells: [], truncated: false)
    }

    let links = snapshotHyperlinks(snapshot)
    var result: [SessionGridCellResponse] = []
    result.reserveCapacity(min(Int(snapshot.cell_count), maxCells))
    var truncated = false

    for row in 0..<rows {
      for col in 0..<cols {
        let idx = row * cols + col
        guard idx < Int(snapshot.cell_count) else { continue }
        let cell = cells[idx]
        guard cell.utf8_length > 0 else { continue }

        let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buffer = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length)
        )
        guard let text = String(bytes: buffer, encoding: .utf8), !text.isEmpty else { continue }

        if result.count >= maxCells {
          truncated = true
          break
        }

        let hyperlink: String? = {
          let id = Int(cell.hyperlink_id)
          guard id > 0, id <= links.count else { return nil }
          return links[id - 1]
        }()

        result.append(
          SessionGridCellResponse(
            row: row,
            col: col,
            text: text,
            foreground: rgbaArray(cell.foreground_rgba),
            background: rgbaArray(cell.background_rgba),
            attributes: TextAttributes(cellFlags: cell.flags).names,
            wide: wideName(cell.wide),
            hyperlink: hyperlink
          ))
      }
      if truncated { break }
    }

    return SessionGridResponse(rows: rows, cols: cols, cells: result, truncated: truncated)
  }

  private static func snapshotHyperlinks(_ snapshot: LabanSnapshot) -> [String] {
    let count = Int(snapshot.hyperlink_count)
    guard count > 0, let table = snapshot.hyperlink_uris else { return [] }
    var result: [String] = []
    result.reserveCapacity(count)
    for idx in 0..<count {
      result.append(table[idx].map { String(cString: $0) } ?? "")
    }
    return result
  }

  private static func wideName(_ wide: UInt8) -> String {
    switch Int(wide) {
    case Int(LABAN_CELL_WIDE_WIDE): return "wide"
    case Int(LABAN_CELL_WIDE_SPACER_TAIL): return "spacerTail"
    case Int(LABAN_CELL_WIDE_SPACER_HEAD): return "spacerHead"
    default: return "narrow"
    }
  }
}
