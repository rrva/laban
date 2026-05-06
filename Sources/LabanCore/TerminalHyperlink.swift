import Foundation
import LabanTerminalCore

public enum TerminalHyperlink {
  public static func uri(atRow row: Int, col: Int, in snapshot: LabanSnapshot) -> String? {
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard row >= 0, row < rows, col >= 0, col < cols,
      let cells = snapshot.cells,
      let hyperlinkURIs = snapshot.hyperlink_uris
    else {
      return nil
    }

    let cell = cells[row * cols + col]
    let id = Int(cell.hyperlink_id)
    guard id > 0, id <= Int(snapshot.hyperlink_count),
      let uri = hyperlinkURIs[id - 1]
    else {
      return nil
    }
    return String(cString: uri)
  }
}
