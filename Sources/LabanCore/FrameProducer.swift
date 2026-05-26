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
  /// Sub-cell vertical pixel shift applied to per-row backgrounds, selection
  /// rects, glyph runs, and the cursor. Used by smooth scroll to slide
  /// content between integer cell positions during an animation. Sign:
  /// positive shifts content UP visually (CG y increases), negative shifts
  /// DOWN. The terminal-area background rect is NOT shifted — it acts as
  /// the canvas under the sliding cells.
  public let contentYOffset: CGFloat

  public init(
    cellWidth: Int = 8,
    cellHeight: Int = 16,
    originX: CGFloat = 0,
    originY: CGFloat = 0,
    contentYOffset: CGFloat = 0
  ) {
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.originX = originX
    self.originY = originY
    self.contentYOffset = contentYOffset
  }

  // Caller owns the snapshot lifetime; FrameProducer does not retain it.
  public func commands(
    from snap: UnsafePointer<LabanSnapshot>,
    selection: TerminalSelection? = nil
  ) -> [FrameCommand] {
    commands(from: snap, selection: selection, findState: nil, cursorBlinkVisible: true)
  }

  public func commands(
    from snap: UnsafePointer<LabanSnapshot>,
    cursorBlinkVisible: Bool
  ) -> [FrameCommand] {
    commands(
      from: snap,
      selection: nil,
      findState: nil,
      cursorBlinkVisible: cursorBlinkVisible)
  }

  public func commands(
    from snap: UnsafePointer<LabanSnapshot>,
    selection: TerminalSelection?,
    findState: TerminalFindState? = nil,
    viewportRowOffset: Int = 0,
    cursorBlinkVisible: Bool
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

    func appendExitBanner() {
      guard snapshot.status != 0 else { return }
      let bannerY = originY
      let bannerW = CGFloat(cols) * cw
      let bannerH = ch
      cmds.append(
        .rect(
          CGRect(x: originX, y: bannerY, width: bannerW, height: bannerH),
          color: Theme.current.bg1,
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
          foreground: Theme.current.dim0,
          background: Theme.current.bg1,
          attributes: [],
          source: .terminal
        ))
    }

    guard rows > 0, cols > 0, let cells = snapshot.cells else {
      appendExitBanner()
      return cmds
    }

    // ---- Pass 1: Background rects for all rows ----
    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch + contentYOffset
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
        let shifted = CGRect(
          x: rect.origin.x, y: rect.origin.y + contentYOffset,
          width: rect.width, height: rect.height)
        cmds.append(.selection(shifted, color: Theme.current.selectionBg))
      }
    }

    // ---- Pass 3: Find highlight rects ----
    if let findState, findState.isActive, !findState.matches.isEmpty {
      let selectedMatch = findState.selectedMatch
      for match in findState.matches where match != selectedMatch {
        guard
          let rect = findRect(
            for: match,
            viewportRowOffset: viewportRowOffset,
            rows: rows,
            cols: cols,
            cellWidth: cw,
            cellHeight: ch
          )
        else { continue }
        cmds.append(.findMatch(rect, color: findMatchColor()))
      }
      if let selectedMatch,
        let rect = findRect(
          for: selectedMatch,
          viewportRowOffset: viewportRowOffset,
          rows: rows,
          cols: cols,
          cellWidth: cw,
          cellHeight: ch
        )
      {
        cmds.append(.findSelected(rect, color: findSelectedColor()))
      }
    }

    // ---- Pass 4: Glyph runs and block-element rects for all rows ----
    let hyperlinkURIs = FrameProducer.hyperlinkURIs(from: snapshot)
    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch + contentYOffset
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
            cellUnderlineColor = Theme.current.blue
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
      snapshot.cursor_blinking == 0 || cursorBlinkVisible,
      Int(snapshot.cursor_row) < rows,
      Int(snapshot.cursor_col) < cols
    {
      let cx = originX + CGFloat(snapshot.cursor_col) * cw
      let cy = originY + CGFloat(rows - 1 - Int(snapshot.cursor_row)) * ch + contentYOffset
      let cellRect = CGRect(x: cx, y: cy, width: cw, height: ch)
      for rect in Self.cursorRects(style: Int(snapshot.cursor_style), cellRect: cellRect) {
        cmds.append(.cursor(rect, color: Theme.current.cursor))
      }
    }

    // Exit banner overlays the bottom terminal row after all terminal cells
    // have been emitted so stale bottom-row content cannot cover it.
    appendExitBanner()

    return cmds
  }

  public func commands(
    from snapshot: LabandSnapshotResponse,
    selection: TerminalSelection? = nil,
    cursorBlinkVisible: Bool = true
  ) -> [FrameCommand] {
    let rows = max(snapshot.rows, 0)
    let cols = max(snapshot.cols, 0)
    let cw = CGFloat(cellWidth)
    let ch = CGFloat(cellHeight)
    // Prefer the daemon's libghostty-supplied default. Treat nil and a literal
    // zero as "unknown" and fall back to the theme. Never use
    // `cells.first?.backgroundRGBA` here — it can be 0 (transparent black) on
    // an unstyled first cell and used to leak the underlying view color
    // through as a black border between the sidebar and the terminal area.
    let defaultBg: UInt32 = {
      if let supplied = snapshot.defaultBackgroundRGBA, supplied != 0 { return supplied }
      return Theme.current.bg0
    }()

    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(rows * 2 + 4)
    cmds.append(
      .rect(
        CGRect(x: originX, y: originY, width: CGFloat(cols) * cw, height: CGFloat(rows) * ch),
        color: defaultBg,
        source: .terminal
      ))

    guard rows > 0, cols > 0 else {
      appendRemoteExitBanner(snapshot, cols: cols, cellHeight: ch, commands: &cmds)
      return cmds
    }

    let fullGrid = snapshot.cells.count >= rows * cols
    func cellAt(row: Int, col: Int) -> LabandSnapshotCell? {
      if fullGrid {
        let index = row * cols + col
        guard index < snapshot.cells.count else { return nil }
        let cell = snapshot.cells[index]
        if cell.row == row && cell.col == col { return cell }
      }
      return snapshot.cells.first { $0.row == row && $0.col == col }
    }

    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch + contentYOffset
      var bgStart: Int? = nil
      var bgColor: UInt32 = 0

      for col in 0..<cols {
        let cellBg = cellAt(row: row, col: col)?.backgroundRGBA ?? defaultBg
        if bgStart == nil {
          if cellBg != defaultBg {
            bgStart = col
            bgColor = cellBg
          }
        } else if cellBg != bgColor || cellBg == defaultBg {
          let runCols = col - bgStart!
          cmds.append(
            .rect(
              CGRect(
                x: originX + CGFloat(bgStart!) * cw,
                y: cellY,
                width: CGFloat(runCols) * cw,
                height: ch),
              color: bgColor,
              source: .terminal
            ))
          bgStart = cellBg != defaultBg ? col : nil
          bgColor = cellBg
        }
      }
      if let start = bgStart {
        cmds.append(
          .rect(
            CGRect(
              x: originX + CGFloat(start) * cw,
              y: cellY,
              width: CGFloat(cols - start) * cw,
              height: ch),
            color: bgColor,
            source: .terminal
          ))
      }
    }

    if let sel = selection {
      for rect in sel.cgRects(
        rows: rows,
        cols: cols,
        cellWidth: cw,
        cellHeight: ch,
        originX: originX,
        originY: originY
      ) {
        cmds.append(
          .selection(
            CGRect(
              x: rect.origin.x,
              y: rect.origin.y + contentYOffset,
              width: rect.width,
              height: rect.height),
            color: Theme.current.selectionBg))
      }
    }

    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch + contentYOffset
      var runStart: Int? = nil
      var runFg: UInt32 = 0
      var runBg: UInt32 = 0
      var runAttrs: TextAttributes = []
      var runText = ""

      func flushRun() {
        guard let start = runStart, !runText.isEmpty else {
          runStart = nil
          runText = ""
          return
        }
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: originX + CGFloat(start) * cw, y: cellY),
            text: runText,
            foreground: runFg,
            background: runBg,
            attributes: runAttrs,
            source: .terminal
          ))
        runStart = nil
        runText = ""
      }

      for col in 0..<cols {
        guard let cell = cellAt(row: row, col: col), !cell.text.isEmpty else {
          flushRun()
          continue
        }
        // Block elements (U+2580..U+259F) and fixed-format geometric triangles
        // (U+25E2..U+25E5) leave hairline gaps when rendered through the
        // font, because the loaded glyph's metrics don't exactly fill the
        // terminal cell. The local FrameProducer overload bypasses the font
        // for those scalars and emits procedural integer-aligned `.rect`
        // commands; the remote overload must do the same so the Claude
        // crab mascot and other block-art tiles render seam-free in
        // background-session mode.
        if cell.text.unicodeScalars.count == 1,
          let scalar = cell.text.unicodeScalars.first,
          BoxDrawing.isProceduralCellElement(scalar)
        {
          flushRun()
          let cellX = originX + CGFloat(col) * cw
          for filled in BoxDrawing.proceduralCellElementRects(
            scalar,
            at: CGPoint(x: cellX, y: cellY),
            cellWidth: cw,
            cellHeight: ch,
            foreground: cell.foregroundRGBA
          ) {
            cmds.append(.rect(filled.rect, color: filled.color, source: .terminal))
          }
          continue
        }
        let attrs = TextAttributes(rawValue: cell.flags).intersection(.renderableMask)
        if runStart == nil {
          runStart = col
          runFg = cell.foregroundRGBA
          runBg = cell.backgroundRGBA
          runAttrs = attrs
          runText = cell.text
        } else if cell.foregroundRGBA == runFg && cell.backgroundRGBA == runBg && attrs == runAttrs
        {
          runText += cell.text
        } else {
          flushRun()
          runStart = col
          runFg = cell.foregroundRGBA
          runBg = cell.backgroundRGBA
          runAttrs = attrs
          runText = cell.text
        }
      }
      flushRun()
    }

    if snapshot.cursorVisible,
      cursorBlinkVisible,
      snapshot.cursorRow >= 0,
      snapshot.cursorCol >= 0,
      snapshot.cursorRow < rows,
      snapshot.cursorCol < cols
    {
      let rect = CGRect(
        x: originX + CGFloat(snapshot.cursorCol) * cw,
        y: originY + CGFloat(rows - 1 - snapshot.cursorRow) * ch + contentYOffset,
        width: cw,
        height: ch
      )
      cmds.append(.cursor(rect, color: Theme.current.cursor))
    }

    appendRemoteExitBanner(snapshot, cols: cols, cellHeight: ch, commands: &cmds)
    return cmds
  }

  private func appendRemoteExitBanner(
    _ snapshot: LabandSnapshotResponse,
    cols: Int,
    cellHeight: CGFloat,
    commands: inout [FrameCommand]
  ) {
    guard snapshot.lifecycleState != .running else { return }
    let width = CGFloat(max(cols, 1)) * CGFloat(cellWidth)
    commands.append(
      .rect(
        CGRect(x: originX, y: originY, width: width, height: cellHeight),
        color: Theme.current.bg1,
        source: .terminal
      ))
    let text: String
    if let exitStatus = snapshot.exitStatus {
      text = "Process exited \(exitStatus)"
    } else {
      text = "Process \(snapshot.lifecycleState.rawValue)"
    }
    commands.append(
      .glyphRun(
        origin: CGPoint(x: originX + 4, y: originY + 2),
        text: text,
        foreground: Theme.current.dim0,
        background: Theme.current.bg1,
        attributes: [],
        source: .terminal
      ))
  }

  public static func cursorRects(style: Int, cellRect: CGRect) -> [CGRect] {
    let thickness = max(CGFloat(1), ceil(min(cellRect.width, cellRect.height) * 0.16))
    switch style {
    case Int(LABAN_CURSOR_STYLE_BAR):
      return [
        CGRect(
          x: cellRect.minX,
          y: cellRect.minY,
          width: min(thickness, cellRect.width),
          height: cellRect.height)
      ]
    case Int(LABAN_CURSOR_STYLE_UNDERLINE):
      return [
        CGRect(
          x: cellRect.minX,
          y: cellRect.minY,
          width: cellRect.width,
          height: min(thickness, cellRect.height))
      ]
    case Int(LABAN_CURSOR_STYLE_BLOCK_HOLLOW):
      let t = min(thickness, min(cellRect.width, cellRect.height))
      return [
        CGRect(x: cellRect.minX, y: cellRect.minY, width: cellRect.width, height: t),
        CGRect(x: cellRect.minX, y: cellRect.maxY - t, width: cellRect.width, height: t),
        CGRect(x: cellRect.minX, y: cellRect.minY, width: t, height: cellRect.height),
        CGRect(x: cellRect.maxX - t, y: cellRect.minY, width: t, height: cellRect.height),
      ]
    default:
      return [cellRect]
    }
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

  private func findRect(
    for match: TerminalFindMatch,
    viewportRowOffset: Int,
    rows: Int,
    cols: Int,
    cellWidth: CGFloat,
    cellHeight: CGFloat
  ) -> CGRect? {
    let localRow = match.row - viewportRowOffset
    guard localRow >= 0, localRow < rows else { return nil }
    let start = min(max(match.startColumn, 0), cols)
    let end = min(max(match.endColumn, 0), cols)
    guard end > start else { return nil }
    return CGRect(
      x: originX + CGFloat(start) * cellWidth,
      y: originY + CGFloat(rows - 1 - localRow) * cellHeight + contentYOffset,
      width: CGFloat(end - start) * cellWidth,
      height: cellHeight
    )
  }

  private static func alphaColor(_ rgba: UInt32, alpha: UInt32) -> UInt32 {
    (rgba & 0xFFFF_FF00) | min(alpha, 0xFF)
  }

  private func findMatchColor() -> UInt32 {
    Self.alphaColor(
      Theme.current.ansi16.indices.contains(3) ? Theme.current.ansi16[3] : 0xDBB3_2DFF, alpha: 0x4D)
  }

  private func findSelectedColor() -> UInt32 {
    Self.alphaColor(
      Theme.current.ansi16.indices.contains(11) ? Theme.current.ansi16[11] : 0xEBC1_3DFF,
      alpha: 0xB3)
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
