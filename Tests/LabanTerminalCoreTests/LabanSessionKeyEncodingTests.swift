import LabanTerminalCore
import XCTest

final class LabanSessionKeyEncodingTests: XCTestCase {

  private func makeFixtureSession(rows: Int32 = 24, cols: Int32 = 80) -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0 else { return nil }
    return session
  }

  private func feedVT(_ session: OpaquePointer, _ sequence: String) {
    let bytes = Array(sequence.utf8)
    _ = bytes.withUnsafeBytes { buf in
      laban_session_feed_output(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
  }

  private func encodeKey(_ session: OpaquePointer, _ event: inout LabanKeyEvent) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: 128)
    var len = 0
    let rc = buf.withUnsafeMutableBytes { outBuf in
      laban_session_encode_key(
        session, &event,
        outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        outBuf.count, &len)
    }
    guard rc == 0 else { return nil }
    return Array(buf.prefix(len))
  }

  func testNormalUpArrowEncodesCSI_A() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_ARROW_UP

    XCTAssertEqual(encodeKey(session, &event), [0x1B, 0x5B, 0x41])  // ESC [ A
  }

  func testApplicationCursorUpArrowEncodesSSThreeA() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    feedVT(session, "\u{1B}[?1h")  // DECCKM: application cursor mode

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_ARROW_UP

    XCTAssertEqual(encodeKey(session, &event), [0x1B, 0x4F, 0x41])  // ESC O A
  }

  func testCtrlCEncodesETX() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_C
    event.modifiers = 2  // LABAN_KEY_MOD_CONTROL

    XCTAssertEqual(encodeKey(session, &event), [0x03])  // ETX (^C)
  }

  func testCtrlZEncodesSUB() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_Z
    event.modifiers = 2  // LABAN_KEY_MOD_CONTROL

    XCTAssertEqual(encodeKey(session, &event), [0x1A])  // SUB (^Z)
  }

  func testCtrlVEncodesSYN() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_V
    event.modifiers = 2  // LABAN_KEY_MOD_CONTROL

    XCTAssertEqual(encodeKey(session, &event), [0x16])  // SYN (^V)
  }

  func testShiftTabEncodesBacktab() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_TAB
    event.modifiers = 1  // LABAN_KEY_MOD_SHIFT

    XCTAssertEqual(encodeKey(session, &event), [0x1B, 0x5B, 0x5A])  // ESC [ Z
  }

  func testModifyOtherKeysCtrlShiftH() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    feedVT(session, "\u{1B}[>4;2m")  // modifyOtherKeys mode 2

    let text = Array("H".utf8)
    var outBuf = [UInt8](repeating: 0, count: 128)
    var outLen = 0
    let rc = text.withUnsafeBytes { textPtr in
      outBuf.withUnsafeMutableBytes { outPtr in
        var ev = LabanKeyEvent()
        ev.action = LABAN_KEY_ACTION_PRESS
        ev.key = LABAN_KEY_H
        ev.modifiers = 3  // LABAN_KEY_MOD_CONTROL | LABAN_KEY_MOD_SHIFT
        ev.unshifted_codepoint = UInt32(UInt8(ascii: "h"))
        ev.utf8 = textPtr.baseAddress?.assumingMemoryBound(to: Int8.self)
        ev.utf8_len = text.count
        return laban_session_encode_key(
          session, &ev,
          outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
          outPtr.count, &outLen)
      }
    }
    XCTAssertEqual(rc, 0)
    // ESC [ 2 7 ; 6 ; 7 2 ~  (modifier 6 = shift+ctrl+1, codepoint 72 = 'H')
    XCTAssertEqual(
      Array(outBuf.prefix(outLen)),
      [0x1B, 0x5B, 0x32, 0x37, 0x3B, 0x36, 0x3B, 0x37, 0x32, 0x7E])
  }

  func testKittyShiftBackspace() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    feedVT(session, "\u{1B}[>1u")  // Kitty keyboard: push disambiguate flag

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_BACKSPACE
    event.modifiers = 1  // LABAN_KEY_MOD_SHIFT

    // ESC [ 1 2 7 ; 2 u  (127=DEL/Backspace, modifier 2=shift+1)
    XCTAssertEqual(
      encodeKey(session, &event),
      [0x1B, 0x5B, 0x31, 0x32, 0x37, 0x3B, 0x32, 0x75])
  }

  func testKittyShiftEnter() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    feedVT(session, "\u{1B}[>1u")  // Kitty keyboard: push disambiguate flag

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_ENTER
    event.modifiers = 1  // LABAN_KEY_MOD_SHIFT

    // ESC [ 1 3 ; 2 u  (13=Enter/CR, modifier 2=shift+1). Claude Code pushes the
    // kitty disambiguate flag and relies on Shift+Enter inserting a newline; if
    // this regressed to a bare CR (0x0D) it would submit the prompt instead.
    XCTAssertEqual(
      encodeKey(session, &event),
      [0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75])
  }

  func testBackarrowModeChangesBackspaceEncoding() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_BACKSPACE

    XCTAssertEqual(encodeKey(session, &event), [0x7F])

    feedVT(session, "\u{1B}[?67h")  // DECBKM: backarrow key mode on
    XCTAssertEqual(encodeKey(session, &event), [0x08])

    feedVT(session, "\u{1B}[?67l")  // DECBKM off
    XCTAssertEqual(encodeKey(session, &event), [0x7F])
  }

  func testOptionProducedTextWithConsumedOptionPassesThroughAsText() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    // Option-4 on US keyboard produces "$"; ALT consumed by native text input
    let text = Array("$".utf8)
    var outBuf = [UInt8](repeating: 0, count: 128)
    var outLen = 0
    let rc = text.withUnsafeBytes { textPtr in
      outBuf.withUnsafeMutableBytes { outPtr in
        var ev = LabanKeyEvent()
        ev.action = LABAN_KEY_ACTION_PRESS
        ev.key = LABAN_KEY_DIGIT_4
        ev.modifiers = 4  // LABAN_KEY_MOD_ALT (option key held)
        ev.consumed_modifiers = 4  // ALT consumed by native text; not terminal Alt
        ev.unshifted_codepoint = UInt32(UInt8(ascii: "4"))
        ev.utf8 = textPtr.baseAddress?.assumingMemoryBound(to: Int8.self)
        ev.utf8_len = text.count
        return laban_session_encode_key(
          session, &ev,
          outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
          outPtr.count, &outLen)
      }
    }
    XCTAssertEqual(rc, 0)
    // Bare "$" (0x24), not ESC-prefixed — option-as-alt is FALSE and ALT is consumed
    XCTAssertEqual(Array(outBuf.prefix(outLen)), [0x24])
  }

  func testOptionAsMetaSettingEncodesAltChord() {
    guard let session = makeFixtureSession() else {
      XCTFail("session creation failed")
      return
    }
    defer { laban_session_destroy(session) }

    var outBuf = [UInt8](repeating: 0, count: 128)
    var outLen = 0
    let rc = outBuf.withUnsafeMutableBytes { outPtr in
      var ev = LabanKeyEvent()
      ev.action = LABAN_KEY_ACTION_PRESS
      ev.key = LABAN_KEY_DIGIT_4
      ev.modifiers = 4  // LABAN_KEY_MOD_ALT
      ev.option_as_alt = 1
      ev.unshifted_codepoint = UInt32(UInt8(ascii: "4"))
      return laban_session_encode_key(
        session, &ev,
        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
        outPtr.count, &outLen)
    }
    XCTAssertEqual(rc, 0)
    // With option-as-meta enabled, Option-4 should encode as Alt-composed bytes (not raw '$').
    XCTAssertEqual(Array(outBuf.prefix(outLen)), [0x1B, 0x34])
  }
}
