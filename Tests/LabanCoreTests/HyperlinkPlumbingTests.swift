import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

// Pin the OSC 8 hyperlink plumbing: cells inside an OSC-8 link section must
// carry the URI and a default visual treatment (single underline in the
// theme accent color), and adjacent non-link text must NOT carry the link
// attribute.
final class HyperlinkPlumbingTests: XCTestCase {

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

  func testOSC8HyperlinkPropagatesURIAndDefaultStyling() throws {
    let esc = "\u{1b}"
    let st = "\u{1b}\\"
    let bytes =
      "before "
      + "\(esc)]8;;https://example.com\(st)example.com\(esc)]8;;\(st)"
      + " after\r\n"

    let cmds = try runWithText(bytes)

    var linkRun:
      (text: String, attrs: TextAttributes, style: UnderlineStyle, color: UInt32?, hl: String?)?
    var nonLinkRuns: [(text: String, hl: String?)] = []
    for cmd in cmds {
      if case .glyphRun(
        _, let text, _, _, let attrs, let src, let style, let color, let hl, _, _, _) =
        cmd,
        src == .terminal
      {
        if hl != nil {
          linkRun = (text, attrs, style, color, hl)
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
          nonLinkRuns.append((text, hl))
        }
      }
    }

    guard let link = linkRun else {
      XCTFail("expected a glyph run with hyperlink set")
      return
    }
    XCTAssertEqual(link.text, "example.com", "link cells should coalesce into one run")
    XCTAssertEqual(link.hl, "https://example.com")
    XCTAssertTrue(
      link.attrs.contains(.underline),
      "default link styling should set underline; got \(link.attrs.names)")
    XCTAssertEqual(link.style, .single, "default link styling should be single underline")
    XCTAssertNotNil(link.color, "default link styling should set an underline color")

    // The "before " and " after" chunks must NOT inherit the link.
    XCTAssertFalse(
      nonLinkRuns.isEmpty, "expected glyph runs around the link without hyperlink set")
    for (text, hl) in nonLinkRuns {
      XCTAssertNil(hl, "non-link run \(text.debugDescription) must not carry the URI")
    }
  }

  func testHyperlinkHitTestReturnsURIForLinkedCell() throws {
    let esc = "\u{1b}"
    let st = "\u{1b}\\"
    let bytes =
      "go "
      + "\(esc)]8;;https://example.com/docs\(st)site\(esc)]8;;\(st)"
      + " done\r\n"

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array(bytes.utf8))
    session.poll()
    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertNil(TerminalHyperlink.uri(atRow: 0, col: 0, in: snap.pointee))
    XCTAssertEqual(
      TerminalHyperlink.uri(atRow: 0, col: 3, in: snap.pointee),
      "https://example.com/docs")
    XCTAssertEqual(
      TerminalHyperlink.uri(atRow: 0, col: 6, in: snap.pointee),
      "https://example.com/docs")
    XCTAssertNil(TerminalHyperlink.uri(atRow: 0, col: 7, in: snap.pointee))
  }

  func testPlainHTTPURLHitTestReturnsURLUnderCell() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array("visit https://example.com/docs, ok\r\n".utf8))
    session.poll()
    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertNil(TerminalHyperlink.uri(atRow: 0, col: 1, in: snap.pointee))
    XCTAssertEqual(
      TerminalHyperlink.uri(atRow: 0, col: 6, in: snap.pointee),
      "https://example.com/docs")
    XCTAssertEqual(
      TerminalHyperlink.uri(atRow: 0, col: 29, in: snap.pointee),
      "https://example.com/docs")
    XCTAssertNil(
      TerminalHyperlink.uri(atRow: 0, col: 30, in: snap.pointee),
      "trailing punctuation is not part of the clickable URL")
  }

  func testPlainHTTPURLHitTestIgnoresInvalidBrowserURL() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array("bad http:// ok\r\n".utf8))
    session.poll()
    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertNil(TerminalHyperlink.uri(atRow: 0, col: 4, in: snap.pointee))
  }
}
