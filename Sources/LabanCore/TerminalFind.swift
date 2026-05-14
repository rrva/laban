import Foundation
import LabanTerminalCore

public struct TerminalFindMatch: Codable, Equatable, Sendable {
  public let row: Int
  public let startColumn: Int
  public let endColumn: Int

  public init(row: Int, startColumn: Int, endColumn: Int) {
    self.row = row
    self.startColumn = startColumn
    self.endColumn = endColumn
  }
}

public enum TerminalFindCaseMode: Sendable {
  case smart
  case literal
}

public struct ScrollbackBlock: Equatable, Sendable {
  public let text: String
  public let rowOffsets: [Int]

  public init(text: String, rowOffsets: [Int]) {
    self.text = text
    self.rowOffsets = rowOffsets
  }

  public var rows: Int { rowOffsets.count }
}

/// Literal terminal-output search.
///
/// Matching is byte-oriented to mirror libghostty-vt's current search engine:
/// smart case folds ASCII A-Z only when the needle contains no uppercase ASCII.
/// Unicode bytes still match literally, but Unicode case folding is intentionally
/// not applied. Soft-wrapped terminal rows are not joined in this version, so a
/// needle spanning a wrap boundary is not found.
public enum TerminalFind {
  public static func search(
    needle: String,
    inSnapshot snapshot: UnsafePointer<LabanSnapshot>,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch] {
    search(needle: needle, inSnapshot: snapshot, rowOffset: 0, caseMode: caseMode)
  }

  static func search(
    needle: String,
    inSnapshot snapshot: UnsafePointer<LabanSnapshot>,
    rowOffset: Int,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch] {
    let needleBytes = Array(needle.utf8)
    guard !needleBytes.isEmpty else { return [] }

    let foldASCII = shouldFoldASCII(needleBytes: needleBytes, caseMode: caseMode)
    let preparedNeedle = foldASCII ? needleBytes.map(foldedASCIIByte) : needleBytes
    let snapshotValue = snapshot.pointee
    let rows = Int(snapshotValue.rows)
    let cols = Int(snapshotValue.cols)
    guard rows > 0, cols > 0, let cells = snapshotValue.cells else { return [] }

    var matches: [TerminalFindMatch] = []
    for row in 0..<rows {
      let buffer = rowBuffer(from: snapshotValue, cells: cells, row: row, cols: cols)
      appendPreparedNeedleMatches(
        preparedNeedle,
        in: buffer,
        row: row + rowOffset,
        foldASCII: foldASCII,
        to: &matches
      )
    }
    return matches
  }

  public static func searchScrollbackAndViewport(
    needle: String,
    scrollback: ScrollbackBlock,
    viewportSnapshot: UnsafePointer<LabanSnapshot>,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch] {
    search(needle: needle, in: scrollback, caseMode: caseMode)
  }

  public static func search(
    needle: String,
    in scrollback: ScrollbackBlock,
    caseMode: TerminalFindCaseMode = .smart
  ) -> [TerminalFindMatch] {
    let needleBytes = Array(needle.utf8)
    guard !needleBytes.isEmpty else { return [] }

    let textBytes = Array(scrollback.text.utf8)
    guard !textBytes.isEmpty, !scrollback.rowOffsets.isEmpty else { return [] }

    let foldASCII = shouldFoldASCII(needleBytes: needleBytes, caseMode: caseMode)
    let preparedNeedle = foldASCII ? needleBytes.map(foldedASCIIByte) : needleBytes
    var matches: [TerminalFindMatch] = []

    for row in 0..<scrollback.rowOffsets.count {
      let start = max(0, min(scrollback.rowOffsets[row], textBytes.count))
      var end: Int
      if row + 1 < scrollback.rowOffsets.count {
        end = max(start, min(scrollback.rowOffsets[row + 1], textBytes.count))
        if end > start, textBytes[end - 1] == 0x0A { end -= 1 }
      } else {
        end = textBytes.count
      }
      while end > start, textBytes[end - 1] == 0x0A || textBytes[end - 1] == 0 {
        end -= 1
      }
      guard end > start else { continue }
      if isASCII(textBytes, start: start, end: end) {
        appendASCIIBytesMatches(
          preparedNeedle,
          in: textBytes,
          start: start,
          end: end,
          row: row,
          foldASCII: foldASCII,
          to: &matches
        )
      } else {
        let rowBytes = Array(textBytes[start..<end])
        let buffer = rowBuffer(fromUTF8Row: rowBytes)
        appendPreparedNeedleMatches(
          preparedNeedle,
          in: buffer,
          row: row,
          foldASCII: foldASCII,
          to: &matches
        )
      }
    }

    return matches
  }

  private struct RowBuffer {
    var bytes: [UInt8] = []
    var startColumnByByte: [Int] = []
    var endColumnByByte: [Int] = []
  }

  private static func rowBuffer(
    from snapshot: LabanSnapshot,
    cells: UnsafePointer<LabanCell>,
    row: Int,
    cols: Int
  ) -> RowBuffer {
    var result = RowBuffer()
    result.bytes.reserveCapacity(cols)
    result.startColumnByByte.reserveCapacity(cols)
    result.endColumnByByte.reserveCapacity(cols)

    let rowStart = row * cols
    for col in 0..<cols {
      let cell = cells[rowStart + col]
      if cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL) {
        continue
      }

      let cellWidth = cell.wide == UInt8(LABAN_CELL_WIDE_WIDE) ? 2 : 1
      let endColumn = min(cols, col + cellWidth)
      let invisible = (cell.flags & UInt16(LABAN_CELL_FLAG_INVISIBLE)) != 0
      guard !invisible, cell.utf8_length > 0, let storage = snapshot.utf8_storage else {
        appendByte(0x20, startColumn: col, endColumn: min(cols, col + 1), to: &result)
        continue
      }

      let offset = Int(cell.utf8_offset)
      let length = Int(cell.utf8_length)
      guard offset >= 0, length > 0, offset + length <= snapshot.utf8_storage_len else {
        appendByte(0x20, startColumn: col, endColumn: min(cols, col + 1), to: &result)
        continue
      }

      let ptr = UnsafeRawPointer(storage).advanced(by: offset)
      let bytes = UnsafeBufferPointer<UInt8>(
        start: ptr.assumingMemoryBound(to: UInt8.self),
        count: length
      )
      for byte in bytes {
        appendByte(byte, startColumn: col, endColumn: endColumn, to: &result)
      }
    }

    return result
  }

  private static func rowBuffer(fromUTF8Row bytes: [UInt8]) -> RowBuffer {
    var result = RowBuffer()
    result.bytes.reserveCapacity(bytes.count)
    result.startColumnByByte.reserveCapacity(bytes.count)
    result.endColumnByByte.reserveCapacity(bytes.count)

    let rowString = String(decoding: bytes, as: UTF8.self)
    var column = 0
    for character in rowString {
      let characterBytes = Array(String(character).utf8)
      let nextColumn = column + 1
      for byte in characterBytes {
        appendByte(byte, startColumn: column, endColumn: nextColumn, to: &result)
      }
      column = nextColumn
    }
    return result
  }

  private static func appendByte(
    _ byte: UInt8,
    startColumn: Int,
    endColumn: Int,
    to buffer: inout RowBuffer
  ) {
    buffer.bytes.append(byte)
    buffer.startColumnByByte.append(startColumn)
    buffer.endColumnByByte.append(endColumn)
  }

  private static func appendPreparedNeedleMatches(
    _ preparedNeedle: [UInt8],
    in buffer: RowBuffer,
    row: Int,
    foldASCII: Bool,
    to result: inout [TerminalFindMatch]
  ) {
    guard !preparedNeedle.isEmpty, buffer.bytes.count >= preparedNeedle.count else { return }

    var index = 0
    let lastStart = buffer.bytes.count - preparedNeedle.count
    while index <= lastStart {
      if matchesPreparedNeedle(
        preparedNeedle,
        in: buffer.bytes,
        at: index,
        foldASCII: foldASCII
      ) {
        result.append(
          TerminalFindMatch(
            row: row,
            startColumn: buffer.startColumnByByte[index],
            endColumn: buffer.endColumnByByte[index + preparedNeedle.count - 1]
          ))
        index += preparedNeedle.count
      } else {
        index += 1
      }
    }
  }

  private static func appendASCIIBytesMatches(
    _ preparedNeedle: [UInt8],
    in bytes: [UInt8],
    start: Int,
    end: Int,
    row: Int,
    foldASCII: Bool,
    to result: inout [TerminalFindMatch]
  ) {
    let count = end - start
    guard !preparedNeedle.isEmpty, count >= preparedNeedle.count else { return }

    var index = start
    let lastStart = end - preparedNeedle.count
    while index <= lastStart {
      if matchesPreparedNeedle(
        preparedNeedle,
        in: bytes,
        at: index,
        foldASCII: foldASCII
      ) {
        let startColumn = index - start
        result.append(
          TerminalFindMatch(
            row: row,
            startColumn: startColumn,
            endColumn: startColumn + preparedNeedle.count
          ))
        index += preparedNeedle.count
      } else {
        index += 1
      }
    }
  }

  private static func matchesPreparedNeedle(
    _ preparedNeedle: [UInt8],
    in bytes: [UInt8],
    at index: Int,
    foldASCII: Bool
  ) -> Bool {
    for n in 0..<preparedNeedle.count {
      let haystack = foldASCII ? foldedASCIIByte(bytes[index + n]) : bytes[index + n]
      if haystack != preparedNeedle[n] {
        return false
      }
    }
    return true
  }

  private static func isASCII(_ bytes: [UInt8], start: Int, end: Int) -> Bool {
    for index in start..<end where bytes[index] >= 0x80 {
      return false
    }
    return true
  }

  private static func shouldFoldASCII(
    needleBytes: [UInt8],
    caseMode: TerminalFindCaseMode
  ) -> Bool {
    guard case .smart = caseMode else { return false }
    return !needleBytes.contains { (0x41...0x5A).contains($0) }
  }

  private static func foldedASCIIByte(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
  }
}
