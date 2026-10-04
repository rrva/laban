import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore

/// Implicit BiDi display for rows holding right-to-left text. Rows without
/// strong RTL text never reach this code; they render exactly as before.
extension FrameProducer {
  /// One engine cell of a BiDi row, in logical order.
  struct BidiCell {
    var column: Int
    var width: Int
    var text: String
    var visuals: ResolvedCellVisuals
  }

  // MARK: - Layouts

  /// Per-row BiDi layouts for a local snapshot, keyed by row; empty when the
  /// setting is off or no row holds strong right-to-left text.
  func bidiLayouts(
    snapshot: LabanSnapshot, rows: Int, cols: Int, hyperlinkURIs: [String]
  ) -> [Int: TerminalBidiRowLayout] {
    guard bidiDisplay, let cells = snapshot.cells, let storage = snapshot.utf8_storage else {
      return [:]
    }
    var layouts: [Int: TerminalBidiRowLayout] = [:]
    for row in 0..<rows {
      let rowStart = row * cols
      var mayNeedBidi = false
      for col in 0..<cols {
        let cell = cells[rowStart + col]
        guard cell.utf8_length > 0 else { continue }
        let bytes = UnsafeBufferPointer<UInt8>(
          start: UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
            .assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length))
        // Lead byte first (ASCII, Latin, Cyrillic never qualify), then the
        // real scalar check, so box drawing, emoji and CJK rows stay on the
        // ordinary path.
        guard TerminalBidi.mayBeRightToLeft(leadByte: bytes[0]) else { continue }
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        while case .scalarValue(let scalar) = decoder.decode(&iterator) {
          if TerminalBidi.isStrongRightToLeft(scalar) {
            mayNeedBidi = true
            break
          }
        }
        if mayNeedBidi { break }
      }
      guard mayNeedBidi else { continue }
      let rowCells = localBidiCells(
        cells: cells, storage: storage, rowStart: rowStart, cols: cols,
        hyperlinkURIs: hyperlinkURIs)
      if let layout = TerminalBidi.layout(
        cells: rowCells.map {
          TerminalBidi.Cell(column: $0.column, width: $0.width, text: $0.text)
        },
        columns: cols)
      {
        layouts[row] = layout
      }
    }
    return layouts
  }

  /// Every column of a local row as BiDi cells. Empty cells count as spaces
  /// so the layout covers the whole row; spacer tails fold into their wide
  /// cell.
  func localBidiCells(
    cells: UnsafePointer<LabanCell>,
    storage: UnsafePointer<CChar>,
    rowStart: Int,
    cols: Int,
    hyperlinkURIs: [String]
  ) -> [BidiCell] {
    var result: [BidiCell] = []
    result.reserveCapacity(cols)
    for col in 0..<cols {
      let cell = cells[rowStart + col]
      if cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL) { continue }
      let text: String
      if cell.utf8_length > 0 {
        let bytes = UnsafeBufferPointer<UInt8>(
          start: UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
            .assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length))
        text = String(decoding: bytes, as: UTF8.self)
      } else {
        text = " "
      }
      result.append(
        BidiCell(
          column: col,
          width: cell.wide == UInt8(LABAN_CELL_WIDE_WIDE) ? 2 : 1,
          text: text,
          visuals: resolvedVisuals(for: cell, hyperlinkURIs: hyperlinkURIs)))
    }
    return result
  }

  // MARK: - Emission

  /// Background rects of a BiDi row at visual columns.
  func appendBidiBackgrounds(
    _ rowCells: [BidiCell],
    layout: TerminalBidiRowLayout,
    cellY: CGFloat,
    cw: CGFloat,
    ch: CGFloat,
    defaultBackground: UInt32,
    into cmds: inout [FrameCommand]
  ) {
    for cell in rowCells where cell.visuals.background != defaultBackground {
      let x = originX + CGFloat(layout.visualColumn[cell.column]) * cw
      cmds.append(
        .rect(
          CGRect(x: x, y: cellY, width: CGFloat(cell.width) * cw, height: ch),
          color: cell.visuals.background,
          source: .terminal,
          compositing: .replace))
    }
  }

  /// Glyph runs and procedural cells of a BiDi row. A run holds cells that
  /// share style and direction and sit next to each other on screen; a
  /// right-to-left run is emitted in logical order with `.rightToLeft` at
  /// its leftmost visual column, so renderers mirror it and a shaper sees
  /// the letters in written order (needed for Arabic joining).
  func appendBidiRowGlyphRuns(
    _ rowCells: [BidiCell],
    layout: TerminalBidiRowLayout,
    cellY: CGFloat,
    cw: CGFloat,
    ch: CGFloat,
    into cmds: inout [FrameCommand]
  ) {
    var run: [BidiCell] = []
    var runRightToLeft = false

    func flush() {
      guard let first = run.first else { return }
      let visualStart = run.map { layout.visualColumn[$0.column] }.min() ?? first.column
      var attributes = first.visuals.attributes
      if runRightToLeft { attributes.insert(.rightToLeft) }
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: originX + CGFloat(visualStart) * cw, y: cellY),
          text: runRightToLeft
            ? BidiMirroring.mirrored(run.map(\.text).joined())
            : run.map(\.text).joined(),
          foreground: first.visuals.foreground,
          background: first.visuals.background,
          attributes: attributes,
          source: .terminal,
          underlineStyle: first.visuals.underlineStyle,
          underlineColor: first.visuals.underlineColor,
          hyperlink: first.visuals.hyperlink,
          displayCellCount: run.reduce(0) { $0 + $1.width }))
      run.removeAll(keepingCapacity: true)
    }

    for cell in rowCells {
      let isBlank = cell.text == " " && cell.visuals.underlineStyle == .none
      guard !cell.visuals.isInvisible, !isBlank else {
        flush()
        continue
      }
      if cell.text.unicodeScalars.count == 1, let scalar = cell.text.unicodeScalars.first,
        BoxDrawing.isProceduralCellElement(scalar)
      {
        flush()
        for filled in BoxDrawing.proceduralCellElementRects(
          scalar,
          at: CGPoint(x: originX + CGFloat(layout.visualColumn[cell.column]) * cw, y: cellY),
          cellWidth: cw,
          cellHeight: ch,
          foreground: cell.visuals.foreground)
        {
          cmds.append(.rect(filled.rect, color: filled.color, source: .terminal))
        }
        continue
      }
      let rightToLeft = layout.isRightToLeft[cell.column]
      let singleCharacter = cell.text.count == 1
      if let previous = run.last {
        let previousVisual = layout.visualColumn[previous.column]
        let visual = layout.visualColumn[cell.column]
        let adjacent =
          rightToLeft ? visual == previousVisual - 1 : visual == previousVisual + previous.width
        let sameStyle =
          previous.visuals.foreground == cell.visuals.foreground
          && previous.visuals.background == cell.visuals.background
          && previous.visuals.attrsRaw == cell.visuals.attrsRaw
          && previous.visuals.underlineStyle == cell.visuals.underlineStyle
          && previous.visuals.underlineColor == cell.visuals.underlineColor
          && previous.visuals.hyperlink == cell.visuals.hyperlink
        let canJoin =
          adjacent && sameStyle && rightToLeft == runRightToLeft && previous.width == 1
          && cell.width == 1 && singleCharacter && previous.text.count == 1
          // Cells whose text would merge into one Character (e.g. a Prepend
          // scalar and its base) are drawn apart so each keeps its column.
          && !(FrameProducer.mayJoinClusters(last: previous.text.utf8, next: cell.text.utf8)
            && (previous.text + cell.text).count < 2)
        if !canJoin { flush() }
      }
      if run.isEmpty { runRightToLeft = rightToLeft }
      run.append(cell)
      // Keep the one-column-per-Character invariant: wide or multi-Character
      // cells stand alone.
      if cell.width != 1 || !singleCharacter { flush() }
    }
    flush()
  }

  /// Splits rects covering logical columns of BiDi rows into rects at the
  /// visual columns those cells are drawn at. Rects on other rows pass
  /// through unchanged.
  func bidiRemapped(
    _ rect: CGRect,
    layouts: [Int: TerminalBidiRowLayout],
    rows: Int,
    cols: Int,
    cw: CGFloat,
    ch: CGFloat
  ) -> [CGRect] {
    guard !layouts.isEmpty, cw > 0, ch > 0 else { return [rect] }
    let row = rows - 1 - Int(((rect.minY - originY - contentYOffset) / ch).rounded())
    guard let layout = layouts[row] else { return [rect] }
    let firstColumn = max(0, Int(((rect.minX - originX) / cw).rounded()))
    let lastColumn = min(cols, Int(((rect.maxX - originX) / cw).rounded()))
    guard lastColumn > firstColumn else { return [rect] }
    let visualColumns = (firstColumn..<lastColumn).map { layout.visualColumn[$0] }.sorted()
    var result: [CGRect] = []
    var start = visualColumns[0]
    var end = start + 1
    for column in visualColumns.dropFirst() {
      if column == end {
        end += 1
      } else {
        result.append(
          CGRect(
            x: originX + CGFloat(start) * cw, y: rect.minY, width: CGFloat(end - start) * cw,
            height: rect.height))
        start = column
        end = column + 1
      }
    }
    result.append(
      CGRect(
        x: originX + CGFloat(start) * cw, y: rect.minY, width: CGFloat(end - start) * cw,
        height: rect.height))
    return result
  }
}

extension FrameProducer {
  /// The logical column of the cell drawn at `visualColumn` on `row`, for
  /// mouse hit-testing: on a BiDi row a click lands on the cell shown there,
  /// not on the cell stored at that column. Other rows return the column
  /// unchanged.
  public static func logicalColumn(
    row: Int, visualColumn: Int, in snapshot: LabanSnapshot,
    bidiDisplay: Bool = BidiDisplaySettings.isEnabled()
  ) -> Int {
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard bidiDisplay, row >= 0, row < rows, visualColumn >= 0, visualColumn < cols,
      let cells = snapshot.cells, let storage = snapshot.utf8_storage
    else { return visualColumn }
    let producer = FrameProducer()
    let rowCells = producer.localBidiCells(
      cells: cells, storage: storage, rowStart: row * cols, cols: cols, hyperlinkURIs: [])
    guard
      let layout = TerminalBidi.layout(
        cells: rowCells.map {
          TerminalBidi.Cell(column: $0.column, width: $0.width, text: $0.text)
        },
        columns: cols)
    else { return visualColumn }
    return layout.logicalColumn[visualColumn]
  }
}
