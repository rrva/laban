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
}
