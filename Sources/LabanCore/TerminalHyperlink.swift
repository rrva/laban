import Foundation
import LabanTerminalCore

public enum TerminalHyperlink {
  public static func uri(atRow row: Int, col: Int, in snapshot: LabanSnapshot) -> String? {
    if let explicit = explicitHyperlinkURI(atRow: row, col: col, in: snapshot) {
      return explicit
    }
    return plainHTTPURL(atRow: row, col: col, in: snapshot)
  }

  private static func explicitHyperlinkURI(
    atRow row: Int,
    col: Int,
    in snapshot: LabanSnapshot
  ) -> String? {
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

  static func plainHTTPURL(atRow row: Int, col: Int, in snapshot: LabanSnapshot) -> String? {
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard row >= 0, row < rows, col >= 0, col < cols else { return nil }

    // Programs print long URLs (aws sso/oidc authorize links, presigned S3
    // URLs) that soft-wrap across visual rows. Rejoin the wrapped logical
    // line — same rule as selection/copy — so the whole URL is clickable
    // instead of a truncated first-row fragment. Without wrap flags (ABI
    // fallback) this degenerates to the single clicked row.
    var lineStart = row
    while lineStart > 0, rowIsSoftWrapped(snapshot, row: lineStart - 1) {
      lineStart -= 1
    }
    var lineEnd = row
    while lineEnd + 1 < rows, rowIsSoftWrapped(snapshot, row: lineEnd) {
      lineEnd += 1
    }

    var text = ""
    var clickedBounds: (lower: Int, upper: Int)?
    for lineRow in lineStart...lineEnd {
      guard let rowText = visibleRowText(row: lineRow, cols: cols, snapshot: snapshot)
      else {
        return nil
      }
      if lineRow == row {
        guard let cellRange = rowText.cellRanges[col] else { return nil }
        clickedBounds = (
          lower: text.count + rowText.text.distance(
            from: rowText.text.startIndex, to: cellRange.lowerBound),
          upper: text.count + rowText.text.distance(
            from: rowText.text.startIndex, to: cellRange.upperBound)
        )
      }
      text += rowText.text
    }
    guard let clickedBounds else { return nil }
    let clickedRange = text.index(text.startIndex, offsetBy: clickedBounds.lower)
      ..< text.index(text.startIndex, offsetBy: clickedBounds.upper)

    let pattern = #"https?://[^\s<>"']+"#
    var searchRange = text.startIndex..<text.endIndex
    while let match = text.range(
      of: pattern,
      options: [.regularExpression, .caseInsensitive],
      range: searchRange
    ) {
      if let trimmed = trimPlainURLRange(match, in: text),
        rangesOverlap(clickedRange, trimmed)
      {
        let candidate = String(text[trimmed])
        if isBrowserHTTPURL(candidate) {
          return candidate
        }
      }
      searchRange = match.upperBound..<text.endIndex
    }
    return nil
  }

  private static func rowIsSoftWrapped(_ snapshot: LabanSnapshot, row: Int) -> Bool {
    guard row >= 0, let flags = snapshot.wrapped_rows, row < snapshot.wrapped_row_count
    else { return false }
    return flags[row] != 0
  }

  private struct VisibleRowText {
    var text: String
    var cellRanges: [Range<String.Index>?]
  }

  private static func visibleRowText(
    row: Int,
    cols: Int,
    snapshot: LabanSnapshot
  ) -> VisibleRowText? {
    guard let cells = snapshot.cells else { return nil }
    let rowStart = row * cols
    var text = ""
    var cellRanges = [Range<String.Index>?](repeating: nil, count: cols)

    for col in 0..<cols {
      let cell = cells[rowStart + col]
      if cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL)
        || (cell.flags & UInt16(LABAN_CELL_FLAG_INVISIBLE)) != 0
      {
        appendCell(" ", col: col, text: &text, cellRanges: &cellRanges)
        continue
      }

      if cell.utf8_length > 0, let storage = snapshot.utf8_storage {
        let offset = Int(cell.utf8_offset)
        let length = Int(cell.utf8_length)
        let ptr = UnsafeRawPointer(storage).advanced(by: offset)
        let buf = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: length
        )
        if let cellText = String(bytes: buf, encoding: .utf8), !cellText.isEmpty {
          appendCell(cellText, col: col, text: &text, cellRanges: &cellRanges)
          continue
        }
      }

      appendCell(" ", col: col, text: &text, cellRanges: &cellRanges)
    }

    return VisibleRowText(text: text, cellRanges: cellRanges)
  }

  private static func appendCell(
    _ value: String,
    col: Int,
    text: inout String,
    cellRanges: inout [Range<String.Index>?]
  ) {
    let start = text.endIndex
    text.append(value)
    let end = text.endIndex
    cellRanges[col] = start..<end
  }

  private static func trimPlainURLRange(
    _ range: Range<String.Index>,
    in text: String
  ) -> Range<String.Index>? {
    var end = range.upperBound
    while end > range.lowerBound {
      let previous = text.index(before: end)
      let charRange = previous..<end
      let scalars = text[charRange].unicodeScalars
      guard scalars.count == 1,
        let scalar = scalars.first,
        trailingPlainURLPunctuation.contains(scalar)
      else {
        break
      }
      end = previous
    }
    guard range.lowerBound < end else { return nil }
    return range.lowerBound..<end
  }

  private static let trailingPlainURLPunctuation = CharacterSet(
    charactersIn: ".,;:!)]}>\"'"
  )

  private static func rangesOverlap(
    _ lhs: Range<String.Index>,
    _ rhs: Range<String.Index>
  ) -> Bool {
    lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
  }

  private static func isBrowserHTTPURL(_ value: String) -> Bool {
    guard let url = URL(string: value),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host,
      !host.isEmpty
    else {
      return false
    }
    return true
  }
}
