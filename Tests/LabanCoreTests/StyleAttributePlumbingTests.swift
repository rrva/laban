import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

// Pin the cell-style → frame-command plumbing for the styling features that
// the QA report at .artifacts/qa-rt/REPORT.md previously caught dropping
// silently. Each test feeds a minimal byte sequence and asserts the produced
// .glyphRun carries the expected attribute.
//
// These tests exercise the full pipeline: libghostty-vt parser →
// LabanTerminalCore snapshot → FrameProducer.commands → FrameCommand.
final class StyleAttributePlumbingTests: XCTestCase {

  private func runWithText(_ bytes: String) throws -> [FrameCommand] {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array(bytes.utf8))
    session.poll()
    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return []
    }
    defer { laban_snapshot_destroy(snap) }
    return FrameProducer(cellWidth: 9, cellHeight: 19).commands(from: UnsafePointer(snap))
  }

  private func firstGlyphRun(_ cmds: [FrameCommand], containing needle: String) -> FrameCommand? {
    for cmd in cmds {
      if case .glyphRun(_, let text, _, _, _, let src, _, _, _, _, _, _, _) = cmd,
        src == .terminal, text.contains(needle)
      {
        return cmd
      }
    }
    return nil
  }

  // MARK: - Underline sub-styles

  func testUnderlineSubStylesArePropagatedFromCSI4N() throws {
    let cases: [(seq: String, label: String, style: UnderlineStyle)] = [
      ("\u{1b}[4:1mSINGLE\u{1b}[0m", "SINGLE", .single),
      ("\u{1b}[4:2mDOUBLE\u{1b}[0m", "DOUBLE", .double),
      ("\u{1b}[4:3mCURLY\u{1b}[0m", "CURLY", .curly),
      ("\u{1b}[4:4mDOTTED\u{1b}[0m", "DOTTED", .dotted),
      ("\u{1b}[4:5mDASHED\u{1b}[0m", "DASHED", .dashed),
    ]
    for (seq, label, expected) in cases {
      let cmds = try runWithText(seq + "\r\n")
      guard
        case .glyphRun(_, _, _, _, _, _, let style, _, _, _, _, _, _)? = firstGlyphRun(
          cmds, containing: label)
      else {
        XCTFail("missing glyph run for \(label)")
        continue
      }
      XCTAssertEqual(
        style, expected, "underline sub-style for \(label) should be \(expected), got \(style)")
    }
  }

  // MARK: - Underline color (CSI 58)

  func testCSI58TruecolorPropagatesUnderlineColor() throws {
    let cmds = try runWithText("\u{1b}[4:1m\u{1b}[58:2::255:0:0mREDUNDER\u{1b}[0m\r\n")
    guard
      case .glyphRun(_, _, _, _, _, _, let style, let color, _, _, _, _, _)? =
        firstGlyphRun(cmds, containing: "REDUNDER")
    else {
      XCTFail("missing REDUNDER glyph run")
      return
    }
    XCTAssertEqual(style, .single)
    XCTAssertEqual(color, 0xFF00_00FF, "underline color should be opaque red")
  }

  func testCSI58PaletteIndexPropagatesUnderlineColorThroughPalette() throws {
    let cmds = try runWithText("\u{1b}[4:3m\u{1b}[58:5:46mGREEN\u{1b}[0m\r\n")
    guard
      case .glyphRun(_, _, _, _, _, _, let style, let color, _, _, _, _, _)? =
        firstGlyphRun(cmds, containing: "GREEN")
    else {
      XCTFail("missing GREEN glyph run")
      return
    }
    XCTAssertEqual(style, .curly)
    XCTAssertNotNil(color, "palette-index 46 should resolve to a non-nil RGB underline color")
    if let color {
      // Palette 46 is bright green in the ANSI 256-color cube; alpha must be 0xFF
      // so downstream code recognises it as set.
      XCTAssertEqual(color & 0xFF, 0xFF, "underline color must include opaque alpha")
    }
  }

  // MARK: - Blink (CSI 5 / 6)

  func testBlinkAttributeIsPropagatedFromCSI5() throws {
    let cmds = try runWithText("\u{1b}[5mBLINK\u{1b}[0m\r\n")
    guard
      case .glyphRun(_, _, _, _, let attrs, _, _, _, _, _, _, _, _)? =
        firstGlyphRun(cmds, containing: "BLINK")
    else {
      XCTFail("missing BLINK glyph run")
      return
    }
    XCTAssertTrue(
      attrs.contains(.blink), "blink attribute should be set on the glyph run; got \(attrs.names)")
  }

  func testRapidBlinkFromCSI6IsAlsoPropagated() throws {
    // libghostty-vt collapses slow/rapid blink onto a single boolean style.blink,
    // so we only assert that *some* blink survives (matches xterm/iTerm behaviour).
    let cmds = try runWithText("\u{1b}[6mFAST\u{1b}[0m\r\n")
    guard
      case .glyphRun(_, _, _, _, let attrs, _, _, _, _, _, _, _, _)? =
        firstGlyphRun(cmds, containing: "FAST")
    else {
      XCTFail("missing FAST glyph run")
      return
    }
    XCTAssertTrue(attrs.contains(.blink), "rapid blink should also surface via .blink")
  }
}
