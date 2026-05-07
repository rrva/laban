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
}
