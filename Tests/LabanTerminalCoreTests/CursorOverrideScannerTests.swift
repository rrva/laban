import LabanTerminalCore
import XCTest

/// Tests for the DECSCUSR / DEC-mode-12 cursor-override byte scanner.
///
/// The scanner runs inside `laban_vt_write_capture` and sets
/// `cursor_style_explicit` / `cursor_blink_explicit` on the session.
/// Tests feed raw bytes into a fixture session and snapshot the resulting
/// flag values.
final class CursorOverrideScannerTests: XCTestCase {

  // MARK: - Helpers

  private func makeSession() -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 20
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0 else { return nil }
    return session
  }

  private func write(_ session: OpaquePointer, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
  }

  private func writeString(_ session: OpaquePointer, _ s: String) {
    write(session, Array(s.utf8))
  }

  private func snapshot(_ session: OpaquePointer) -> UnsafeMutablePointer<LabanSnapshot>? {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    guard laban_session_snapshot(session, &snap) == 0 else { return nil }
    return snap
  }

  // MARK: - DECSCUSR set (Ps 1-6 sets both flags)

  func testDECSCSUR_SetStyleAndBlink_Ps1() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[1 q")  // blinking block
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 1, "Ps=1 must set style_explicit")
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 1, "Ps=1 must set blink_explicit")
  }

  func testDECSCSUR_SetStyleAndBlink_Ps5() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[5 q")  // blinking bar
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 1, "Ps=5 must set style_explicit")
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 1, "Ps=5 must set blink_explicit")
  }

  func testDECSCSUR_SetStyleAndBlink_Ps2() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[2 q")  // steady block
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 1)
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 1)
  }

  // MARK: - DECSCUSR 0 clears both flags

  func testDECSCSUR_Clear_Ps0() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    // First set, then clear
    writeString(session, "\u{1B}[5 q")  // set
    writeString(session, "\u{1B}[0 q")  // clear with Ps=0
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 0, "Ps=0 must clear style_explicit")
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 0, "Ps=0 must clear blink_explicit")
  }

  func testDECSCSUR_Clear_NoParam() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[2 q")  // set
    writeString(session, "\u{1B}[ q")  // CSI SP q with no param
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 0, "absent param must clear style_explicit")
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 0, "absent param must clear blink_explicit")
  }

  // MARK: - RIS clears both flags

  func testRIS_ClearsBothFlags() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[3 q")  // set
    writeString(session, "\u{1B}c")  // RIS
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 0, "RIS must clear style_explicit")
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 0, "RIS must clear blink_explicit")
  }

  // MARK: - DECSTR clears both flags

  func testDECSTR_ClearsBothFlags() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[4 q")  // set
    writeString(session, "\u{1B}[!p")  // DECSTR: CSI ! p
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 0, "DECSTR must clear style_explicit")
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 0, "DECSTR must clear blink_explicit")
  }

  // MARK: - Sequence split across two writes

  func testDECSCSUR_SplitAcrossTwoWrites_SetFlags() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    // Split "\u{1B}[5 q" across two writes: first ESC+[+5, then " q"
    write(session, [0x1B, 0x5B, 0x35])  // ESC [ 5
    write(session, [0x20, 0x71])  // SP q

    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(
      snap.pointee.cursor_style_explicit, 1,
      "DECSCUSR split across writes must still set style_explicit")
    XCTAssertEqual(
      snap.pointee.cursor_blink_explicit, 1,
      "DECSCUSR split across writes must still set blink_explicit")
  }

  func testDECSCSUR_SplitAcrossTwoWrites_ClearAfterSet() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[6 q")  // set: steady bar
    // Split DECSCUSR 0 reset across bytes
    write(session, [0x1B])  // ESC alone
    write(session, [0x5B, 0x30, 0x20, 0x71])  // [ 0 SP q

    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(
      snap.pointee.cursor_style_explicit, 0,
      "DECSCUSR 0 split across writes must still clear style_explicit")
    XCTAssertEqual(
      snap.pointee.cursor_blink_explicit, 0,
      "DECSCUSR 0 split across writes must still clear blink_explicit")
  }

  // MARK: - DEC mode 12 (blink only)

  func testDecMode12_HEnablesBlinkOnly() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[?12h")  // CSI ? 12 h: enable blink
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(
      snap.pointee.cursor_blink_explicit, 1,
      "CSI ? 12 h must set blink_explicit")
    XCTAssertEqual(
      snap.pointee.cursor_style_explicit, 0,
      "CSI ? 12 h must NOT set style_explicit")
  }

  func testDecMode12_LDisablesBlink() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "\u{1B}[?12h")  // enable
    writeString(session, "\u{1B}[?12l")  // disable
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(
      snap.pointee.cursor_blink_explicit, 0,
      "CSI ? 12 l must clear blink_explicit")
  }

  // MARK: - No false positives on plain text

  func testPlainText_NoFlagsSet() {
    guard let session = makeSession() else {
      XCTFail("session create")
      return
    }
    defer { laban_session_destroy(session) }

    writeString(session, "hello world\r\n")
    guard let snap = snapshot(session) else {
      XCTFail("snapshot nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(snap.pointee.cursor_style_explicit, 0)
    XCTAssertEqual(snap.pointee.cursor_blink_explicit, 0)
  }
}
