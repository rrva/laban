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
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
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
      if case .glyphRun(let origin, let text, _, _, let attrs, .preedit, let uStyle, _, _) = cmd {
        return (origin, text, attrs, uStyle)
      }
    }
    return nil
  }

  func testPreeditEmitsUnderlinedGlyphRunAtCursor() throws {
    let (session, snap) = try snapshotAfterWriting("echo ")
    defer {
      laban_snapshot_destroy(snap)
      session.close()
    }

    let cw = 8, ch = 16
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
}
