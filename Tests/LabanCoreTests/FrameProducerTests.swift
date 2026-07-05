import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

// Escape-sequence bytes for the colored-boxes fixture lines:
//   ESC[38;2;255;204;0m┌────────────┐ESC[0m\r\n
//   ESC[38;2;116;199;236m│ hello mvp  │ESC[0m\r\n
//   ESC[38;2;255;204;0m└────────────┘ESC[0m\r\n
private let coloredBoxesString =
  "\u{1B}[38;2;255;204;0m┌────────────┐\u{1B}[0m\r\n"
  + "\u{1B}[38;2;116;199;236m│ hello mvp  │\u{1B}[0m\r\n"
  + "\u{1B}[38;2;255;204;0m└────────────┘\u{1B}[0m\r\n"
private let coloredBoxesBytes: [UInt8] = Array(coloredBoxesString.utf8)

final class FrameProducerTests: XCTestCase {

  // MARK: - hello mvp fixture

  func testFixtureSessionWithHelloMvpProducesGlyphCommands() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(coloredBoxesBytes)
    session.poll()

    let snap = session.snapshot()
    defer { laban_snapshot_destroy(snap) }
    guard let snap else {
      XCTFail("snapshot must be non-nil")
      return
    }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    let glyphCmds = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, let src, _, _, _, _) = cmd, src == .terminal {
        return text
      }
      return nil
    }

    XCTAssertFalse(
      glyphCmds.isEmpty, "fixture session must produce at least one terminal glyph command")

    let allText = glyphCmds.joined()
    XCTAssertTrue(
      allText.contains("h") && allText.contains("e"),
      "glyph commands must contain characters from 'hello mvp'; got: \(allText.prefix(80))")
  }

  func testFixtureSessionPreservesArabicPresentationAndHangulGlyphs() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let text = "\u{FEB1}\u{B2C8}\u{C740}"
    session.write(Array(text.utf8))
    session.poll()

    let snap = session.snapshot()
    defer { laban_snapshot_destroy(snap) }
    guard let snap else {
      XCTFail("snapshot must be non-nil")
      return
    }

    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(from: UnsafePointer(snap))
    let allText = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, let src, _, _, _, _) = cmd, src == .terminal {
        return text
      }
      return nil
    }.joined()

    XCTAssertTrue(
      allText.contains(text),
      "terminal snapshot text must survive frame production; got \(allText.debugDescription)")
  }

  func testFixtureSessionProducesTerminalSourceCommands() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(coloredBoxesBytes)

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let cmds = FrameProducer().commands(from: UnsafePointer(snap))
    let terminalCmds = cmds.filter {
      if case .rect(_, _, let src) = $0 { return src == .terminal }
      if case .glyphRun(_, _, _, _, _, let src, _, _, _, _) = $0 { return src == .terminal }
      return false
    }
    XCTAssertFalse(terminalCmds.isEmpty, "commands must include terminal-sourced commands")
  }

  // MARK: - Box-drawing

  func testBoxDrawingFixtureProducesNonEmptyGlyphCommandsWithoutTextReplacement() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(coloredBoxesBytes)

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let cmds = FrameProducer().commands(from: UnsafePointer(snap))

    let glyphTexts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, let src, _, _, _, _) = cmd, src == .terminal {
        return text
      }
      return nil
    }

    XCTAssertFalse(glyphTexts.isEmpty, "box-drawing fixture must produce glyph commands")

    // Producer must not replace the box-drawing characters with substitute text
    let boxChars: [Character] = ["┌", "─", "┐", "│", "└", "┘"]
    for ch in boxChars {
      let found = glyphTexts.contains {
        $0.unicodeScalars.contains { Unicode.Scalar($0.value) == ch.unicodeScalars.first }
      }
      XCTAssertTrue(found, "box-drawing character '\(ch)' must appear verbatim in glyph commands")
    }
  }

  // MARK: - Block-element procedural rendering

  func testBlockElementsAreEmittedAsRectsNotGlyphs() throws {
    // Block elements (U+2580–U+259F) must be emitted as procedural .rect
    // commands so they tile gap-free regardless of font glyph metrics. This
    // keeps the renderer abstraction backend-agnostic.
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(Array("████ ▘▝▖▗".utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(from: UnsafePointer(snap))

    let glyphTexts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, let src, _, _, _, _) = cmd, src == .terminal {
        return text
      }
      return nil
    }
    let allGlyphText = glyphTexts.joined()
    for scalar in "████▘▝▖▗".unicodeScalars {
      XCTAssertFalse(
        allGlyphText.unicodeScalars.contains(scalar),
        "block element U+\(String(scalar.value, radix: 16, uppercase: true)) "
          + "must be emitted as .rect, not glyph text")
    }
  }

  func testFullBlockRunRendersGapFreeEndToEnd() throws {
    // End-to-end: a row of █ characters rendered through producer + software
    // renderer must completely cover its row of cells with no background
    // pixel surviving. This is the precise predicate behind the visible
    // hairline-gap bug.
    var size = LabanTerminalSize()
    size.rows = 1
    size.cols = 10
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let cols = 6
    session.write(Array(String(repeating: "█", count: cols).utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let cellW = 8
    let cellH = 16
    let surface = BitmapSurface(width: cellW * Int(size.cols), height: cellH)
    let bg = snap.pointee.default_background_rgba
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas())
    let producer = FrameProducer(cellWidth: cellW, cellHeight: cellH)
    renderer.render(producer.commands(from: UnsafePointer(snap)))

    for y in 0..<cellH {
      for x in 0..<(cellW * cols) {
        if let p = surface.pixel(x: x, y: y), p == bg {
          XCTFail("background pixel survived at (\(x),\(y)) — full blocks must tile gap-free")
          return
        }
      }
    }
  }

  // MARK: - Command structure

  func testFrameProducerIncludesBackgroundRectAndCursor() throws {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 10
    let session = try Session.fixture(size: size)
    defer { session.close() }

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    let hasTerminalRect = cmds.contains {
      if case .rect(_, _, let src) = $0 { return src == .terminal }
      return false
    }
    XCTAssertTrue(hasTerminalRect, "must contain at least one terminal rect command")

    // Cursor is emitted when cursor_visible is set (libghostty defaults to visible)
    let hasCursor = cmds.contains {
      if case .cursor = $0 { return true }
      return false
    }
    XCTAssertTrue(hasCursor, "must include cursor command for fresh session")
  }

  func testFrameProducerShapesAndBlinksCursorStyles() throws {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 10
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(Array("\u{1B}[5 q".utf8))  // blinking bar cursor
    guard let barSnap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(barSnap) }

    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    let hiddenBlink = producer.commands(
      from: UnsafePointer(barSnap),
      cursorBlinkVisible: false)
    XCTAssertFalse(
      hiddenBlink.contains { if case .cursor = $0 { return true } else { return false } },
      "blinking cursor should emit no cursor command during the off phase")

    let visibleBlinkRects = producer.commands(
      from: UnsafePointer(barSnap),
      cursorBlinkVisible: true
    ).compactMap { cmd -> CGRect? in
      if case .cursor(let rect, _) = cmd { return rect }
      return nil
    }
    XCTAssertEqual(visibleBlinkRects.count, 1)
    XCTAssertEqual(visibleBlinkRects.first?.width, 2)
    XCTAssertEqual(visibleBlinkRects.first?.height, 20)

    session.write(Array("\u{1B}[4 q".utf8))  // steady underline cursor
    guard let underlineSnap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(underlineSnap) }

    let steadyUnderlineRects = producer.commands(
      from: UnsafePointer(underlineSnap),
      cursorBlinkVisible: false
    ).compactMap { cmd -> CGRect? in
      if case .cursor(let rect, _) = cmd { return rect }
      return nil
    }
    XCTAssertEqual(steadyUnderlineRects.count, 1)
    XCTAssertEqual(steadyUnderlineRects.first?.width, 10)
    XCTAssertEqual(steadyUnderlineRects.first?.height, 2)

    let hollowRects = FrameProducer.cursorRects(
      style: Int(LABAN_CURSOR_STYLE_BLOCK_HOLLOW),
      cellRect: CGRect(x: 0, y: 0, width: 10, height: 20))
    XCTAssertEqual(hollowRects.count, 4)
  }

  func testAccessibilityVisualOptionsAddSelectionAndCursorOutlines() throws {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 10
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(Array("hello".utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let selection = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: 0, col: 0),
      focus: TerminalCellCoordinate(row: 0, col: 2))
    let resolvedCursor = (style: CursorSettings.Style.block.labanStyleValue, blinking: false)
    let standard = FrameProducer(cellWidth: 10, cellHeight: 20).commands(
      from: UnsafePointer(snap),
      selection: selection,
      cursorBlinkVisible: true,
      resolvedCursor: resolvedCursor)
    let accessible = FrameProducer(
      cellWidth: 10,
      cellHeight: 20,
      accessibilityVisualOptions: TerminalAccessibilityVisualOptions(
        increaseContrast: true,
        differentiateWithoutColor: true)
    ).commands(
      from: UnsafePointer(snap),
      selection: selection,
      cursorBlinkVisible: true,
      resolvedCursor: resolvedCursor)

    XCTAssertGreaterThan(
      selectionColors(in: accessible).count,
      selectionColors(in: standard).count,
      "display accessibility must add outline selection cues, not only recolor")
    XCTAssertGreaterThan(
      cursorRects(in: accessible).count,
      cursorRects(in: standard).count,
      "display accessibility must add a stronger cursor outline")
  }

  func testAccessibilityVisualOptionsMakeTerminalBackgroundOpaque() {
    var snap = makeExitSnapshot(status: 0, exitStatus: 0)
    snap.default_background_rgba = 0x1122_3344
    let producer = FrameProducer(
      accessibilityVisualOptions: TerminalAccessibilityVisualOptions(reduceTransparency: true))

    let cmds = withUnsafePointer(to: &snap) { producer.commands(from: $0) }

    guard case .rect(_, let color, let source)? = cmds.first else {
      XCTFail("first command must be the terminal background")
      return
    }
    XCTAssertEqual(source, .terminal)
    XCTAssertEqual(color, 0x1122_33FF)
  }

  func testFrameProducerTexturedQuadTypeIsSupported() {
    // Verify the texturedQuad case compiles and can be pattern-matched.
    let cmd: FrameCommand = .texturedQuad(
      rect: CGRect(x: 0, y: 0, width: 16, height: 16),
      resourceId: 7,
      source: .image
    )
    if case .texturedQuad(_, let rid, let src) = cmd {
      XCTAssertEqual(rid, 7)
      XCTAssertEqual(src, .image)
    } else {
      XCTFail("texturedQuad must match")
    }
  }

  // MARK: - Coalescing tests

  func testSameStyleRowProducesOneGlyphRun() throws {
    // A row of same-style text should coalesce into one glyphRun.
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let bytes = Array("Hello, this is coalesced text!\r\n".utf8)
    session.write(bytes)

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    let terminalGlyphs = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, let src, _, _, _, _) = cmd, src == .terminal {
        return text
      }
      return nil
    }

    // The first row of text "Hello, this is coalesced text!" should be
    // emitted as a single glyphRun (or at most a few if palette colors differ).
    let allJoined = terminalGlyphs.joined()
    XCTAssertTrue(allJoined.contains("Hello"), "coalesced text must contain 'Hello'")

    // The number of distinct glyph runs should be far below the cell count.
    // A single line of uniform text should produce at most a few runs
    // (one for the line, possibly one for the blank rest of the row).
    XCTAssertLessThan(
      terminalGlyphs.count, 80,
      "coalesced output should have far fewer glyph runs than cells")
  }

  func testBlankGridCommandCountIsLow() throws {
    // A blank grid should not emit one rect per cell.
    var size = LabanTerminalSize()
    size.rows = 10
    size.cols = 30
    let session = try Session.fixture(size: size)
    defer { session.close() }

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    // The blank grid at default bg should produce:
    // 1 terminal background rect + cursor (active by default) = 2 commands
    // If cursor is visible, expect 2; if not, expect 1.
    let hasCursor = cmds.contains {
      if case .cursor = $0 { return true }
      return false
    }
    let expectedMax = hasCursor ? 3 : 2
    XCTAssertLessThanOrEqual(
      cmds.count, expectedMax,
      "blank grid with default background should not emit per-cell rects; "
        + "got \(cmds.count) commands")
  }

  // MARK: - Large snapshot smoke (diagnostic)

  func testLargeSnapshotFrameCommandCount() throws {
    var size = LabanTerminalSize()
    size.rows = 50
    size.cols = 220
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // Write enough text to fill some rows
    let line = String(repeating: "X", count: 220) + "\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<10 { session.write(lineBytes) }

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let start = Date()
    let cmds = producer.commands(from: UnsafePointer(snap))
    let elapsed = Date().timeIntervalSince(start)

    let glyphCount = cmds.filter {
      if case .glyphRun = $0 { return true }
      return false
    }.count
    print(
      "[smoke] large-snapshot: \(cmds.count) total commands, \(glyphCount) glyph commands, "
        + "\(String(format: "%.2f", elapsed * 1000))ms, 220x50 grid")

    // Not a benchmark gate; just verify it completes and produces a plausible count
    XCTAssertGreaterThan(cmds.count, 0)
  }

  // MARK: - Exit banner tests

  private func makeExitSnapshot(status: Int32, exitStatus: Int32) -> LabanSnapshot {
    var snap = LabanSnapshot()
    snap.rows = 24
    snap.cols = 80
    snap.status = status
    snap.exit_status = exitStatus
    snap.cells = nil
    return snap
  }

  func testNoBannerWhenRunning() {
    var snap = makeExitSnapshot(status: 0, exitStatus: 0)
    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = withUnsafePointer(to: &snap) { producer.commands(from: $0) }
    let exitLabels = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _) = cmd,
        text.localizedCaseInsensitiveContains("exited")
          || text.localizedCaseInsensitiveContains("signaled")
      {
        return text
      }
      return nil
    }
    XCTAssertTrue(
      exitLabels.isEmpty,
      "running snapshot must not produce exit banner; got \(exitLabels)")
  }

  func testBannerWhenExitedNormal() {
    var snap = makeExitSnapshot(status: 1, exitStatus: 0)
    let producer = FrameProducer(cellWidth: 8, cellHeight: 16, originX: 0, originY: 10)
    let cmds = withUnsafePointer(to: &snap) { producer.commands(from: $0) }
    let bannerRects = cmds.compactMap { cmd -> CGRect? in
      if case .rect(let r, _, _) = cmd, abs(r.origin.y - 10) < 1 { return r }
      return nil
    }
    XCTAssertFalse(bannerRects.isEmpty, "exited snapshot must produce a banner rect at originY")
    let bannerLabels = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _) = cmd, text.contains("exited") {
        return text
      }
      return nil
    }
    XCTAssertFalse(
      bannerLabels.isEmpty,
      "exited snapshot must produce a glyph run containing 'exited'")
    XCTAssertTrue(
      bannerLabels.contains(where: { $0.contains("0") }),
      "exit code 0 must appear in banner text; got \(bannerLabels)")
  }

  func testExitBannerCommandsOverlayTerminalGlyphs() throws {
    var size = LabanTerminalSize()
    size.rows = 3
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array("visible before exit".utf8))

    guard let ownedSnapshot = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(ownedSnapshot) }

    var snap = ownedSnapshot.pointee
    snap.status = 1
    snap.exit_status = 7
    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = withUnsafePointer(to: &snap) { producer.commands(from: $0) }

    let contentIndex = cmds.firstIndex { cmd in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _) = cmd {
        return text.contains("visible before exit")
      }
      return false
    }
    let bannerRectIndex = cmds.firstIndex { cmd in
      if case .rect(let rect, let color, _) = cmd {
        return rect.origin.y == 0 && color == Theme.current.bg1
      }
      return false
    }
    let bannerGlyphIndex = cmds.firstIndex { cmd in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _) = cmd {
        return text.contains("Process exited 7")
      }
      return false
    }

    guard let contentIndex, let bannerRectIndex, let bannerGlyphIndex else {
      XCTFail("expected content and exit banner commands; got \(cmds)")
      return
    }
    XCTAssertGreaterThan(bannerRectIndex, contentIndex)
    XCTAssertGreaterThan(bannerGlyphIndex, contentIndex)
  }

  func testBannerWhenExitedSignal() {
    var snap = makeExitSnapshot(status: 2, exitStatus: 15)
    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = withUnsafePointer(to: &snap) { producer.commands(from: $0) }
    let bannerLabels = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _) = cmd, text.contains("signaled") {
        return text
      }
      return nil
    }
    XCTAssertFalse(bannerLabels.isEmpty, "signal exit must produce glyph run containing 'signaled'")
    XCTAssertTrue(
      bannerLabels.contains(where: { $0.contains("15") }),
      "signal number 15 must appear in banner text; got \(bannerLabels)")
  }

  // MARK: - SGR attributes

  func testZshAnsiNamedColorsUseInjectedThemePalette() throws {
    let oldTheme = Theme.current
    Theme.apply(Theme.selenizedDark)
    defer { Theme.apply(oldTheme) }

    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let model = try AppModel(initialSize: size) { size in
      try Session.fixture(size: size)
    }

    guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
      XCTFail("model must expose its initial active session")
      return
    }

    // These are the forms zsh emits for prompt escapes like %F{red} and %K{blue}.
    let line = "\u{1B}[31mRED\u{1B}[39m \u{1B}[44mBG\u{1B}[49m\r\n"
    session.write(Array(line.utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(from: UnsafePointer(snap))

    guard let redRun = terminalGlyphRun(in: cmds, containing: "RED") else {
      XCTFail("missing RED glyph run")
      return
    }
    XCTAssertEqual(
      redRun.foreground, Theme.selenizedDark.ansi16[1],
      "zsh named foreground color must resolve through the injected ANSI palette")

    guard let bgRun = terminalGlyphRun(in: cmds, containing: "BG") else {
      XCTFail("missing BG glyph run")
      return
    }
    XCTAssertEqual(
      bgRun.background, Theme.selenizedDark.ansi16[4],
      "zsh named background color must resolve through the injected ANSI palette")
  }

  func testZshIndexedAndTruecolorSgrColorsReachGlyphRuns() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // zsh expands %F{46}, %F{#00ff00}, and %K{#112233} to these SGR forms.
    let line =
      "\u{1B}[38;5;46mIDX\u{1B}[39m "
      + "\u{1B}[38;2;0;255;0mHEX\u{1B}[39m "
      + "\u{1B}[48;2;17;34;51mBGHEX\u{1B}[49m\r\n"
    session.write(Array(line.utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(from: UnsafePointer(snap))

    guard let indexed = terminalGlyphRun(in: cmds, containing: "IDX") else {
      XCTFail("missing IDX glyph run")
      return
    }
    XCTAssertEqual(indexed.foreground, 0x00FF_00FF, "256-color index 46 should be green")

    guard let truecolor = terminalGlyphRun(in: cmds, containing: "HEX") else {
      XCTFail("missing HEX glyph run")
      return
    }
    XCTAssertEqual(truecolor.foreground, 0x00FF_00FF, "truecolor foreground must survive")

    guard let truecolorBg = terminalGlyphRun(in: cmds, containing: "BGHEX") else {
      XCTFail("missing BGHEX glyph run")
      return
    }
    XCTAssertEqual(truecolorBg.background, 0x1122_33FF, "truecolor background must survive")
  }

  func testZshPaletteSchemeOsc4RgbFormAffectsAnsiColors() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // Shell color-scheme scripts commonly use OSC 4 with rgb:RR/GG/BB and ST.
    let line =
      "\u{1B}]4;1;rgb:12/34/56\u{1B}\\"
      + "\u{1B}[31mRED\u{1B}[39m\r\n"
    session.write(Array(line.utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(from: UnsafePointer(snap))

    guard let redRun = terminalGlyphRun(in: cmds, containing: "RED") else {
      XCTFail("missing RED glyph run")
      return
    }
    XCTAssertEqual(
      redRun.foreground, 0x1234_56FF,
      "zsh palette scripts must be able to update ANSI colors via OSC 4 rgb: form")
  }

  // Bold/italic/underline/strikethrough/overline must propagate from the
  // Ghostty render state through LabanCell.flags to FrameCommand.glyphRun
  // attributes. The fixture writes overlapping SGR ranges so a single line
  // covers multiple attribute combinations.
  func testSgrAttributesAppearOnGlyphRuns() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let line =
      "\u{1B}[1mBOLD\u{1B}[0m "
      + "\u{1B}[3mIT\u{1B}[0m "
      + "\u{1B}[4mUL\u{1B}[0m "
      + "\u{1B}[9mSTRK\u{1B}[0m "
      + "\u{1B}[53mOVR\u{1B}[0m\r\n"
    session.write(Array(line.utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    func attrs(matching needle: String) -> TextAttributes? {
      for cmd in cmds {
        if case .glyphRun(_, let text, _, _, let attributes, let src, _, _, _, _) = cmd,
          src == .terminal, text.contains(needle)
        {
          return attributes
        }
      }
      return nil
    }

    XCTAssertEqual(attrs(matching: "BOLD"), .bold)
    XCTAssertEqual(attrs(matching: "IT"), .italic)
    XCTAssertEqual(attrs(matching: "UL"), .underline)
    XCTAssertEqual(attrs(matching: "STRK"), .strikethrough)
    XCTAssertEqual(attrs(matching: "OVR"), .overline)
  }

  // SGR 7 (inverse) must swap foreground and background at the snapshot
  // layer so the renderer never has to know about inverse video. The
  // FrameCommand for an inverse-styled cell carries the swapped colors.
  func testInverseVideoSwapsForegroundAndBackground() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // SGR 38;2 sets truecolor fg; SGR 48;2 sets truecolor bg; SGR 7 inverts.
    let line =
      "\u{1B}[38;2;255;0;0m\u{1B}[48;2;0;0;255mFG\u{1B}[0m"
      + "\u{1B}[38;2;255;0;0m\u{1B}[48;2;0;0;255m\u{1B}[7mIN\u{1B}[0m\r\n"
    session.write(Array(line.utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    var normalFg: UInt32 = 0
    var normalBg: UInt32 = 0
    var inverseFg: UInt32 = 0
    var inverseBg: UInt32 = 0
    for cmd in cmds {
      if case .glyphRun(_, let text, let fg, let bg, _, let src, _, _, _, _) = cmd,
        src == .terminal
      {
        if text.contains("FG") {
          normalFg = fg
          normalBg = bg
        }
        if text.contains("IN") {
          inverseFg = fg
          inverseBg = bg
        }
      }
    }

    XCTAssertEqual((normalFg >> 24) & 0xFF, 255, "non-inverse fg should be red")
    XCTAssertEqual((normalBg >> 8) & 0xFF, 255, "non-inverse bg should be blue")
    XCTAssertEqual(inverseFg, normalBg, "inverse fg must equal non-inverse bg")
    XCTAssertEqual(inverseBg, normalFg, "inverse bg must equal non-inverse fg")
  }

  // A run that changes attributes mid-row must split into separate glyph
  // runs even when fg and bg do not change. Without this split, the
  // software renderer would apply one set of attributes (e.g. bold) to
  // both halves.
  func testGlyphRunSplitsWhenAttributesChange() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let line = "AB\u{1B}[1mCD\u{1B}[0mEF\r\n"
    session.write(Array(line.utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    var runs: [(text: String, attrs: TextAttributes)] = []
    for cmd in cmds {
      if case .glyphRun(_, let text, _, _, let attributes, let src, _, _, _, _) = cmd,
        src == .terminal,
        text.contains("A") || text.contains("C") || text.contains("E")
      {
        runs.append((text, attributes))
      }
    }
    let nonBold = runs.filter { !$0.attrs.contains(.bold) }
    let bold = runs.filter { $0.attrs.contains(.bold) }
    XCTAssertFalse(bold.isEmpty, "expected a bold glyph run for CD")
    XCTAssertFalse(nonBold.isEmpty, "expected non-bold glyph runs for AB and EF")
    XCTAssertTrue(
      bold.contains { $0.text.contains("CD") },
      "bold glyph run must contain 'CD'; got \(bold)")
  }

  // Triangle glyphs must render as procedural rects so they tile inside
  // the cell instead of leaking into adjacent cells via fallback fonts.
  func testTriangleGlyphsRenderAsProceduralRects() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }

    session.write(Array("\u{25E2}\u{25E3}\u{25E4}\u{25E5}\r\n".utf8))
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    let triangleGlyphs = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _) = cmd,
        text.unicodeScalars.contains(where: { (0x25E2...0x25E5).contains($0.value) })
      {
        return text
      }
      return nil
    }
    XCTAssertTrue(
      triangleGlyphs.isEmpty,
      "triangle glyphs must not be emitted as glyph runs; got \(triangleGlyphs)")
  }

  private func terminalGlyphRun(
    in cmds: [FrameCommand],
    containing needle: String
  ) -> (text: String, foreground: UInt32, background: UInt32)? {
    for cmd in cmds {
      if case .glyphRun(_, let text, let foreground, let background, _, let src, _, _, _, _) = cmd,
        src == .terminal, text.contains(needle)
      {
        return (text, foreground, background)
      }
    }
    return nil
  }

  // MARK: - resolvedCursor parameter

  func testResolvedCursorStyle_UserBarAppliesWhenNoOverride() throws {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 10
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // No DECSCUSR written: user setting is bar
    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    let cmds = producer.commands(
      from: UnsafePointer(snap),
      selection: nil,
      cursorBlinkVisible: true,
      resolvedCursor: (style: CursorSettings.Style.bar.labanStyleValue, blinking: false))
    let cursorRects = cmds.compactMap { cmd -> CGRect? in
      if case .cursor(let r, _) = cmd { return r } else { return nil }
    }
    XCTAssertEqual(cursorRects.count, 1, "resolved bar style must emit one cursor rect")
    XCTAssertEqual(cursorRects.first?.width, 2, "bar cursor width must be ~2 px at cw=10")
  }

  func testResolvedCursorStyle_UserUnderlineAppliesWhenNoOverride() throws {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 10
    let session = try Session.fixture(size: size)
    defer { session.close() }
    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    let cmds = producer.commands(
      from: UnsafePointer(snap),
      selection: nil,
      cursorBlinkVisible: true,
      resolvedCursor: (style: CursorSettings.Style.underline.labanStyleValue, blinking: false))
    let cursorRects = cmds.compactMap { cmd -> CGRect? in
      if case .cursor(let r, _) = cmd { return r } else { return nil }
    }
    XCTAssertEqual(cursorRects.count, 1)
    XCTAssertEqual(cursorRects.first?.height, 2, "underline cursor height must be ~2 px at ch=20")
  }

  func testResolvedCursorBlink_HidesWhenResolved() throws {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 10
    let session = try Session.fixture(size: size)
    defer { session.close() }
    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    // resolvedCursor.blinking = true, cursorBlinkVisible = false -> hidden
    let cmds = producer.commands(
      from: UnsafePointer(snap),
      selection: nil,
      cursorBlinkVisible: false,
      resolvedCursor: (style: CursorSettings.Style.block.labanStyleValue, blinking: true))
    XCTAssertFalse(
      cmds.contains { if case .cursor = $0 { return true } else { return false } },
      "resolved blinking cursor must be hidden when cursorBlinkVisible is false")
  }

  // MARK: - Remote (laband) snapshot cursor styling

  private func remoteSnapshotFixture(rows: Int = 5, cols: Int = 10) -> LabandSnapshotResponse {
    LabandSnapshotResponse(
      logicalSessionId: "remote-test",
      incarnationId: "inc-1",
      rows: rows,
      cols: cols,
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: false,
      visibleText: "",
      cells: [])
  }

  private func remoteCursorRects(_ cmds: [FrameCommand]) -> [CGRect] {
    cmds.compactMap { cmd -> CGRect? in
      if case .cursor(let r, _) = cmd { return r } else { return nil }
    }
  }

  private func cursorRects(in cmds: [FrameCommand]) -> [CGRect] {
    cmds.compactMap { cmd -> CGRect? in
      if case .cursor(let r, _) = cmd { return r } else { return nil }
    }
  }

  private func selectionColors(in cmds: [FrameCommand]) -> [UInt32] {
    cmds.compactMap { cmd -> UInt32? in
      if case .selection(_, let color) = cmd { return color } else { return nil }
    }
  }

  /// The user-default path: omitting `userCursorStyle` must draw the default
  /// full-cell block on a remote (laband) snapshot.
  func testRemoteCursor_DefaultStyleDrawsFullCellBlock() {
    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    let cmds = producer.commands(from: remoteSnapshotFixture())
    let rects = remoteCursorRects(cmds)
    XCTAssertEqual(rects.count, 1, "remote default cursor must emit one rect")
    XCTAssertEqual(rects.first?.width, 10, "default block must span the full cell width")
    XCTAssertEqual(rects.first?.height, 20, "default block must span the full cell height")
  }

  func testRemoteCursor_UserBarShapesRemoteCursor() {
    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    let cmds = producer.commands(from: remoteSnapshotFixture(), userCursorStyle: .bar)
    let rects = remoteCursorRects(cmds)
    XCTAssertEqual(rects.count, 1)
    XCTAssertEqual(rects.first?.width, 2, "user bar must shape the remote cursor (~2 px at cw=10)")
    XCTAssertEqual(rects.first?.height, 20, "bar spans the full cell height")
  }

  func testRemoteCursor_UserUnderlineShapesRemoteCursor() {
    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    let cmds = producer.commands(from: remoteSnapshotFixture(), userCursorStyle: .underline)
    let rects = remoteCursorRects(cmds)
    XCTAssertEqual(rects.count, 1)
    XCTAssertEqual(
      rects.first?.height, 2, "user underline must shape the remote cursor (~2 px at ch=20)")
    XCTAssertEqual(rects.first?.width, 10, "underline spans the full cell width")
  }

  /// Remote frames hide the cursor entirely when the daemon says so —
  /// styling must not resurrect it.
  func testRemoteCursor_HiddenWhenSnapshotCursorInvisible() {
    var snapshot = remoteSnapshotFixture()
    snapshot.cursorVisible = false
    let producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    let cmds = producer.commands(from: snapshot, userCursorStyle: .bar)
    XCTAssertTrue(
      remoteCursorRects(cmds).isEmpty,
      "an invisible remote cursor must emit no cursor rects regardless of user style")
  }

  func testRemoteAccessibilityVisualOptionsAddSelectionAndCursorOutlines() {
    let selection = TerminalSelection(
      sessionId: "remote-test",
      anchor: TerminalCellCoordinate(row: 0, col: 0),
      focus: TerminalCellCoordinate(row: 0, col: 2))
    let standard = FrameProducer(cellWidth: 10, cellHeight: 20).commands(
      from: remoteSnapshotFixture(rows: 2, cols: 4),
      selection: selection)
    let accessible = FrameProducer(
      cellWidth: 10,
      cellHeight: 20,
      accessibilityVisualOptions: TerminalAccessibilityVisualOptions(
        increaseContrast: true,
        differentiateWithoutColor: true)
    ).commands(
      from: remoteSnapshotFixture(rows: 2, cols: 4),
      selection: selection)

    XCTAssertGreaterThan(selectionColors(in: accessible).count, selectionColors(in: standard).count)
    XCTAssertGreaterThan(cursorRects(in: accessible).count, cursorRects(in: standard).count)
  }
}
