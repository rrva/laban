import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore

// Converts a LabanSnapshot into a flat FrameCommand list for the terminal viewport.
// Uses standard CoreGraphics coordinates: (0,0) at bottom-left.
// Row 0 (topmost terminal row) maps to y = (rows-1) * cellHeight.
//
// Coalesces adjacent same-style cells into run commands to reduce CoreText calls.
public struct FrameProducer {
  public let cellWidth: Int
  public let cellHeight: Int
  public let originX: CGFloat
  public let originY: CGFloat

  public init(
    cellWidth: Int = 8,
    cellHeight: Int = 16,
    originX: CGFloat = 0,
    originY: CGFloat = 0
  ) {
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.originX = originX
    self.originY = originY
  }

  // Caller owns the snapshot lifetime; FrameProducer does not retain it.
  public func commands(
    from snap: UnsafePointer<LabanSnapshot>,
    selection: TerminalSelection? = nil
  ) -> [FrameCommand] {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    let cw = CGFloat(cellWidth)
    let ch = CGFloat(cellHeight)
    let defaultBg = snapshot.default_background_rgba

    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(rows * 2 + 4)

    // Terminal area background
    cmds.append(
      .rect(
        CGRect(x: originX, y: originY, width: CGFloat(cols) * cw, height: CGFloat(rows) * ch),
        color: defaultBg,
        source: .terminal
      ))

    guard rows > 0, cols > 0, let cells = snapshot.cells else { return cmds }

    // ---- Pass 1: Background rects for all rows ----
    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch
      let rowStart = row * cols

      var bgStart: Int? = nil
      var bgColor: UInt32 = 0

      for col in 0..<cols {
        let cell = cells[rowStart + col]
        let cellBg = cell.background_rgba

        if bgStart == nil {
          if cellBg != defaultBg {
            bgStart = col
            bgColor = cellBg
          }
        } else if cellBg != bgColor || cellBg == defaultBg {
          let runCols = col - bgStart!
          let cellX = originX + CGFloat(bgStart!) * cw
          cmds.append(
            .rect(
              CGRect(x: cellX, y: cellY, width: CGFloat(runCols) * cw, height: ch),
              color: bgColor,
              source: .terminal
            ))
          bgStart = cellBg != defaultBg ? col : nil
          bgColor = cellBg
        }
      }
      if let start = bgStart {
        let runCols = cols - start
        let cellX = originX + CGFloat(start) * cw
        cmds.append(
          .rect(
            CGRect(x: cellX, y: cellY, width: CGFloat(runCols) * cw, height: ch),
            color: bgColor,
            source: .terminal
          ))
      }
    }

    // ---- Pass 2: Selection highlight rects ----
    if let sel = selection {
      for rect in sel.cgRects(
        rows: rows, cols: cols,
        cellWidth: cw, cellHeight: ch,
        originX: originX, originY: originY
      ) {
        cmds.append(.selection(rect, color: Theme.CurrentTheme.selectionBg))
      }
    }

    // ---- Pass 3: Glyph runs and block-element rects for all rows ----
    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch
      let rowStart = row * cols

      var runStart: Int? = nil
      var runFg: UInt32 = 0
      var runBg: UInt32 = 0
      var runText = ""

      for col in 0..<cols {
        let cell = cells[rowStart + col]
        let hasContent = cell.utf8_length > 0 && snapshot.utf8_storage != nil
        let cellFg = cell.foreground_rgba
        let cellBg = cell.background_rgba

        if hasContent, let storage = snapshot.utf8_storage {
          let offset = Int(cell.utf8_offset)
          let length = Int(cell.utf8_length)
          let ptr = UnsafeRawPointer(storage).advanced(by: offset)
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: length
          )
          if let text = String(bytes: buf, encoding: .utf8), !text.isEmpty {
            // Block elements are emitted as procedural .rect commands so they
            // tile gap-free regardless of the font's glyph metrics. Keeps the
            // renderer backend-agnostic — software, Metal, or any future
            // backend just sees colored rects.
            if text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first,
              BoxDrawing.isBlockElement(scalar)
            {
              if let start = runStart, !runText.isEmpty {
                let cellX = originX + CGFloat(start) * cw
                cmds.append(
                  .glyphRun(
                    origin: CGPoint(x: cellX, y: cellY),
                    text: runText,
                    foreground: runFg,
                    background: runBg,
                    source: .terminal
                  ))
              }
              runStart = nil
              runText = ""
              let cellX = originX + CGFloat(col) * cw
              for filled in BoxDrawing.blockElementRects(
                scalar,
                at: CGPoint(x: cellX, y: cellY),
                cellWidth: cw,
                cellHeight: ch,
                foreground: cellFg
              ) {
                cmds.append(.rect(filled.rect, color: filled.color, source: .terminal))
              }
              continue
            }

            if runStart != nil, runFg == cellFg && runBg == cellBg {
              runText += text
            } else {
              if let start = runStart, !runText.isEmpty {
                let cellX = originX + CGFloat(start) * cw
                cmds.append(
                  .glyphRun(
                    origin: CGPoint(x: cellX, y: cellY),
                    text: runText,
                    foreground: runFg,
                    background: runBg,
                    source: .terminal
                  ))
              }
              runStart = col
              runFg = cellFg
              runBg = cellBg
              runText = text
            }
          } else {
            if let start = runStart, !runText.isEmpty {
              let cellX = originX + CGFloat(start) * cw
              cmds.append(
                .glyphRun(
                  origin: CGPoint(x: cellX, y: cellY),
                  text: runText,
                  foreground: runFg,
                  background: runBg,
                  source: .terminal
                ))
            }
            runStart = nil
            runText = ""
          }
        } else {
          if let start = runStart, !runText.isEmpty {
            let cellX = originX + CGFloat(start) * cw
            cmds.append(
              .glyphRun(
                origin: CGPoint(x: cellX, y: cellY),
                text: runText,
                foreground: runFg,
                background: runBg,
                source: .terminal
              ))
          }
          runStart = nil
          runText = ""
        }
      }
      if let start = runStart, !runText.isEmpty {
        let cellX = originX + CGFloat(start) * cw
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: cellX, y: cellY),
            text: runText,
            foreground: runFg,
            background: runBg,
            source: .terminal
          ))
      }
    }

    // Cursor
    if snapshot.cursor_visible != 0,
      Int(snapshot.cursor_row) < rows,
      Int(snapshot.cursor_col) < cols
    {
      let cx = originX + CGFloat(snapshot.cursor_col) * cw
      let cy = originY + CGFloat(rows - 1 - Int(snapshot.cursor_row)) * ch
      cmds.append(
        .cursor(
          CGRect(x: cx, y: cy, width: cw, height: ch),
          color: Theme.CurrentTheme.cursor
        ))
    }

    return cmds
  }
}
