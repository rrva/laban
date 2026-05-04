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

    // Exit banner — overlays the bottom terminal row when the process has exited.
    // Placed before the cells guard so it renders even when cells is nil.
    if snapshot.status != 0 {
      let bannerY = originY
      let bannerW = CGFloat(cols) * cw
      let bannerH = ch
      cmds.append(
        .rect(
          CGRect(x: originX, y: bannerY, width: bannerW, height: bannerH),
          color: Theme.CurrentTheme.bg1,
          source: .terminal
        ))
      let exitText: String
      switch snapshot.status {
      case 1: exitText = "Process exited \(snapshot.exit_status)"
      case 2: exitText = "Process signaled \(snapshot.exit_status)"
      default: exitText = "Process exited"
      }
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: originX + 4, y: bannerY + 2),
          text: exitText,
          foreground: Theme.CurrentTheme.dim0,
          background: Theme.CurrentTheme.bg1,
          attributes: [],
          source: .terminal
        ))
    }

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
    let hyperlinkURIs = FrameProducer.hyperlinkURIs(from: snapshot)
    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch
      let rowStart = row * cols

      var runStart: Int? = nil
      var runFg: UInt32 = 0
      var runBg: UInt32 = 0
      var runAttrs: TextAttributes = []
      var runText = ""
      var runUnderlineStyle: UnderlineStyle = .none
      var runUnderlineColor: UInt32? = nil
      var runHyperlink: String? = nil
      // Set when we encounter a SPACER_TAIL while a run is open. The spacer
      // is provisionally swallowed; we only flush it if the next visible
      // cell does not extend the cluster.
      var pendingSpacer = false

      func flushRun() {
        guard let start = runStart, !runText.isEmpty else {
          runStart = nil
          runText = ""
          return
        }
        let cellX = originX + CGFloat(start) * cw
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: cellX, y: cellY),
            text: runText,
            foreground: runFg,
            background: runBg,
            attributes: runAttrs,
            source: .terminal,
            underlineStyle: runUnderlineStyle,
            underlineColor: runUnderlineColor,
            hyperlink: runHyperlink
          ))
        runStart = nil
        runText = ""
        runUnderlineStyle = .none
        runUnderlineColor = nil
        runHyperlink = nil
      }

      for col in 0..<cols {
        let cell = cells[rowStart + col]
        let isSpacerTail = (cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL))
        let hasContent = cell.utf8_length > 0 && snapshot.utf8_storage != nil

        // SPACER_TAIL belongs to the wide cell that precedes it. Hold off on
        // flushing the run; if the next visible cell extends the current
        // grapheme cluster (ZWJ chain, RI pair, skin-tone modifier), we'll
        // append into the same run — otherwise we'll flush below.
        if isSpacerTail {
          if runStart != nil { pendingSpacer = true }
          continue
        }

        // The C bridge already swaps fg/bg for inverse video, so .inverse is
        // dropped here to keep downstream consumers from double-inverting.
        let attrs = TextAttributes(rawValue: cell.flags)
          .intersection(.renderableMask)
          .subtracting(.inverse)
        let cellBg = cell.background_rgba
        let cellFg =
          attrs.contains(.faint)
          ? FrameProducer.blend(cell.foreground_rgba, toward: cellBg, foregroundWeight: 0.50)
          : cell.foreground_rgba
        var cellUnderlineStyle = UnderlineStyle(rawValue: cell.underline_style) ?? .none
        var cellUnderlineColor = cell.underline_color_rgba == 0 ? nil : cell.underline_color_rgba
        let cellHyperlink: String? = {
          let id = Int(cell.hyperlink_id)
          guard id > 0, id <= hyperlinkURIs.count else { return nil }
          return hyperlinkURIs[id - 1]
        }()
        // Default link styling: a single underline in the accent color when
        // the cell carries a hyperlink and the SGR didn't already set one.
        // Lets users see and click on links without making the renderer
        // theme-aware everywhere.
        var cellAttrs = attrs
        if cellHyperlink != nil {
          if cellUnderlineStyle == .none && !cellAttrs.contains(.underline) {
            cellUnderlineStyle = .single
          }
          if cellUnderlineColor == nil {
            cellUnderlineColor = Theme.CurrentTheme.blue
          }
          cellAttrs.insert(.underline)
        }

        if hasContent, !attrs.contains(.invisible), let storage = snapshot.utf8_storage {
          let offset = Int(cell.utf8_offset)
          let length = Int(cell.utf8_length)
          let ptr = UnsafeRawPointer(storage).advanced(by: offset)
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: length
          )
          if let text = String(bytes: buf, encoding: .utf8), !text.isEmpty {
            // Block and fixed-format geometric elements are emitted as
            // procedural .rect commands so they tile gap-free and stay inside
            // terminal cell bounds regardless of fallback font metrics.
            if text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first,
              BoxDrawing.isProceduralCellElement(scalar)
            {
              flushRun()
              pendingSpacer = false
              let cellX = originX + CGFloat(col) * cw
              for filled in BoxDrawing.proceduralCellElementRects(
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

            let sameStyle =
              runFg == cellFg && runBg == cellBg && runAttrs == cellAttrs
              && runUnderlineStyle == cellUnderlineStyle
              && runUnderlineColor == cellUnderlineColor
              && runHyperlink == cellHyperlink

            if runStart != nil, sameStyle {
              if pendingSpacer {
                // Resolve the held SPACER_TAIL: if appending shrinks the
                // grapheme-cluster count (Swift Character collapses), the
                // wide cell and this one belong to the same cluster — keep
                // them in the same run. Otherwise flush before the new cell.
                let mergedCount = (runText + text).count
                if mergedCount < runText.count + text.count {
                  runText += text
                  pendingSpacer = false
                } else {
                  flushRun()
                  pendingSpacer = false
                  runStart = col
                  runFg = cellFg
                  runBg = cellBg
                  runAttrs = cellAttrs
                  runUnderlineStyle = cellUnderlineStyle
                  runUnderlineColor = cellUnderlineColor
                  runHyperlink = cellHyperlink
                  runText = text
                }
              } else {
                runText += text
              }
            } else {
              flushRun()
              pendingSpacer = false
              runStart = col
              runFg = cellFg
              runBg = cellBg
              runAttrs = cellAttrs
              runUnderlineStyle = cellUnderlineStyle
              runUnderlineColor = cellUnderlineColor
              runHyperlink = cellHyperlink
              runText = text
            }
          } else {
            flushRun()
            pendingSpacer = false
          }
        } else {
          flushRun()
          pendingSpacer = false
        }
      }
      flushRun()
      pendingSpacer = false
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

  private static func hyperlinkURIs(from snapshot: LabanSnapshot) -> [String] {
    let count = Int(snapshot.hyperlink_count)
    guard count > 0, let table = snapshot.hyperlink_uris else { return [] }
    var result: [String] = []
    result.reserveCapacity(count)
    for i in 0..<count {
      if let cstr = table[i] {
        result.append(String(cString: cstr))
      } else {
        result.append("")
      }
    }
    return result
  }

  private static func blend(
    _ foreground: UInt32, toward background: UInt32, foregroundWeight: Double
  ) -> UInt32 {
    let fgWeight = min(max(foregroundWeight, 0), 1)
    let bgWeight = 1 - fgWeight

    func channel(_ shift: UInt32) -> UInt32 {
      let fg = Double((foreground >> shift) & 0xFF)
      let bg = Double((background >> shift) & 0xFF)
      return UInt32((fg * fgWeight + bg * bgWeight).rounded())
    }

    let r = channel(24)
    let g = channel(16)
    let b = channel(8)
    let a = (foreground & 0xFF)
    return (r << 24) | (g << 16) | (b << 8) | a
  }
}
