import LabanCore
import LabanTerminalCore
import XCTest

final class TerminalPasteTests: XCTestCase {
  func testSanitizeKeepsTextAndPasteWhitespace() {
    XCTAssertEqual(TerminalPaste.sanitize("a\tb\nc\rd"), "a\tb\nc\rd")
  }

  func testSanitizeDropsC0DelAndC1Controls() {
    let input = "a\u{001B}]0;owned\u{0007}b\u{007F}c\u{009B}31md"
    XCTAssertEqual(TerminalPaste.sanitize(input), "a]0;ownedbc31md")
  }

  func testWritePasteCapturingBytesReturnsBracketedEncoding() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("\u{1b}[?2004h".utf8))
    let sent = session.writePasteCapturingBytes("hello")

    XCTAssertEqual(sent.result?.bracketed, true)
    XCTAssertEqual(sent.result?.bytesWritten, sent.bytes.count)
    let text = String(bytes: sent.bytes, encoding: .utf8)
    XCTAssertEqual(text, "\u{1b}[200~hello\u{1b}[201~")
  }

  /// Regression: in labpty / laband mode the local Session is a
  /// fixture (no PTY in-process), so writePasteCapturingBytes would
  /// feed the encoded paste bytes into the local VT — rendering the
  /// paste content into the grid before Claude Code ever saw it.
  /// encodePaste must return the same bytes WITHOUT touching the VT.
  func testEncodePasteReturnsBytesWithoutFeedingLocalGrid() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("\u{1b}[?2004h".utf8))
    let sent = session.encodePaste("hello")

    XCTAssertEqual(sent.result?.bracketed, true)
    XCTAssertEqual(sent.result?.bytesWritten, sent.bytes.count)
    let text = String(bytes: sent.bytes, encoding: .utf8)
    XCTAssertEqual(text, "\u{1b}[200~hello\u{1b}[201~")

    guard let snap = session.snapshot() else {
      XCTFail("snapshot")
      return
    }
    defer { laban_snapshot_destroy(snap) }
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else {
      XCTFail("snapshot cells")
      return
    }
    var grid = ""
    for row in 0..<rows {
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        if cell.utf8_length > 0 {
          let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(cell.utf8_length))
          grid += String(bytes: buf, encoding: .utf8) ?? ""
        }
      }
    }
    XCTAssertFalse(
      grid.contains("hello"),
      "encodePaste leaked paste content into the local grid: \(grid)")
  }

  /// When DECSET 2004 is *not* active, encodePaste must return the
  /// raw bytes unchanged (no `ESC[200~ … ESC[201~` wrapper). This is
  /// the safe-shell case where the caller already sanitised the
  /// paste and just wants the encoded form to forward to a remote
  /// PTY.
  func testEncodePasteReturnsRawBytesWhenBracketedPasteDisabled() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let sent = session.encodePaste("hello")
    XCTAssertEqual(sent.result?.bracketed, false)
    XCTAssertEqual(String(bytes: sent.bytes, encoding: .utf8), "hello")
  }

  /// An empty paste must short-circuit: no encoding, no bytes
  /// produced, no spurious side effects on the local Session.
  func testEncodePasteReturnsEmptyForEmptyText() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("\u{1b}[?2004h".utf8))
    let sent = session.encodePaste("")
    XCTAssertEqual(sent.result?.bytesWritten, 0)
    XCTAssertEqual(sent.bytes.count, 0)
  }

  /// Documents the inverse for the in-process backend: writePaste's
  /// fixture branch feeds the encoded bytes into the VT, so a fixture
  /// session DOES end up with the paste text in its grid. The live app
  /// only takes this branch when there is no remote coordinator —
  /// i.e. the in-process backend with a real PTY, where the equivalent
  /// flow is the PTY echo arriving back through libghostty.
  func testWritePasteFeedsFixtureGridForInProcessBackend() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("\u{1b}[?2004h".utf8))
    _ = session.writePasteCapturingBytes("hello")

    guard let snap = session.snapshot() else {
      XCTFail("snapshot")
      return
    }
    defer { laban_snapshot_destroy(snap) }
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else {
      XCTFail("snapshot cells")
      return
    }
    var grid = ""
    for row in 0..<rows {
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        if cell.utf8_length > 0 {
          let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(cell.utf8_length))
          grid += String(bytes: buf, encoding: .utf8) ?? ""
        }
      }
    }
    XCTAssertTrue(
      grid.contains("hello"),
      "writePaste's fixture branch should feed the paste text to the VT for in-process tests")
  }
}
