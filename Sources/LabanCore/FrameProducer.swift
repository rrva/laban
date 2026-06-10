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

  // A/B toggle: force the legacy glyph pass even on macOS 26. Production never
  // sets this; the parity test flips it to prove the Span/UTF8Span fast path
  // emits byte-identical FrameCommands, and the bench measures both in one run.
  nonisolated(unsafe) static var _forceLegacyGlyphRuns = false

  // Raw bitmasks so the hot loop avoids cross-module OptionSet method calls.
  // TextAttributes lives in LabanRenderer; `.intersection`/`.subtracting` do
  // not inline across the module boundary, so they showed up as real cost in
  // the profile. Bitwise ops on the raw UInt16 are free.
  private static let renderableMaskRaw: UInt16 = TextAttributes.renderableMask.rawValue
  private static let inverseRaw: UInt16 = TextAttributes.inverse.rawValue
  private static let faintRaw: UInt16 = TextAttributes.faint.rawValue
  private static let invisibleRaw: UInt16 = TextAttributes.invisible.rawValue
  private static let underlineRaw: UInt16 = TextAttributes.underline.rawValue

  private struct ResolvedCellVisuals {
    var foreground: UInt32
    var background: UInt32
    var attrsRaw: UInt16
    var underlineStyle: UnderlineStyle
    var underlineColor: UInt32?
    var hyperlink: String?

    var attributes: TextAttributes { TextAttributes(rawValue: attrsRaw) }
    var hasHyperlink: Bool { hyperlink != nil }
    var isInvisible: Bool { (attrsRaw & FrameProducer.invisibleRaw) != 0 }
  }

  private static func resolvedVisuals(
    for cell: LabanCell,
    hyperlinkURIs: [String]
  ) -> ResolvedCellVisuals {
    var attrsRaw = (cell.flags & renderableMaskRaw) & ~inverseRaw
    let background = cell.background_rgba
    let foreground =
      (attrsRaw & faintRaw) != 0
      ? blend(cell.foreground_rgba, toward: background, foregroundWeight: 0.50)
      : cell.foreground_rgba
    var underlineStyle = UnderlineStyle(rawValue: cell.underline_style) ?? .none
    var underlineColor = cell.underline_color_rgba == 0 ? nil : cell.underline_color_rgba
    let hyperlink: String? = {
      let id = Int(cell.hyperlink_id)
      guard id > 0, id <= hyperlinkURIs.count else { return nil }
      return hyperlinkURIs[id - 1]
    }()
    if hyperlink != nil {
      if underlineStyle == .none && (attrsRaw & underlineRaw) == 0 {
        underlineStyle = .single
      }
      if underlineColor == nil {
        underlineColor = Theme.current.blue
      }
      attrsRaw |= underlineRaw
    }
    return ResolvedCellVisuals(
      foreground: foreground,
      background: background,
      attrsRaw: attrsRaw,
      underlineStyle: underlineStyle,
      underlineColor: underlineColor,
      hyperlink: hyperlink)
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
    cursorBlinkVisible: Bool,
    preedit: String? = nil,
    preeditCaretCells: Int = 0,
    resolvedCursor: (style: Int32, blinking: Bool)? = nil
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
    // macOS 26 takes a Span/UTF8Span fast path that builds each coalesced run
    // from raw UTF-8 bytes (one String per run, not per cell) and merges
    // grapheme clusters without allocating; older systems — and the A/B test
    // toggle — take the legacy loop. Both MUST emit byte-identical
    // FrameCommands; FrameProducerSpanParityTests pins that.
    let hyperlinkURIs = FrameProducer.hyperlinkURIs(from: snapshot)
    if #available(macOS 26, *), !FrameProducer._forceLegacyGlyphRuns {
      appendFastTerminalGlyphRuns(
        into: &cmds, snapshot: snapshot, rows: rows, cols: cols, cw: cw, ch: ch,
        hyperlinkURIs: hyperlinkURIs)
    } else {
      appendLegacyTerminalGlyphRuns(
        into: &cmds, snapshot: snapshot, rows: rows, cols: cols, cw: cw, ch: ch,
        hyperlinkURIs: hyperlinkURIs)
    }

    // Cursor
    let effectiveCursorBlinking =
      resolvedCursor?.blinking ?? (snapshot.cursor_blinking != 0)
    let effectiveCursorStyle =
      resolvedCursor?.style ?? snapshot.cursor_style
    if snapshot.cursor_visible != 0,
      !effectiveCursorBlinking || cursorBlinkVisible,
      Int(snapshot.cursor_row) < rows,
      Int(snapshot.cursor_col) < cols
    {
      // Advance the caret past any in-flight composition so it tracks the end
      // of the preedit as the user dictates/composes, matching native text
      // fields; with no marked text the offset is 0 and the caret is unmoved.
      let caretCol = min(Int(snapshot.cursor_col) + preeditCaretCells, cols - 1)
      let cx = originX + CGFloat(caretCol) * cw
      let cy = originY + CGFloat(rows - 1 - Int(snapshot.cursor_row)) * ch + contentYOffset
      let cellRect = CGRect(x: cx, y: cy, width: cw, height: ch)
      for rect in Self.cursorRects(style: Int(effectiveCursorStyle), cellRect: cellRect) {
        cmds.append(.cursor(rect, color: Theme.current.cursor))
      }
    }

    if let preedit {
      appendPreedit(
        into: &cmds,
        text: preedit,
        cursorRow: Int(snapshot.cursor_row),
        cursorCol: Int(snapshot.cursor_col),
        rows: rows,
        cols: cols,
        foreground: snapshot.default_foreground_rgba,
        background: defaultBg)
    }

    // Exit banner overlays the bottom terminal row after all terminal cells
    // have been emitted so stale bottom-row content cannot cover it.
    appendExitBanner()

    return cmds
  }

  public func overlayCommands(
    from snap: UnsafePointer<LabanSnapshot>,
    selection: TerminalSelection?,
    findState: TerminalFindState? = nil,
    viewportRowOffset: Int = 0,
    cursorBlinkVisible: Bool,
    preedit: String? = nil,
    preeditCaretCells: Int = 0,
    resolvedCursor: (style: Int32, blinking: Bool)? = nil
  ) -> [FrameCommand] {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    let cw = CGFloat(cellWidth)
    let ch = CGFloat(cellHeight)

    guard rows > 0, cols > 0 else { return [] }

    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(4)

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

    let overlayEffectiveBlinking =
      resolvedCursor?.blinking ?? (snapshot.cursor_blinking != 0)
    let overlayEffectiveStyle =
      resolvedCursor?.style ?? snapshot.cursor_style
    if snapshot.cursor_visible != 0,
      !overlayEffectiveBlinking || cursorBlinkVisible,
      Int(snapshot.cursor_row) < rows,
      Int(snapshot.cursor_col) < cols
    {
      // Advance the caret past any in-flight composition so it tracks the end
      // of the preedit as the user dictates/composes, matching native text
      // fields; with no marked text the offset is 0 and the caret is unmoved.
      let caretCol = min(Int(snapshot.cursor_col) + preeditCaretCells, cols - 1)
      let cx = originX + CGFloat(caretCol) * cw
      let cy = originY + CGFloat(rows - 1 - Int(snapshot.cursor_row)) * ch + contentYOffset
      let cellRect = CGRect(x: cx, y: cy, width: cw, height: ch)
      for rect in Self.cursorRects(style: Int(overlayEffectiveStyle), cellRect: cellRect) {
        cmds.append(.cursor(rect, color: Theme.current.cursor))
      }
    }

    if let preedit {
      appendPreedit(
        into: &cmds,
        text: preedit,
        cursorRow: Int(snapshot.cursor_row),
        cursorCol: Int(snapshot.cursor_col),
        rows: rows,
        cols: cols,
        foreground: snapshot.default_foreground_rgba,
        background: snapshot.default_background_rgba)
    }

    return cmds
  }

  /// Emit IME/dictation composition (preedit) text at the cursor cell. macOS
  /// delivers the live transcript through `setMarkedText` as the user speaks or
  /// composes; this draws it inline — a background mask + an underlined glyph
  /// run in the terminal font — using the exact cursor origin (including
  /// `contentYOffset`) so it tracks the caret and scrolls with the grid, like
  /// Ghostty/WezTerm "builtin" preedit. The `.preedit` source lets every
  /// renderer (incl. the GPU-cell path) route it through the terminal atlas.
  private func appendPreedit(
    into cmds: inout [FrameCommand],
    text: String,
    cursorRow: Int,
    cursorCol: Int,
    rows: Int,
    cols: Int,
    foreground: UInt32,
    background: UInt32
  ) {
    guard !text.isEmpty, rows > 0, cols > 0 else { return }
    let row = min(max(cursorRow, 0), rows - 1)
    let col = min(max(cursorCol, 0), cols - 1)
    let cw = CGFloat(cellWidth)
    let ch = CGFloat(cellHeight)
    let cx = originX + CGFloat(col) * cw
    let cy = originY + CGFloat(rows - 1 - row) * ch + contentYOffset
    // One cell advance per grapheme cluster, matching how the renderers lay out
    // a glyph run; the mask covers that span so underlying cells don't bleed
    // through the composition.
    let runWidth = CGFloat(text.count) * cw
    cmds.append(
      .rect(
        CGRect(x: cx, y: cy, width: runWidth, height: ch),
        color: background,
        source: .preedit
      ))
    cmds.append(
      .glyphRun(
        origin: CGPoint(x: cx, y: cy),
        text: text,
        foreground: foreground,
        background: background,
        attributes: [.underline],
        source: .preedit,
        underlineStyle: .single,
        underlineColor: nil,
        hyperlink: nil
      ))
  }

  public func terminalCellPayload(
    from snap: UnsafePointer<LabanSnapshot>,
    includedRows requestedRows: [Int],
    selection: TerminalSelection? = nil,
    findState: TerminalFindState? = nil,
    viewportRowOffset: Int = 0,
    cursorBlinkVisible: Bool = true
  ) -> TerminalCellPayload? {
    var payload = TerminalCellPayload(
      rows: 0,
      cols: 0,
      origin: CGPoint(x: originX, y: originY),
      cellSize: CGSize(width: CGFloat(cellWidth), height: CGFloat(cellHeight)),
      contentYOffset: contentYOffset,
      defaultBackground: 0)
    fillTerminalCellPayload(
      into: &payload,
      from: snap,
      includedRows: requestedRows,
      selection: selection,
      findState: findState,
      viewportRowOffset: viewportRowOffset,
      cursorBlinkVisible: cursorBlinkVisible)
    return payload
  }

  private enum SingleUTF8ScalarResult {
    case scalar(UInt32)
    case multiScalar
    case invalid
  }

  private static func singleUTF8ScalarValue(
    _ bytes: UnsafePointer<UInt8>,
    length: Int
  ) -> SingleUTF8ScalarResult {
    @inline(__always)
    func continuation(_ byte: UInt8) -> Bool {
      (byte & 0xC0) == 0x80
    }

    // A cell whose UTF-8 spans 2...4 bytes may decode to a single scalar
    // (e.g. precomposed "é") OR to a multi-scalar grapheme cluster whose
    // encoding happens to fit in <= 4 bytes (e.g. NFD "e" + combining acute =
    // 3 bytes / 2 scalars). The single-scalar fast path below recognises only
    // the former. When it does not match, the span is not necessarily invalid:
    // validate the whole span and classify a valid multi-scalar cluster as
    // .multiScalar so the payload keeps it in the UTF-8 slab instead of failing
    // closed with .invalidUTF8. Genuinely malformed bytes still return .invalid.
    @inline(__always)
    func multiScalarOrInvalid() -> SingleUTF8ScalarResult {
      isValidUTF8(bytes, length) ? .multiScalar : .invalid
    }

    switch length {
    case 1:
      let b0 = bytes[0]
      return b0 < 0x80 ? .scalar(UInt32(b0)) : .invalid
    case 2:
      let b0 = bytes[0]
      let b1 = bytes[1]
      guard (0xC2...0xDF).contains(b0), continuation(b1) else { return multiScalarOrInvalid() }
      return .scalar(UInt32(b0 & 0x1F) << 6 | UInt32(b1 & 0x3F))
    case 3:
      let b0 = bytes[0]
      let b1 = bytes[1]
      let b2 = bytes[2]
      guard continuation(b2) else { return multiScalarOrInvalid() }
      switch b0 {
      case 0xE0:
        guard (0xA0...0xBF).contains(b1) else { return multiScalarOrInvalid() }
      case 0xE1...0xEC, 0xEE...0xEF:
        guard continuation(b1) else { return multiScalarOrInvalid() }
      case 0xED:
        guard (0x80...0x9F).contains(b1) else { return multiScalarOrInvalid() }
      default:
        return multiScalarOrInvalid()
      }
      return .scalar(
        UInt32(b0 & 0x0F) << 12
          | UInt32(b1 & 0x3F) << 6
          | UInt32(b2 & 0x3F))
    case 4:
      let b0 = bytes[0]
      let b1 = bytes[1]
      let b2 = bytes[2]
      let b3 = bytes[3]
      guard continuation(b2), continuation(b3) else { return multiScalarOrInvalid() }
      switch b0 {
      case 0xF0:
        guard (0x90...0xBF).contains(b1) else { return multiScalarOrInvalid() }
      case 0xF1...0xF3:
        guard continuation(b1) else { return multiScalarOrInvalid() }
      case 0xF4:
        guard (0x80...0x8F).contains(b1) else { return multiScalarOrInvalid() }
      default:
        return multiScalarOrInvalid()
      }
      return .scalar(
        UInt32(b0 & 0x07) << 18
          | UInt32(b1 & 0x3F) << 12
          | UInt32(b2 & 0x3F) << 6
          | UInt32(b3 & 0x3F))
    default:
      return .multiScalar
    }
  }

  @inline(__always)
  private static func isValidUTF8(_ bytes: UnsafePointer<UInt8>, _ length: Int) -> Bool {
    var decoder = Unicode.UTF8()
    var iterator = UnsafeBufferPointer(start: bytes, count: length).makeIterator()
    while true {
      switch decoder.decode(&iterator) {
      case .scalarValue:
        continue
      case .emptyInput:
        return true
      case .error:
        return false
      }
    }
  }

  public func fillTerminalCellPayload(
    into payload: inout TerminalCellPayload,
    from snap: UnsafePointer<LabanSnapshot>,
    includedRows requestedRows: [Int],
    selection: TerminalSelection? = nil,
    findState: TerminalFindState? = nil,
    viewportRowOffset: Int = 0,
    cursorBlinkVisible: Bool = true,
    includeCursor: Bool = true,
    resolvedCursor: (style: Int32, blinking: Bool)? = nil
  ) {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    let cw = CGFloat(cellWidth)
    let ch = CGFloat(cellHeight)
    let defaultBg = snapshot.default_background_rgba
    payload.reset(
      rows: rows,
      cols: cols,
      origin: CGPoint(x: originX, y: originY),
      cellSize: CGSize(width: cw, height: ch),
      contentYOffset: contentYOffset,
      defaultBackground: defaultBg,
      fallbackReason: snapshot.status == 0 ? nil : .exitBanner)
    guard rows > 0, cols > 0 else {
      return
    }
    guard let cells = snapshot.cells else {
      payload.fallbackReason = .missingCellStorage
      return
    }

    payload.dirtyRows.reserveCapacity(requestedRows.count)
    for row in requestedRows where row >= 0 && row < rows {
      payload.dirtyRows.append(row)
    }

    func markFallback(_ reason: TerminalCellPayload.FallbackReason) {
      if payload.fallbackReason == nil {
        payload.fallbackReason = reason
      }
    }

    if snapshot.status != 0 {
      markFallback(.exitBanner)
    }

    payload.backgroundRuns.reserveCapacity(payload.dirtyRows.count * 2)
    for row in payload.dirtyRows {
      let rowStart = row * cols
      var bgStart: Int?
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
          payload.backgroundRuns.append(
            TerminalCellPayload.BackgroundRun(
              row: row,
              startCol: bgStart!,
              colCount: col - bgStart!,
              color: bgColor))
          bgStart = cellBg != defaultBg ? col : nil
          bgColor = cellBg
        }
      }
      if let start = bgStart {
        payload.backgroundRuns.append(
          TerminalCellPayload.BackgroundRun(
            row: row,
            startCol: start,
            colCount: cols - start,
            color: bgColor))
      }
    }

    let hyperlinkURIs = FrameProducer.hyperlinkURIs(from: snapshot)
    payload.glyphs.reserveCapacity(payload.dirtyRows.count * cols)
    payload.proceduralCells.reserveCapacity(payload.dirtyRows.count)
    for row in payload.dirtyRows {
      let rowStart = row * cols
      var pendingSpacerAfterLastGlyph = false

      func glyphBytes(_ glyph: TerminalCellPayload.Glyph) -> [UInt8]? {
        if let range = glyph.utf8Range {
          guard range.lowerBound >= 0, range.upperBound <= payload.utf8Bytes.count else {
            return nil
          }
          return Array(payload.utf8Bytes[range])
        }
        if let scalarValue = glyph.scalarValue,
          let scalar = Unicode.Scalar(scalarValue)
        {
          return Array(String(scalar).utf8)
        }
        if !glyph.text.isEmpty {
          return Array(glyph.text.utf8)
        }
        return nil
      }

      func samePayloadGlyphStyle(_ lhs: TerminalCellPayload.Glyph, _ rhs: TerminalCellPayload.Glyph)
        -> Bool
      {
        lhs.row == rhs.row
          && lhs.foreground == rhs.foreground
          && lhs.background == rhs.background
          && lhs.attributes == rhs.attributes
          && lhs.underlineStyle == rhs.underlineStyle
          && lhs.underlineColor == rhs.underlineColor
          && lhs.hasHyperlink == rhs.hasHyperlink
      }

      func appendGlyphOrMergeAfterSpacer(
        _ glyph: TerminalCellPayload.Glyph,
        bytes: [UInt8],
        forceUTF8Storage: Bool
      ) {
        if pendingSpacerAfterLastGlyph,
          let previousIndex = payload.glyphs.indices.last,
          samePayloadGlyphStyle(payload.glyphs[previousIndex], glyph),
          let previousBytes = glyphBytes(payload.glyphs[previousIndex])
        {
          let previousText = String(decoding: previousBytes, as: UTF8.self)
          let currentText = String(decoding: bytes, as: UTF8.self)
          let mergedBytes = previousBytes + bytes
          let mergedText = String(decoding: mergedBytes, as: UTF8.self)
          if mergedText.count < previousText.count + currentText.count {
            let start = payload.utf8Bytes.count
            payload.utf8Bytes.append(contentsOf: mergedBytes)
            payload.glyphs[previousIndex].text = ""
            payload.glyphs[previousIndex].scalarValue = nil
            payload.glyphs[previousIndex].utf8Range = start..<payload.utf8Bytes.count
            pendingSpacerAfterLastGlyph = false
            return
          }
        }

        var storedGlyph = glyph
        if forceUTF8Storage {
          let start = payload.utf8Bytes.count
          payload.utf8Bytes.append(contentsOf: bytes)
          storedGlyph.utf8Range = start..<payload.utf8Bytes.count
        }
        payload.glyphs.append(storedGlyph)
        pendingSpacerAfterLastGlyph = false
      }

      for col in 0..<cols {
        let cell = cells[rowStart + col]
        let isSpacerTail = cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL)
        if isSpacerTail {
          if payload.glyphs.last?.row == row {
            pendingSpacerAfterLastGlyph = true
          }
          continue
        }

        let visuals = FrameProducer.resolvedVisuals(for: cell, hyperlinkURIs: hyperlinkURIs)
        let cellAttrs = visuals.attributes

        if !cellAttrs.subtracting(.gpuCellRenderableMask).isEmpty {
          markFallback(.unsupportedAttributes)
        }
        if visuals.isInvisible {
          pendingSpacerAfterLastGlyph = false
          continue
        }
        let scalarResult: SingleUTF8ScalarResult
        let utf8Bytes: UnsafeBufferPointer<UInt8>?
        if cell.codepoint != 0 {
          scalarResult = .scalar(cell.codepoint)
          utf8Bytes = nil
        } else {
          guard cell.utf8_length > 0, let storage = snapshot.utf8_storage else { continue }
          let offset = Int(cell.utf8_offset)
          let length = Int(cell.utf8_length)
          let ptr = UnsafeRawPointer(storage).advanced(by: offset)
          scalarResult = Self.singleUTF8ScalarValue(
            ptr.assumingMemoryBound(to: UInt8.self),
            length: length)
          utf8Bytes = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: length)
        }
        switch scalarResult {
        case .scalar(let scalarValue):
          guard let scalar = Unicode.Scalar(scalarValue) else {
            pendingSpacerAfterLastGlyph = false
            markFallback(.invalidUTF8)
            continue
          }
          if BoxDrawing.isProceduralCellElement(scalar) {
            pendingSpacerAfterLastGlyph = false
            payload.proceduralCells.append(
              TerminalCellPayload.ProceduralCell(
                row: row,
                col: col,
                scalarValue: scalarValue,
                foreground: visuals.foreground))
            continue
          }
          let glyph = TerminalCellPayload.Glyph(
            row: row,
            col: col,
            text: "",
            scalarValue: scalarValue,
            foreground: visuals.foreground,
            background: visuals.background,
            attributes: cellAttrs,
            underlineStyle: visuals.underlineStyle,
            underlineColor: visuals.underlineColor,
            hasHyperlink: visuals.hasHyperlink,
            wide: cell.wide)
          if pendingSpacerAfterLastGlyph {
            appendGlyphOrMergeAfterSpacer(
              glyph,
              bytes: Array(String(scalar).utf8),
              forceUTF8Storage: false)
          } else {
            payload.glyphs.append(glyph)
          }
        case .multiScalar:
          guard let utf8Bytes else {
            pendingSpacerAfterLastGlyph = false
            markFallback(.invalidUTF8)
            continue
          }
          let glyph = TerminalCellPayload.Glyph(
            row: row,
            col: col,
            text: "",
            scalarValue: nil,
            foreground: visuals.foreground,
            background: visuals.background,
            attributes: cellAttrs,
            underlineStyle: visuals.underlineStyle,
            underlineColor: visuals.underlineColor,
            hasHyperlink: visuals.hasHyperlink,
            wide: cell.wide)
          if pendingSpacerAfterLastGlyph {
            appendGlyphOrMergeAfterSpacer(
              glyph,
              bytes: Array(utf8Bytes),
              forceUTF8Storage: true)
          } else {
            let start = payload.utf8Bytes.count
            payload.utf8Bytes.append(contentsOf: utf8Bytes)
            var storedGlyph = glyph
            storedGlyph.utf8Range = start..<payload.utf8Bytes.count
            payload.glyphs.append(storedGlyph)
          }
        case .invalid:
          pendingSpacerAfterLastGlyph = false
          markFallback(.invalidUTF8)
        }
      }
    }

    let payloadEffectiveBlinking =
      resolvedCursor?.blinking ?? (snapshot.cursor_blinking != 0)
    let payloadEffectiveStyle =
      resolvedCursor?.style ?? snapshot.cursor_style
    if includeCursor,
      snapshot.cursor_visible != 0,
      !payloadEffectiveBlinking || cursorBlinkVisible,
      Int(snapshot.cursor_row) < rows,
      Int(snapshot.cursor_col) < cols
    {
      let cx = originX + CGFloat(snapshot.cursor_col) * cw
      let cy = originY + CGFloat(rows - 1 - Int(snapshot.cursor_row)) * ch + contentYOffset
      let cellRect = CGRect(x: cx, y: cy, width: cw, height: ch)
      for rect in Self.cursorRects(style: Int(payloadEffectiveStyle), cellRect: cellRect) {
        payload.cursorRects.append(
          TerminalCellPayload.CursorRect(rect: rect, color: Theme.current.cursor))
      }
    }
  }

  // Grapheme-cluster count over contiguous UTF-8 bytes, allocation-free. Uses
  // the same UAX-29 segmentation as `String.count`, so the spacer-merge
  // decision is identical to the legacy `(runText + text).count` comparison.
  @available(macOS 26, *)
  private static func graphemeClusterCount(_ utf8Bytes: Span<UInt8>) -> Int {
    guard let utf8 = try? UTF8Span(validating: utf8Bytes) else { return 0 }
    var iterator = utf8.makeCharacterIterator()
    var count = 0
    while iterator.next() != nil { count += 1 }
    return count
  }

  // macOS 26 glyph pass. Builds each coalesced run by appending raw UTF-8 bytes
  // into one reused buffer and materialises a single String per run at flush —
  // versus the legacy `String(bytes:encoding:)` allocation per cell, which
  // dominated the profile via per-call generic-metadata instantiation, malloc,
  // and ARC. Attribute masking uses raw bits (no cross-module OptionSet calls)
  // and grapheme merging uses UTF8Span (no per-cell Character/String). Output
  // is byte-identical to `appendLegacyTerminalGlyphRuns` (parity test).
  @available(macOS 26, *)
  private func appendFastTerminalGlyphRuns(
    into cmds: inout [FrameCommand],
    snapshot: LabanSnapshot,
    rows: Int,
    cols: Int,
    cw: CGFloat,
    ch: CGFloat,
    hyperlinkURIs: [String]
  ) {
    guard let cells = snapshot.cells else { return }
    let storage = snapshot.utf8_storage

    // One allocation, reused across every run in every row.
    var runBytes: [UInt8] = []
    runBytes.reserveCapacity(cols * 4)

    for row in 0..<rows {
      let cellY = originY + CGFloat(rows - 1 - row) * ch + contentYOffset
      let rowStart = row * cols

      var runStart: Int? = nil
      var runFg: UInt32 = 0
      var runBg: UInt32 = 0
      var runAttrsRaw: UInt16 = 0
      var runUnderlineStyle: UnderlineStyle = .none
      var runUnderlineColor: UInt32? = nil
      var runHyperlink: String? = nil
      var pendingSpacer = false
      runBytes.removeAll(keepingCapacity: true)

      func flushRun() {
        guard let start = runStart, !runBytes.isEmpty else {
          runStart = nil
          runBytes.removeAll(keepingCapacity: true)
          return
        }
        let cellX = originX + CGFloat(start) * cw
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: cellX, y: cellY),
            text: String(decoding: runBytes, as: UTF8.self),
            foreground: runFg,
            background: runBg,
            attributes: TextAttributes(rawValue: runAttrsRaw),
            source: .terminal,
            underlineStyle: runUnderlineStyle,
            underlineColor: runUnderlineColor,
            hyperlink: runHyperlink
          ))
        runStart = nil
        runBytes.removeAll(keepingCapacity: true)
        runUnderlineStyle = .none
        runUnderlineColor = nil
        runHyperlink = nil
      }

      for col in 0..<cols {
        let cell = cells[rowStart + col]
        let isSpacerTail = (cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL))
        let hasContent = cell.utf8_length > 0 && storage != nil

        if isSpacerTail {
          if runStart != nil { pendingSpacer = true }
          continue
        }

        let visuals = FrameProducer.resolvedVisuals(for: cell, hyperlinkURIs: hyperlinkURIs)

        guard hasContent, !visuals.isInvisible, let storage else {
          flushRun()
          pendingSpacer = false
          continue
        }

        let offset = Int(cell.utf8_offset)
        let length = Int(cell.utf8_length)
        let cellBytes = UnsafeBufferPointer<UInt8>(
          start: UnsafeRawPointer(storage).advanced(by: offset).assumingMemoryBound(to: UInt8.self),
          count: length)

        // Validate UTF-8 (mirrors `String(bytes:encoding:) != nil`) and detect a
        // lone procedural box-drawing scalar. Pure ASCII — the common case for
        // agent output — skips UTF8Span entirely and can never be procedural.
        var validUTF8 = false
        var proceduralScalar: Unicode.Scalar? = nil
        if length == 1, cellBytes[0] < 0x80 {
          validUTF8 = true
        } else if let utf8 = try? UTF8Span(validating: cellBytes.span) {
          validUTF8 = true
          var scalars = utf8.makeUnicodeScalarIterator()
          if let first = scalars.next(), scalars.next() == nil,
            BoxDrawing.isProceduralCellElement(first)
          {
            proceduralScalar = first
          }
        }

        guard validUTF8 else {
          flushRun()
          pendingSpacer = false
          continue
        }

        // Block and fixed-format geometric elements are emitted as procedural
        // .rect commands so they tile gap-free regardless of fallback metrics.
        if let scalar = proceduralScalar {
          flushRun()
          pendingSpacer = false
          let cellX = originX + CGFloat(col) * cw
          for filled in BoxDrawing.proceduralCellElementRects(
            scalar,
            at: CGPoint(x: cellX, y: cellY),
            cellWidth: cw,
            cellHeight: ch,
            foreground: visuals.foreground
          ) {
            cmds.append(.rect(filled.rect, color: filled.color, source: .terminal))
          }
          continue
        }

        let sameStyle =
          runFg == visuals.foreground && runBg == visuals.background
          && runAttrsRaw == visuals.attrsRaw
          && runUnderlineStyle == visuals.underlineStyle
          && runUnderlineColor == visuals.underlineColor
          && runHyperlink == visuals.hyperlink

        if runStart != nil, sameStyle {
          if pendingSpacer {
            // Resolve the held SPACER_TAIL: keep the wide cell and this one in
            // the same run iff merging shrinks the grapheme-cluster count.
            var merged = runBytes
            merged.append(contentsOf: cellBytes)
            let mergedCount = FrameProducer.graphemeClusterCount(merged.span)
            let separateCount =
              FrameProducer.graphemeClusterCount(runBytes.span)
              + FrameProducer.graphemeClusterCount(cellBytes.span)
            if mergedCount < separateCount {
              runBytes.append(contentsOf: cellBytes)
              pendingSpacer = false
            } else {
              flushRun()
              pendingSpacer = false
              runStart = col
              runFg = visuals.foreground
              runBg = visuals.background
              runAttrsRaw = visuals.attrsRaw
              runUnderlineStyle = visuals.underlineStyle
              runUnderlineColor = visuals.underlineColor
              runHyperlink = visuals.hyperlink
              runBytes.removeAll(keepingCapacity: true)
              runBytes.append(contentsOf: cellBytes)
            }
          } else {
            runBytes.append(contentsOf: cellBytes)
          }
        } else {
          flushRun()
          pendingSpacer = false
          runStart = col
          runFg = visuals.foreground
          runBg = visuals.background
          runAttrsRaw = visuals.attrsRaw
          runUnderlineStyle = visuals.underlineStyle
          runUnderlineColor = visuals.underlineColor
          runHyperlink = visuals.hyperlink
          runBytes.removeAll(keepingCapacity: true)
          runBytes.append(contentsOf: cellBytes)
        }
      }
      flushRun()
      pendingSpacer = false
    }
  }

  // Pre-macOS-26 / forced-legacy glyph pass. Kept byte-for-byte as it shipped;
  // the fast path is validated against this output.
  private func appendLegacyTerminalGlyphRuns(
    into cmds: inout [FrameCommand],
    snapshot: LabanSnapshot,
    rows: Int,
    cols: Int,
    cw: CGFloat,
    ch: CGFloat,
    hyperlinkURIs: [String]
  ) {
    guard let cells = snapshot.cells else { return }
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

        let visuals = FrameProducer.resolvedVisuals(for: cell, hyperlinkURIs: hyperlinkURIs)
        let cellAttrs = visuals.attributes

        if hasContent, !visuals.isInvisible, let storage = snapshot.utf8_storage {
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
                foreground: visuals.foreground
              ) {
                cmds.append(.rect(filled.rect, color: filled.color, source: .terminal))
              }
              continue
            }

            let sameStyle =
              runFg == visuals.foreground && runBg == visuals.background && runAttrs == cellAttrs
              && runUnderlineStyle == visuals.underlineStyle
              && runUnderlineColor == visuals.underlineColor
              && runHyperlink == visuals.hyperlink

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
                  runFg = visuals.foreground
                  runBg = visuals.background
                  runAttrs = cellAttrs
                  runUnderlineStyle = visuals.underlineStyle
                  runUnderlineColor = visuals.underlineColor
                  runHyperlink = visuals.hyperlink
                  runText = text
                }
              } else {
                runText += text
              }
            } else {
              flushRun()
              pendingSpacer = false
              runStart = col
              runFg = visuals.foreground
              runBg = visuals.background
              runAttrs = cellAttrs
              runUnderlineStyle = visuals.underlineStyle
              runUnderlineColor = visuals.underlineColor
              runHyperlink = visuals.hyperlink
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
  }

  public func commands(
    from snapshot: LabandSnapshotResponse,
    selection: TerminalSelection? = nil,
    cursorBlinkVisible: Bool = true,
    preedit: String? = nil,
    preeditCaretCells: Int = 0,
    userCursorStyle: CursorSettings.Style = .block
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
      // Advance the caret past any in-flight composition (preedit) so it
      // tracks the end of the marked text, matching the local snapshot path.
      let caretCol = min(snapshot.cursorCol + preeditCaretCells, cols - 1)
      let cellRect = CGRect(
        x: originX + CGFloat(caretCol) * cw,
        y: originY + CGFloat(rows - 1 - snapshot.cursorRow) * ch + contentYOffset,
        width: cw,
        height: ch
      )
      // Use the user's configured style for the remote cursor (ring snapshots
      // carry no explicit DECSCUSR override bits — Decision Log entry).
      for rect in Self.cursorRects(style: Int(userCursorStyle.labanStyleValue), cellRect: cellRect) {
        cmds.append(.cursor(rect, color: Theme.current.cursor))
      }
    }

    if let preedit {
      appendPreedit(
        into: &cmds,
        text: preedit,
        cursorRow: snapshot.cursorRow,
        cursorCol: snapshot.cursorCol,
        rows: rows,
        cols: cols,
        foreground: Theme.current.fg0,
        background: defaultBg)
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
