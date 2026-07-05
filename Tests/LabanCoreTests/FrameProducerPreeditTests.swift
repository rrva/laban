import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// IME/dictation preedit (marked text) is drawn inline at the cursor: macOS
/// streams the live composition through `setMarkedText`, and `FrameProducer`
/// turns it into an underlined glyph run at the cursor cell so the pending text
/// shows as the user speaks/composes instead of only after they commit. These
/// pin the producer-side emission, which is what every renderer (software,
/// classic Metal, and both GPU-cell builders) consumes.
final class FrameProducerPreeditTests: XCTestCase {
  private func snapshotAfterWriting(_ text: String) throws
    -> (Session, UnsafeMutablePointer<LabanSnapshot>)
  {
    try snapshotAfterWriting(text, graphemeClusterMode: false)
  }

  private func snapshotAfterWriting(
    _ text: String,
    graphemeClusterMode: Bool
  ) throws -> (Session, UnsafeMutablePointer<LabanSnapshot>) {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    session.setGraphemeClusterMode(graphemeClusterMode)
    session.write(Array(text.utf8))
    session.poll()
    guard let snap = session.snapshot() else {
      session.close()
      throw XCTSkip("snapshot must be non-nil")
    }
    return (session, snap)
  }

  private func preeditGlyphRun(in cmds: [FrameCommand])
    -> (origin: CGPoint, text: String, attrs: TextAttributes, underline: UnderlineStyle)?
  {
    for cmd in cmds {
      if case .glyphRun(let origin, let text, _, _, let attrs, .preedit, let uStyle, _, _, _) = cmd {
        return (origin, text, attrs, uStyle)
      }
    }
    return nil
  }

  private func preeditMaskRect(in cmds: [FrameCommand]) -> CGRect? {
    for cmd in cmds {
      if case .rect(let rect, _, .preedit) = cmd { return rect }
    }
    return nil
  }

  private func preeditDisplayCellCount(in cmds: [FrameCommand]) -> Int? {
    for cmd in cmds {
      if case .glyphRun(_, _, _, _, _, .preedit, _, _, _, let count) = cmd { return count }
    }
    return nil
  }

  func testPreeditEmitsUnderlinedGlyphRunAtCursor() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cw = 8
    let ch = 16
    let producer = FrameProducer(cellWidth: cw, cellHeight: ch)
    let composition = "こんにちは"
    let cmds = producer.commands(
      from: snap, selection: nil, cursorBlinkVisible: true, preedit: composition)

    let run = try XCTUnwrap(
      preeditGlyphRun(in: cmds),
      "a `.preedit` glyph run must be emitted so the live composition shows at the cursor")
    XCTAssertEqual(run.text, composition, "the run must carry the full marked text verbatim")
    XCTAssertTrue(
      run.attrs.contains(.underline), "preedit reads as pending via an underline")
    XCTAssertEqual(run.underline, .single)

    // It must anchor at the cursor cell, in the same view-space geometry the
    // cursor itself uses (origin {0,0}, no scroll offset here).
    let rows = Int(snap.pointee.rows)
    let cursorRow = Int(snap.pointee.cursor_row)
    let cursorCol = Int(snap.pointee.cursor_col)
    XCTAssertEqual(
      run.origin,
      CGPoint(x: CGFloat(cursorCol) * CGFloat(cw), y: CGFloat(rows - 1 - cursorRow) * CGFloat(ch)),
      "preedit must sit at the cursor cell")

    // A background mask is emitted in the same source so underlying cells do
    // not bleed through the composition.
    let hasMask = cmds.contains {
      if case .rect(_, _, .preedit) = $0 { return true }
      return false
    }
    XCTAssertTrue(hasMask, "a `.preedit` background rect must mask the cells under the composition")
  }

  func testNoPreeditCommandsWhenCompositionAbsent() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16)
      .commands(from: snap, selection: nil, cursorBlinkVisible: true, preedit: nil)

    XCTAssertNil(
      preeditGlyphRun(in: cmds), "no marked text means no preedit run on screen")
    XCTAssertFalse(
      cmds.contains {
        if case .rect(_, _, .preedit) = $0 { return true }
        return false
      }, "no marked text means no preedit mask either")
  }

  func testOverlayCommandsEmitPreeditForGPUCellPath() throws {
    let (session, snap) = try snapshotAfterWriting("ls ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    // The GPU-cell path skips the bulk terminal commands and draws the cursor,
    // selection, find — and now preedit — from `overlayCommands`. Without this
    // the composition would be invisible under the GPU renderer.
    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16)
      .overlayCommands(from: snap, selection: nil, cursorBlinkVisible: true, preedit: "ab")

    let run = try XCTUnwrap(
      preeditGlyphRun(in: cmds),
      "overlayCommands must carry the preedit so the GPU-cell renderer draws it")
    XCTAssertEqual(run.text, "ab")
    XCTAssertTrue(run.attrs.contains(.underline))
  }

  func testOverlayPreeditUsesDisplayCellWidthAtNonzeroCursorColumn() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cw = 8
    let ch = 16
    let producer = FrameProducer(cellWidth: cw, cellHeight: ch)
    let composition = "中文"
    let cursorCol = Int(snap.pointee.cursor_col)
    let expectedColumns = TerminalDisplayWidth.cells(of: composition)
    let cmds = producer.overlayCommands(
      from: snap, selection: nil, cursorBlinkVisible: true, preedit: composition)

    let run = try XCTUnwrap(
      preeditGlyphRun(in: cmds),
      "overlayCommands must emit preedit at the cursor for the GPU-cell path")
    let mask = try XCTUnwrap(
      preeditMaskRect(in: cmds),
      "overlay preedit must emit a background mask for wide compositions")

    XCTAssertEqual(
      run.origin.x, CGFloat(cursorCol) * CGFloat(cw), accuracy: 0.5,
      "overlay preedit must start at the live cursor column")
    XCTAssertEqual(
      mask.width,
      CGFloat(expectedColumns) * CGFloat(cw),
      accuracy: 0.5,
      "overlay mask width must use display-cell width for wide preedit")
  }

  func testOverlayPreeditMaskUsesDisplayCellWidthForZWJ() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cw = 8
    let ch = 16
    let composition = "👩\u{200D}💻"
    let expectedColumns = TerminalDisplayWidth.cells(of: composition)
    let cmds = FrameProducer(cellWidth: cw, cellHeight: ch)
      .overlayCommands(from: snap, selection: nil, cursorBlinkVisible: true, preedit: composition)

    let mask = try XCTUnwrap(
      preeditMaskRect(in: cmds),
      "overlay preedit must emit a background mask for clustered emoji")
    XCTAssertEqual(
      mask.width,
      CGFloat(expectedColumns) * CGFloat(cw),
      accuracy: 0.5,
      "overlay mask width must follow the same fallback width policy for ZWJ emoji")
  }

  private func firstCursorRect(in cmds: [FrameCommand]) -> CGRect? {
    for cmd in cmds {
      if case .cursor(let rect, _) = cmd { return rect }
    }
    return nil
  }

  func testCursorAdvancesToEndOfPreedit() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }
    let cw = 8
    let ch = 16
    let producer = FrameProducer(cellWidth: cw, cellHeight: ch)

    // The caret must move as the composition grows — otherwise it sticks at the
    // start of the marked text instead of tracking what the user is typing.
    let withoutPreedit = producer.commands(
      from: snap, selection: nil, cursorBlinkVisible: true, preedit: nil)
    let composition = "abc"  // three single-cell clusters
    let withPreedit = producer.commands(
      from: snap, selection: nil, cursorBlinkVisible: true,
      preedit: composition, preeditCaretCells: composition.count)

    let baseCaret = try XCTUnwrap(
      firstCursorRect(in: withoutPreedit),
      "the shell caret must be drawn so we can measure how far it advances")
    let composedCaret = try XCTUnwrap(
      firstCursorRect(in: withPreedit),
      "the caret must still be drawn while composing")

    XCTAssertEqual(
      composedCaret.origin.x - baseCaret.origin.x,
      CGFloat(composition.count) * CGFloat(cw),
      accuracy: 0.5,
      "a caret at the end of the composition advances one cell per cluster")
    XCTAssertEqual(
      composedCaret.origin.y, baseCaret.origin.y, accuracy: 0.5,
      "the caret stays on the cursor row while composing")
  }

  func testOverlayPreeditMaskUsesGraphemeClusterWidthForZWJUnderMode2027() throws {
    let (session, snap) = try snapshotAfterWriting("echo ", graphemeClusterMode: true)
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cw = 8
    let ch = 16
    let composition = "👩\u{200D}💻"
    let cmds = FrameProducer(cellWidth: cw, cellHeight: ch)
      .overlayCommands(from: snap, selection: nil, cursorBlinkVisible: true, preedit: composition)

    let mask = try XCTUnwrap(
      preeditMaskRect(in: cmds),
      "overlay preedit must emit a background mask for clustered emoji")
    XCTAssertEqual(
      mask.width,
      CGFloat(2 * cw),
      accuracy: 0.5,
      "under DEC mode 2027 the ZWJ emoji preedit mask must span 2 cells, not 4")

    let run = try XCTUnwrap(
      preeditGlyphRun(in: cmds),
      "overlay preedit must emit a glyph run for clustered emoji")
    XCTAssertEqual(
      run.origin.x + mask.width,
      CGFloat(Int(snap.pointee.cursor_col) + 2) * CGFloat(cw),
      accuracy: 0.5,
      "the preedit run origin + mask width must match the 2-cell advance")
  }

  func testPreeditGlyphRunCarriesDisplayCellCount() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cw = 8
    let ch = 16
    let composition = "中👩\u{200D}💻a"
    let expectedLegacyCells = TerminalDisplayWidth.cells(of: composition)
    let cmds = FrameProducer(cellWidth: cw, cellHeight: ch)
      .commands(from: snap, selection: nil, cursorBlinkVisible: true, preedit: composition)

    let run = try XCTUnwrap(preeditGlyphRun(in: cmds))
    XCTAssertEqual(run.origin.x, CGFloat(Int(snap.pointee.cursor_col)) * CGFloat(cw), accuracy: 0.5)
    // With mode 2027 off by default, the carried count follows the legacy
    // scalar fallback so the renderer never has to re-derive it from the mask.
    XCTAssertNotNil(
      preeditDisplayCellCount(in: cmds),
      "preedit glyphRun must carry a displayCellCount for renderer consistency")
    XCTAssertEqual(preeditDisplayCellCount(in: cmds), expectedLegacyCells)
  }

  func testPreeditCarriesDisplayCellCountForRendererConsistency() throws {
    let (session, snap) = try snapshotAfterWriting("echo ", graphemeClusterMode: true)
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cw = 8
    let ch = 16
    let composition = "👩\u{200D}💻"
    let cmds = FrameProducer(cellWidth: cw, cellHeight: ch)
      .commands(from: snap, selection: nil, cursorBlinkVisible: true, preedit: composition)

    let mask = try XCTUnwrap(preeditMaskRect(in: cmds))
    let run = try XCTUnwrap(preeditGlyphRun(in: cmds))
    XCTAssertEqual(
      mask.width,
      CGFloat(2 * cw),
      accuracy: 0.5,
      "mask must be sized to the mode-2027 display cell count")
    XCTAssertEqual(
      run.origin.x,
      mask.origin.x,
      accuracy: 0.5,
      "run and mask must share the same origin")
    XCTAssertEqual(
      preeditDisplayCellCount(in: cmds),
      2,
      "the producer must carry the mode-2027 display cell count on the glyph run")
  }

  func testPreeditMaskUsesDisplayCellWidthForWideText() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }
    let cw = 8
    let ch = 16
    let composition = "中👩\u{200D}💻a"

    let cmds = FrameProducer(cellWidth: cw, cellHeight: ch)
      .commands(from: snap, selection: nil, cursorBlinkVisible: true, preedit: composition)

    let mask = try XCTUnwrap(preeditMaskRect(in: cmds))

    XCTAssertEqual(
      mask.width,
      CGFloat(7 * cw),
      accuracy: 0.5,
      "preedit mask width must follow the terminal grid width of wide text")
  }

  func testCaretHonorsImeInsertionPointWithinComposition() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }
    let cw = 8
    let ch = 16
    let producer = FrameProducer(cellWidth: cw, cellHeight: ch)

    // An IME with the insertion point mid-composition (e.g. editing an earlier
    // syllable) reports a caret short of the end; the on-screen caret must land
    // exactly there, not at the composition's end.
    let base = try XCTUnwrap(
      firstCursorRect(in: producer.commands(from: snap, cursorBlinkVisible: true)))
    let midCaret = try XCTUnwrap(
      firstCursorRect(
        in: producer.commands(
          from: snap, selection: nil, cursorBlinkVisible: true,
          preedit: "abcde", preeditCaretCells: 2)))

    XCTAssertEqual(
      midCaret.origin.x - base.origin.x, CGFloat(2) * CGFloat(cw), accuracy: 0.5,
      "the caret must sit at the IME's insertion point (2 cells in), not at the end")
  }
}
