import LabanTerminalCore
import XCTest

@testable import LabanCore

final class SessionKeyEncodingTests: XCTestCase {
  func testEncodeKeyGrowsBufferForLongNativeText() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let text = String(repeating: "a", count: 256)
    let event = KeyEvent(action: .press, key: .a, text: text)

    XCTAssertEqual(session.encodeKey(event), Array(text.utf8))
  }

  func testSendKeyCapturingBytesGrowsBufferForLongNativeText() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    let text = String(repeating: "a", count: 256)
    let event = KeyEvent(action: .press, key: .a, text: text)
    let sent = session.sendKeyCapturingBytes(event)

    XCTAssertEqual(sent.result, 0)
    XCTAssertEqual(sent.bytes, Array(text.utf8))
  }

  // Regression: forwarding a cmd+V image paste to Claude Code synthesizes a
  // Ctrl+V keystroke. For a daemon-backed session (laband/labpty) the PTY lives
  // out of process, so locally pty_fd < 0 and the send path encodes the key but
  // has nothing to write to — it reports no captured bytes, which silently
  // dropped the forwarded paste while a physical Ctrl+V kept working. The
  // forwarder must use encodeKey, which produces SYN (^V) regardless of PTY
  // ownership. A deferred (unspawned) session reproduces that pty_fd < 0 state.
  func testNoLocalPtySessionEncodesCtrlVButSendCapturesNothing() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.makeDeferred(size: size, cwd: "/tmp")
    defer { session.close() }

    let event = KeyEvent(action: .press, key: .v, modifiers: .control)

    XCTAssertEqual(session.encodeKey(event), [0x16])

    let sent = session.sendKeyCapturingBytes(event)
    XCTAssertNotEqual(sent.result, 0)
    XCTAssertTrue(sent.bytes.isEmpty)
  }
}
