import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// A labpty reattach replays the byte ring from offset 0 through the viewer
/// session's parser. Host side effects carried in that historical output —
/// an OSC 52 clipboard write, an OSC 9 notification — already happened when the
/// bytes were live; replaying them would overwrite the user's current clipboard
/// with stale text and re-post old notifications. `withHostEffectsSuppressed`
/// is the seam the feed loop wraps replay reads in.
final class SessionHostEffectSuppressionTests: XCTestCase {
  private let osc52Write = Array("\u{1b}]52;c;aGVsbG8=\u{07}".utf8)  // "hello"
  private let osc9Notify = Array("\u{1b}]9;build done\u{07}".utf8)

  private func makeSession() throws -> Session {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return try Session.fixture(size: size)
  }

  func testLiveFeedDeliversClipboardWriteAndNotification() throws {
    let session = try makeSession()
    defer { session.close() }
    var writes: [Data] = []
    var notes: [String] = []
    session.onClipboardWrite = { writes.append($0) }
    session.onOSCNotification = { notes.append($0) }

    _ = session.feedOutput(osc52Write + osc9Notify)

    XCTAssertEqual(writes, [Data("hello".utf8)])
    XCTAssertEqual(notes, ["build done"])
  }

  func testReplayedFeedDropsClipboardWriteAndNotification() throws {
    let session = try makeSession()
    defer { session.close() }
    var writes: [Data] = []
    var notes: [String] = []
    session.onClipboardWrite = { writes.append($0) }
    session.onOSCNotification = { notes.append($0) }

    session.withHostEffectsSuppressed {
      _ = session.feedOutput(osc52Write + osc9Notify)
    }
    XCTAssertEqual(writes, [], "a replayed OSC 52 write must not touch the clipboard")
    XCTAssertEqual(notes, [], "a replayed OSC 9 must not re-post a notification")

    // Live output after the replay is honored again.
    _ = session.feedOutput(osc52Write)
    XCTAssertEqual(writes, [Data("hello".utf8)])
  }

  func testReplayedFeedDropsClipboardReadQuery() throws {
    let session = try makeSession()
    defer { session.close() }
    var reads: [String] = []
    session.clipboardReadEnabled = true
    session.onClipboardReadRequest = { reads.append($0) }

    session.withHostEffectsSuppressed {
      _ = session.feedOutput(Array("\u{1b}]52;c;?\u{07}".utf8))
    }
    XCTAssertEqual(reads, [])
  }
}
