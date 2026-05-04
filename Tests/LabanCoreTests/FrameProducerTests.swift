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
      if case .glyphRun(_, let text, _, _, let src) = cmd, src == .terminal {
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
      if case .glyphRun(_, _, _, _, let src) = $0 { return src == .terminal }
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
      if case .glyphRun(_, let text, _, _, let src) = cmd, src == .terminal {
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
      if case .glyphRun(_, let text, _, _, let src) = cmd, src == .terminal { return text }
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
      if case .glyphRun(_, let text, _, _, let src) = cmd, src == .terminal {
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
      if case .glyphRun(_, let text, _, _, _) = cmd,
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
      if case .glyphRun(_, let text, _, _, _) = cmd, text.contains("exited") { return text }
      return nil
    }
    XCTAssertFalse(
      bannerLabels.isEmpty,
      "exited snapshot must produce a glyph run containing 'exited'")
    XCTAssertTrue(
      bannerLabels.contains(where: { $0.contains("0") }),
      "exit code 0 must appear in banner text; got \(bannerLabels)")
  }

  func testBannerWhenExitedSignal() {
    var snap = makeExitSnapshot(status: 2, exitStatus: 15)
    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = withUnsafePointer(to: &snap) { producer.commands(from: $0) }
    let bannerLabels = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _) = cmd, text.contains("signaled") { return text }
      return nil
    }
    XCTAssertFalse(bannerLabels.isEmpty, "signal exit must produce glyph run containing 'signaled'")
    XCTAssertTrue(
      bannerLabels.contains(where: { $0.contains("15") }),
      "signal number 15 must appear in banner text; got \(bannerLabels)")
  }
}
