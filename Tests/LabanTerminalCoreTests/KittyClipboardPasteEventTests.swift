import Foundation
import LabanTerminalCore
import XCTest

/// ADR 0040: Kitty clipboard protocol (OSC 5522) paste events. A program that
/// enabled DEC mode 5522 gets a paste event on ⌘V instead of text, then reads
/// the representations it wants with the event's one-time password. Laban
/// serves that read from the snapshot taken at the paste and denies every
/// unsolicited read.
final class KittyClipboardPasteEventTests: XCTestCase {
  private func makeSession() throws -> OpaquePointer {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0, let session else {
      throw XCTSkip("laban_session_create failed")
    }
    return session
  }

  private func write(_ session: OpaquePointer, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  private func drain(_ session: OpaquePointer) -> String {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      var len = 0
      guard laban_session_drain_response(session, &buf, buf.count, &len) == 0, len > 0 else {
        break
      }
      out.append(contentsOf: buf[0..<len])
      if len < buf.count { break }
    }
    return String(decoding: out, as: UTF8.self)
  }

  private func pasteEventsEnabled(_ session: OpaquePointer) -> Bool {
    var enabled: Int32 = 0
    XCTAssertEqual(laban_session_paste_events_enabled(session, &enabled), 0)
    return enabled != 0
  }

  private func encodePasteEvent(
    _ session: OpaquePointer, _ items: [(mime: String, data: [UInt8])]
  ) -> (rc: Int32, bytes: String) {
    var mimes = items.map { Array($0.mime.utf8) }
    var datas = items.map(\.data)
    var out = [UInt8](repeating: 0, count: 4096)
    var outLen = 0
    var cItems: [LabanPasteItem] = []
    for i in items.indices {
      mimes[i].withUnsafeBufferPointer { m in
        datas[i].withUnsafeBufferPointer { d in
          cItems.append(
            LabanPasteItem(
              mime: UnsafeRawPointer(m.baseAddress!).assumingMemoryBound(to: CChar.self),
              mime_len: m.count, data: d.baseAddress, data_len: d.count))
        }
      }
    }
    // The pointers above are only used while `mimes`/`datas` stay alive and
    // unmutated, which holds for the duration of this call.
    let rc = withExtendedLifetime((mimes, datas)) {
      laban_session_encode_paste_event(session, cItems, cItems.count, &out, out.count, &outLen)
    }
    return (rc, String(decoding: out.prefix(outLen), as: UTF8.self))
  }

  /// The `pw=<value>` (base64 one-time password) metadata of a paste-event packet.
  private func password(in event: String) -> String? {
    guard let range = event.range(of: "pw=") else { return nil }
    let tail = event[range.upperBound...]
    let end = tail.firstIndex(where: { $0 == ":" || $0 == ";" || $0 == "\u{1b}" || $0 == "\u{07}" })
    return String(tail[..<(end ?? tail.endIndex)])
  }

  private func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

  func testPasteEventsAreOffUntilTheProgramEnablesMode5522() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }
    XCTAssertFalse(pasteEventsEnabled(session))
    let result = encodePasteEvent(session, [("text/plain", Array("hi".utf8))])
    XCTAssertEqual(result.rc, 0)
    XCTAssertEqual(result.bytes, "", "no event while mode 5522 is off")

    write(session, "\u{1b}[?5522h")
    XCTAssertTrue(pasteEventsEnabled(session))
  }

  func testPasteEventThenGrantedReadServesTheSnapshot() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}[?5522h")

    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]
    let event = encodePasteEvent(
      session, [("image/png", png), ("text/plain", Array("caption".utf8))])
    XCTAssertEqual(event.rc, 0)
    XCTAssertTrue(event.bytes.hasPrefix("\u{1b}]5522;"), event.bytes.debugDescription)
    XCTAssertEqual(drain(session), "", "the event is returned to the caller, not written")
    let pw = try XCTUnwrap(password(in: event.bytes), event.bytes.debugDescription)

    // The program reads the image with the event's one-time password.
    write(
      session,
      "\u{1b}]5522;type=read:name=\(base64("test")):pw=\(pw);\(base64("image/png"))\u{1b}\\")
    let reply = drain(session)
    XCTAssertTrue(
      reply.contains(Data(png).base64EncodedString()),
      "granted read must carry the PNG: \(reply.debugDescription)")
    XCTAssertFalse(reply.contains(base64("caption")), "only the requested MIME is served")
  }

  func testUnsolicitedReadIsDenied() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }
    write(session, "\u{1b}[?5522h")
    _ = encodePasteEvent(session, [("text/plain", Array("secret".utf8))])

    // No password: a program reading the clipboard on its own is refused.
    write(session, "\u{1b}]5522;type=read;\(base64("text/plain"))\u{1b}\\")
    let reply = drain(session)
    XCTAssertFalse(reply.contains(base64("secret")), reply.debugDescription)
    XCTAssertTrue(reply.contains("EPERM"), reply.debugDescription)
  }

  func testOSC52ReadStillGetsNoReplyWhileDisabled() throws {
    let session = try makeSession()
    defer { laban_session_destroy(session) }
    // libghostty now routes OSC 52 `?` to the installed clipboard_read effect
    // too; its empty fallback reply must be dropped so ADR 0014 holds.
    write(session, "\u{1b}]52;c;?\u{07}")
    write(session, "\u{1b}]52;c;?\u{1b}\\")
    XCTAssertEqual(drain(session), "")
  }
}
