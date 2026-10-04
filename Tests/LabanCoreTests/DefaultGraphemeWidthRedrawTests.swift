import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Claude Code's fullscreen renderer measures a ZWJ emoji as one 2-column
/// cluster without negotiating DEC mode 2027, pads each line to the full
/// terminal width, and then moves with CR + relative cursor-down. A terminal
/// that counted the emoji as 4 columns wrapped that line, every later relative
/// move landed a row low, and a "Jump to bottom" toast was drawn into a row the
/// app never repaints. New sessions therefore start with mode 2027 ON.
final class DefaultGraphemeWidthRedrawTests: XCTestCase {
  private let suiteKey = GraphemeWidthSettings.defaultsKey
  private var saved: Any?

  override func setUp() {
    super.setUp()
    saved = UserDefaults.standard.object(forKey: suiteKey)
    UserDefaults.standard.removeObject(forKey: suiteKey)
  }

  override func tearDown() {
    if let saved {
      UserDefaults.standard.set(saved, forKey: suiteKey)
    } else {
      UserDefaults.standard.removeObject(forKey: suiteKey)
    }
    super.tearDown()
  }

  func testFullWidthLineWithZWJEmojiDoesNotWrapUnderFactoryDefault() throws {
    var size = LabanTerminalSize()
    size.rows = 6
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // "x 🧑‍💻 " is 5 columns as one cluster; pad to exactly 20.
    let line = "x 🧑\u{200D}💻 " + String(repeating: "-", count: 15)
    session.write(Array("\u{1b}[H\u{1b}[1B\(line)\r\u{1b}[1Btoast".utf8))

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }
    XCTAssertEqual(snap.pointee.grapheme_cluster_2027, 1, "factory default starts mode 2027 ON")
    XCTAssertEqual(
      Int(snap.pointee.cursor_row), 2, "CR + CUD after a full-width line moves one row")
    XCTAssertEqual(Int(snap.pointee.cursor_col), 5)
  }
}
