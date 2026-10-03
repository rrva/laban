import CoreText
import Foundation

/// Implicit BiDi for one terminal row: where each logical cell is drawn.
///
/// The terminal engine stores rows in logical (written) order. A row holding
/// strong right-to-left text (Hebrew, Arabic, ...) is displayed in visual
/// order per the Unicode Bidirectional Algorithm with a left-to-right base
/// paragraph direction, so `abc שלום` shows `abc` then the Hebrew mirrored.
public struct TerminalBidiRowLayout: Equatable, Sendable {
  /// Visual column of each logical column (spacer tails follow their wide
  /// cell). Columns past the row's content map to themselves.
  public let visualColumn: [Int]
  /// Whether each logical column lies in a right-to-left run.
  public let isRightToLeft: [Bool]
  /// Logical column drawn at each visual column (inverse of `visualColumn`).
  public let logicalColumn: [Int]
}

public enum TerminalBidi {
  /// One engine cell of a row: its first column, column span and text.
  public struct Cell: Equatable, Sendable {
    public var column: Int
    public var width: Int
    public var text: String

    public init(column: Int, width: Int, text: String) {
      self.column = column
      self.width = width
      self.text = text
    }
  }

  /// Cheap pre-check on a cell's UTF-8 bytes: every strong right-to-left
  /// scalar is at or above U+0590, whose UTF-8 lead byte is 0xD6 or higher.
  @inline(__always)
  public static func mayBeRightToLeft(leadByte: UInt8) -> Bool {
    leadByte >= 0xD6
  }

  /// Strong right-to-left scalars: Hebrew, Arabic, Syriac, Thaana, N'Ko,
  /// Samaritan, Mandaic, Arabic Extended, and their presentation forms, plus
  /// the RTL supplementary blocks.
  public static func isStrongRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF,
      0x10800...0x10FFF, 0x1E800...0x1EFFF:
      // Combining marks inside these blocks are not strong; they attach to
      // a strong base, which is what makes the row need reordering.
      return !scalar.properties.isGraphemeExtend
    default:
      return false
    }
  }

  /// Letters of scripts whose letters join (Arabic, Syriac, N'Ko, Mongolian
  /// and Arabic presentation forms); a renderer shapes runs of these as a line.
  public static func isJoiningScript(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0600...0x08FF, 0x1800...0x18AF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
      return true
    default:
      return false
    }
  }

  public static func containsStrongRightToLeft(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isStrongRightToLeft)
  }

  /// Visual layout of a row, or nil when no cell holds strong RTL text
  /// (the row then draws in logical order, unchanged).
  public static func layout(cells: [Cell], columns: Int) -> TerminalBidiRowLayout? {
    guard columns > 0, cells.contains(where: { containsStrongRightToLeft($0.text) }) else {
      return nil
    }
    // Row string with each cell's UTF-16 start, so CoreText runs map back to
    // cells.
    var string = ""
    var utf16Starts: [Int] = []
    utf16Starts.reserveCapacity(cells.count)
    var utf16Offset = 0
    for cell in cells {
      utf16Starts.append(utf16Offset)
      string += cell.text
      utf16Offset += cell.text.utf16.count
    }
    let attributed = NSMutableAttributedString(string: string)
    var direction = CTWritingDirection.leftToRight
    let paragraphStyle = withUnsafeBytes(of: &direction) { raw in
      var setting = CTParagraphStyleSetting(
        spec: .baseWritingDirection,
        valueSize: MemoryLayout<CTWritingDirection>.size,
        value: raw.baseAddress!)
      return CTParagraphStyleCreate(&setting, 1)
    }
    attributed.addAttribute(
      kCTParagraphStyleAttributeName as NSAttributedString.Key,
      value: paragraphStyle,
      range: NSRange(location: 0, length: attributed.length))
    let line = CTLineCreateWithAttributedString(attributed)

    // Cells in visual order: CoreText returns runs in visual order; a
    // right-to-left run lists its cells from last to first.
    var visualCells: [(cell: Int, rightToLeft: Bool)] = []
    visualCells.reserveCapacity(cells.count)
    var placed = Set<Int>()
    for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
      let range = CTRunGetStringRange(run)
      let rightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
      let lower = range.location
      let upper = range.location + range.length
      var runCells: [Int] = []
      for (index, start) in utf16Starts.enumerated() where start >= lower && start < upper {
        runCells.append(index)
      }
      if rightToLeft { runCells.reverse() }
      for index in runCells where placed.insert(index).inserted {
        visualCells.append((index, rightToLeft))
      }
    }
    // Cells CoreText produced no glyph run for (e.g. controls) keep their
    // logical slot after everything else.
    for index in cells.indices where !placed.contains(index) {
      visualCells.append((index, false))
    }

    var visualColumn = Array(0..<columns)
    var isRightToLeft = Array(repeating: false, count: columns)
    let firstColumn = cells.first?.column ?? 0
    var next = firstColumn
    for (index, rightToLeft) in visualCells {
      let cell = cells[index]
      for offset in 0..<max(1, cell.width) where cell.column + offset < columns {
        visualColumn[cell.column + offset] = min(columns - 1, next + offset)
        isRightToLeft[cell.column + offset] = rightToLeft
      }
      next += max(1, cell.width)
    }
    var logicalColumn = Array(0..<columns)
    for (logical, visual) in visualColumn.enumerated() where visual < columns {
      logicalColumn[visual] = logical
    }
    return TerminalBidiRowLayout(
      visualColumn: visualColumn, isRightToLeft: isRightToLeft, logicalColumn: logicalColumn)
  }
}
