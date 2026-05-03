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
  public func commands(from snap: UnsafePointer<LabanSnapshot>) -> [FrameCommand] {
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

    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch
      let rowStart = row * cols

      // ---- Background runs: merge adjacent cells with same background color ----
      var bgStart: Int? = nil
      var bgColor: UInt32 = 0

      for col in 0..<cols {
        let cell = cells[rowStart + col]
        let cellBg = cell.background_rgba

        if bgStart == nil {
          // Start a new background run (skip default-bg cells)
          if cellBg != defaultBg {
            bgStart = col
            bgColor = cellBg
          }
        } else if cellBg != bgColor || cellBg == defaultBg {
          // Emit the completed background run
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
        // else: same color continues
      }
      // Emit final background run
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

      // ---- Glyph runs: merge adjacent non-empty cells with same FG+BG ----
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
            if let start = runStart, runFg == cellFg && runBg == cellBg {
              // Continue run: same FG+BG
              runText += text
            } else {
              // Emit previous run
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
              // Start new run
              runStart = col
              runFg = cellFg
              runBg = cellBg
              runText = text
            }
          } else {
            // Failed to decode — emit any prior run and skip this cell
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
          // Empty cell — emit any prior run and reset
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
      // Emit final glyph run for this row
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
          color: Theme.SelenizedLight.cursor
        ))
    }

    return cmds
  }
}
