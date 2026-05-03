import LabanTerminalCore
import XCTest

final class LabanSessionTests: XCTestCase {

  private func makeFixtureSession(rows: Int32 = 24, cols: Int32 = 80) -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    let result = laban_session_create(&config, size, &session)
    guard result == 0 else { return nil }
    return session
  }

  func testFixtureCreatePollSnapshotDestroy() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }

    XCTAssertEqual(laban_session_poll(session), 0, "poll must return 0 in fixture mode")

    let bytes = Array("hello".utf8)
    let writeResult = bytes.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
    XCTAssertEqual(writeResult, 0, "fixture write must succeed")

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }

    guard let snap = snapshot else {
      XCTFail("snapshot is nil")
      return
    }
    XCTAssertGreaterThan(snap.pointee.cell_count, 0)
    let cells = snap.pointee.cells!
    let hCode = UInt32(UInt8(ascii: "h"))
    XCTAssertEqual(
      cells[0].codepoint, hCode,
      "cell (0,0) should hold 'h' after writing 'hello'")

    var newSize = LabanTerminalSize()
    newSize.rows = 12
    newSize.cols = 40
    XCTAssertEqual(laban_session_resize(session, newSize), 0)

    laban_session_destroy(session)
  }

  func testDirtyLifecycle() {
    guard let session = makeFixtureSession(rows: 5, cols: 10) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Initial dirty state: may be dirty or clean depending on Ghostty init.
    // We snapshot once to allow a baseline, then mark rendered.
    var dirty: Int32 = 0
    XCTAssertEqual(laban_session_render_dirty(session, &dirty), 0)
    _ = dirty  // capture initial state for reference

    // After marking rendered, dirty must be 0.
    XCTAssertEqual(laban_session_mark_rendered(session), 0)
    dirty = 99
    XCTAssertEqual(laban_session_render_dirty(session, &dirty), 0)
    XCTAssertEqual(dirty, 0, "after mark_rendered, dirty must be 0")

    // Write bytes; dirty query must report dirty.
    let bytes = Array("hello\r\n".utf8)
    bytes.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }

    dirty = 0
    XCTAssertEqual(laban_session_render_dirty(session, &dirty), 0)
    // After writing, some rows are dirty
    XCTAssertEqual(dirty, 1, "after writing bytes, dirty must be 1")

    // Snapshot + build commands as stand-in for rendering.
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
    XCTAssertNotNil(snap)
    laban_snapshot_destroy(snap)

    // Mark rendered.
    XCTAssertEqual(laban_session_mark_rendered(session), 0)

    // Dirty query must return false without additional writes.
    dirty = 99
    XCTAssertEqual(laban_session_render_dirty(session, &dirty), 0)
    XCTAssertEqual(dirty, 0, "after mark_rendered with no new writes, dirty must be 0")
  }

  func testFixtureResizeChangesSize() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var newSize = LabanTerminalSize()
    newSize.rows = 12
    newSize.cols = 40
    XCTAssertEqual(laban_session_resize(session, newSize), 0)

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }

    guard let snap = snapshot else {
      XCTFail("snapshot is nil")
      return
    }
    XCTAssertEqual(snap.pointee.rows, 12, "rows should be 12 after resize")
    XCTAssertEqual(snap.pointee.cols, 40, "cols should be 40 after resize")
    XCTAssertEqual(snap.pointee.cell_count, 12 * 40)
  }

  func testFixtureSnapshotDestroyIsSafe() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    laban_snapshot_destroy(snapshot)
    laban_session_destroy(session)
  }

  // MARK: - PTY mode tests

  private func withCArgv(_ strings: [String], body: (UnsafePointer<UnsafePointer<CChar>?>) -> Void)
  {
    var mptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    mptrs.append(nil)
    defer { for p in mptrs { if let p { free(p) } } }
    let count = mptrs.count
    mptrs.withUnsafeMutableBufferPointer { mbuf in
      mbuf.baseAddress!.withMemoryRebound(
        to: UnsafePointer<CChar>?.self, capacity: count
      ) { rebound in
        body(UnsafePointer(rebound))
      }
    }
  }

  func testRealShellSmokeOkOutput() {
    let exe = "/bin/sh"
    let argStrings = ["/bin/sh", "-lc", "printf 'ok\\n'"]

    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        var config = LabanLaunchConfig()
        config.executable = exeCStr
        config.argv = argvPtr
        config.fixture_mode = 0

        var size = LabanTerminalSize()
        size.rows = 24
        size.cols = 80

        var session: OpaquePointer?
        guard laban_session_create(&config, size, &session) == 0 else {
          XCTFail("laban_session_create failed for PTY mode")
          return
        }
        guard let session else {
          XCTFail("session is nil")
          return
        }
        defer { laban_session_destroy(session) }

        var snap: UnsafeMutablePointer<LabanSnapshot>?
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
          XCTAssertEqual(laban_session_poll(session), 0)
          guard laban_session_snapshot(session, &snap) == 0, let s = snap else { break }
          if s.pointee.status != 0 { break }
          laban_snapshot_destroy(snap)
          snap = nil
          Thread.sleep(forTimeInterval: 0.05)
        }
        defer { laban_snapshot_destroy(snap) }

        guard let s = snap else {
          XCTFail("no snapshot obtained after polling 2 seconds")
          return
        }
        XCTAssertEqual(s.pointee.status, 1, "shell should have exited normally")

        let cells = s.pointee.cells!
        let count = s.pointee.cell_count
        let oCP = UInt32(UInt8(ascii: "o"))
        let kCP = UInt32(UInt8(ascii: "k"))
        var foundOK = false
        if count >= 2 {
          for i in 0..<count - 1 where !foundOK {
            if cells[i].codepoint == oCP && cells[i + 1].codepoint == kCP {
              foundOK = true
            }
          }
        }
        XCTAssertTrue(foundOK, "expected 'ok' in cell grid after shell exits")
      }
    }
  }

  func testForcedSpawnFailureDoesNotLeak() {
    let exe = "/nonexistent/executable"
    exe.withCString { exeCStr in
      var config = LabanLaunchConfig()
      config.executable = exeCStr
      config.fixture_mode = 0

      var size = LabanTerminalSize()
      size.rows = 24
      size.cols = 80

      var session: OpaquePointer?
      XCTAssertEqual(
        laban_session_create(&config, size, &session), -1,
        "create with invalid exe must return -1")
      XCTAssertNil(session, "session must be nil when create fails")
    }
  }

  func testPTYResizeSetsSize() {
    let exe = "/bin/sh"
    let argStrings = ["/bin/sh"]

    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        var config = LabanLaunchConfig()
        config.executable = exeCStr
        config.argv = argvPtr
        config.fixture_mode = 0

        var size = LabanTerminalSize()
        size.rows = 24
        size.cols = 80

        var session: OpaquePointer?
        guard laban_session_create(&config, size, &session) == 0 else {
          XCTFail("laban_session_create failed for PTY resize test")
          return
        }
        guard let session else {
          XCTFail("session is nil")
          return
        }
        defer { laban_session_destroy(session) }

        var newSize = LabanTerminalSize()
        newSize.rows = 10
        newSize.cols = 30
        XCTAssertEqual(
          laban_session_resize(session, newSize), 0,
          "resize must return 0")

        var snap: UnsafeMutablePointer<LabanSnapshot>?
        XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
        defer { laban_snapshot_destroy(snap) }

        guard let s = snap else {
          XCTFail("snapshot is nil")
          return
        }
        XCTAssertEqual(s.pointee.rows, 10, "rows should be 10 after resize")
        XCTAssertEqual(s.pointee.cols, 30, "cols should be 30 after resize")
        XCTAssertEqual(s.pointee.cell_count, 10 * 30)
      }
    }
  }

  // MARK: - Scrollback tests

  func testScrollbackRevealsPriorLinesAfterNegativeDelta() {
    guard let session = makeFixtureSession(rows: 5, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Write enough lines to push content into scrollback (terminal has 5 visible rows).
    let prefix = "line-"
    var allBytes = [UInt8]()
    for i in 0..<10 {
      allBytes += Array("\(prefix)\(i)\r\n".utf8)
    }

    allBytes.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self), allBytes.count)
    }

    // Snapshot: scrollback should exist but line-0 should not be visible.
    var snap0: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap0), 0)
    defer { laban_snapshot_destroy(snap0) }
    guard let s0 = snap0 else {
      XCTFail("snapshot nil")
      return
    }

    let visible0 = visibleText(from: UnsafePointer(s0))
    // line-0 should NOT be visible yet (it's in scrollback)
    XCTAssertFalse(visible0.contains("line-0"), "line-0 should be scrolled off initially")

    // Scroll up by 4 rows (negative delta = older history).
    XCTAssertEqual(laban_session_scroll_viewport(session, -4), 0)

    // Snapshot again — viewport offset should have changed.
    var sbVs = LabanViewportState()
    XCTAssertEqual(laban_session_viewport_state(session, &sbVs), 0)
    XCTAssertGreaterThan(
      sbVs.viewport_offset, 0, "viewport offset should increase after scrolling up")

    // Use a separate variable to avoid double-free in defer.
    laban_snapshot_destroy(snap0)
    snap0 = nil
    var snap1: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap1), 0)
    defer { laban_snapshot_destroy(snap1) }
    guard let s1 = snap1 else {
      XCTFail("snapshot nil")
      return
    }
    let visible1 = visibleText(from: UnsafePointer(s1))
    XCTAssertNotEqual(visible0, visible1, "visible text should change after scroll")
  }

  func testViewportStateReportsScrollbackMetadata() {
    guard let session = makeFixtureSession(rows: 5, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Baseline viewport state — no scrollback yet.
    var vs = LabanViewportState()
    XCTAssertEqual(laban_session_viewport_state(session, &vs), 0)
    XCTAssertEqual(vs.scrollback_rows, 0, "no scrollback yet")
    XCTAssertEqual(vs.viewport_offset, 0, "viewport at active bottom")
    XCTAssertEqual(vs.mouse_tracking, 0, "mouse tracking off by default")

    // Write enough lines to create scrollback.
    var allBytes = [UInt8]()
    for i in 0..<10 {
      allBytes += Array("line \(i)\r\n".utf8)
    }
    allBytes.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self), allBytes.count)
    }

    // After enough output, scrollback rows should be > 0.
    vs = LabanViewportState()
    XCTAssertEqual(laban_session_viewport_state(session, &vs), 0)
    XCTAssertGreaterThan(
      vs.scrollback_rows, 0, "scrollback should exist after 10 lines in 5-row terminal")
    XCTAssertEqual(vs.total_rows, vs.viewport_rows + vs.scrollback_rows)
    XCTAssertEqual(vs.mouse_tracking, 0)

    // Scroll up and confirm offset changed (goes down in Ghostty's model).
    let offsetBefore = vs.viewport_offset
    XCTAssertGreaterThan(offsetBefore, 0, "should have scroll offset before scrolling")
    XCTAssertEqual(laban_session_scroll_viewport(session, -2), 0)
    vs = LabanViewportState()
    XCTAssertEqual(laban_session_viewport_state(session, &vs), 0)
    XCTAssertNotEqual(
      vs.viewport_offset, offsetBefore, "viewport offset should change after scrolling up")
  }

  // MARK: - Mouse encoding tests

  func testMouseEncodingWithSGREnabled() {
    guard let session = makeFixtureSession(rows: 5, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Enable normal SGR mouse tracking (DECSET 1000 + DECSET 1006).
    let enableSeq = Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)
    enableSeq.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        enableSeq.count)
    }

    // Verify mouse tracking is now active.
    var vs = LabanViewportState()
    XCTAssertEqual(laban_session_viewport_state(session, &vs), 0)
    XCTAssertEqual(vs.mouse_tracking, 1, "SGR mouse tracking should be enabled")

    // Build a left-button press event inside the terminal.
    var event = LabanMouseEvent()
    event.action = LABAN_MOUSE_ACTION_PRESS
    event.button = LABAN_MOUSE_BUTTON_LEFT
    event.x = 300
    event.y = 200
    event.screen_width = 400
    event.screen_height = 200
    event.cell_width = 8
    event.cell_height = 16

    var buf = [UInt8](repeating: 0, count: 64)
    var outLen: size_t = 0

    let result = laban_session_encode_mouse(session, &event, &buf, buf.count, &outLen)
    XCTAssertEqual(result, 0, "encode should succeed")
    XCTAssertGreaterThan(outLen, 0, "should produce non-empty mouse event bytes")

    // SGR mouse format produces sequences starting with ESC[< (0x1b 0x5b 0x3c).
    let sgrPrefix: [UInt8] = [0x1b, 0x5b, 0x3c]
    let actualPrefix = Array(buf.prefix(3))
    XCTAssertEqual(
      actualPrefix, sgrPrefix,
      "SGR mouse encoding should start with ESC[<; got \(actualPrefix)")

    // Decode the sequence to verify it contains expected button/position info.
    if let seq = String(bytes: buf.prefix(Int(outLen)), encoding: .utf8) {
      XCTAssertTrue(seq.hasPrefix("\u{1b}[<"), "sequence should start with ESC[<; got \(seq)")
      // Should end with 'M' for press events in SGR mode.
      XCTAssertTrue(
        seq.hasSuffix("M") || seq.hasSuffix("m"),
        "sequence should end with M (press) or m (release); got \(seq)")
    }
  }

  func testMouseEncodingUsesSurfacePixelPositions() {
    guard let session = makeFixtureSession(rows: 5, cols: 30) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let enableSeq = Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)
    enableSeq.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        enableSeq.count)
    }

    var event = LabanMouseEvent()
    event.action = LABAN_MOUSE_ACTION_PRESS
    event.button = LABAN_MOUSE_BUTTON_LEFT
    event.x = 160
    event.y = 32
    event.screen_width = 240
    event.screen_height = 80
    event.cell_width = 8
    event.cell_height = 16

    var buf = [UInt8](repeating: 0, count: 64)
    var outLen: size_t = 0
    XCTAssertEqual(laban_session_encode_mouse(session, &event, &buf, buf.count, &outLen), 0)

    let seq = String(bytes: buf.prefix(Int(outLen)), encoding: .utf8)
    XCTAssertEqual(seq, "\u{1b}[<0;21;3M")
  }

  func testMouseEncodingUsesGhosttyModifierBitOrder() {
    guard let session = makeFixtureSession(rows: 5, cols: 30) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let enableSeq = Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)
    enableSeq.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        enableSeq.count)
    }

    var event = LabanMouseEvent()
    event.action = LABAN_MOUSE_ACTION_PRESS
    event.button = LABAN_MOUSE_BUTTON_LEFT
    event.x = 0
    event.y = 0
    event.screen_width = 240
    event.screen_height = 80
    event.cell_width = 8
    event.cell_height = 16
    event.modifiers = 4

    var altBuf = [UInt8](repeating: 0, count: 64)
    var altLen: size_t = 0
    XCTAssertEqual(laban_session_encode_mouse(session, &event, &altBuf, altBuf.count, &altLen), 0)
    XCTAssertEqual(String(bytes: altBuf.prefix(Int(altLen)), encoding: .utf8), "\u{1b}[<8;1;1M")

    event.modifiers = 2
    var ctrlBuf = [UInt8](repeating: 0, count: 64)
    var ctrlLen: size_t = 0
    XCTAssertEqual(
      laban_session_encode_mouse(session, &event, &ctrlBuf, ctrlBuf.count, &ctrlLen), 0)
    XCTAssertEqual(
      String(bytes: ctrlBuf.prefix(Int(ctrlLen)), encoding: .utf8),
      "\u{1b}[<16;1;1M")
  }

  func testButtonModeDragMotionPreservesPressedButton() {
    guard let session = makeFixtureSession(rows: 5, cols: 30) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let enableSeq = Array("\u{1b}[?1002h\u{1b}[?1006h".utf8)
    enableSeq.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        enableSeq.count)
    }

    var press = LabanMouseEvent()
    press.action = LABAN_MOUSE_ACTION_PRESS
    press.button = LABAN_MOUSE_BUTTON_LEFT
    press.x = 8
    press.y = 16
    press.screen_width = 240
    press.screen_height = 80
    press.cell_width = 8
    press.cell_height = 16

    var pressBuf = [UInt8](repeating: 0, count: 64)
    var pressLen: size_t = 0
    XCTAssertEqual(
      laban_session_encode_mouse(session, &press, &pressBuf, pressBuf.count, &pressLen), 0)
    XCTAssertGreaterThan(pressLen, 0)

    var motion = press
    motion.action = LABAN_MOUSE_ACTION_MOTION
    motion.button = LABAN_MOUSE_BUTTON_NONE
    motion.x = 16
    motion.y = 32

    var motionBuf = [UInt8](repeating: 0, count: 64)
    var motionLen: size_t = 0
    XCTAssertEqual(
      laban_session_encode_mouse(session, &motion, &motionBuf, motionBuf.count, &motionLen), 0)

    let seq = String(bytes: motionBuf.prefix(Int(motionLen)), encoding: .utf8)
    XCTAssertEqual(seq, "\u{1b}[<32;3;3M")
  }

  func testMouseEncodingWheelUpAndDownAreDistinct() {
    guard let session = makeFixtureSession(rows: 5, cols: 30) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Enable SGR mouse.
    let enableSeq = Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)
    enableSeq.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        enableSeq.count)
    }

    var upEvent = LabanMouseEvent()
    upEvent.action = LABAN_MOUSE_ACTION_PRESS
    upEvent.button = LABAN_MOUSE_BUTTON_WHEEL_UP
    upEvent.x = 150
    upEvent.y = 75
    upEvent.screen_width = 400
    upEvent.screen_height = 200
    upEvent.cell_width = 8
    upEvent.cell_height = 16

    var downEvent = upEvent
    downEvent.button = LABAN_MOUSE_BUTTON_WHEEL_DOWN

    var upBuf = [UInt8](repeating: 0, count: 64)
    var upLen: size_t = 0
    XCTAssertEqual(laban_session_encode_mouse(session, &upEvent, &upBuf, upBuf.count, &upLen), 0)
    XCTAssertGreaterThan(upLen, 0)

    var downBuf = [UInt8](repeating: 0, count: 64)
    var downLen: size_t = 0
    XCTAssertEqual(
      laban_session_encode_mouse(session, &downEvent, &downBuf, downBuf.count, &downLen), 0)
    XCTAssertGreaterThan(downLen, 0)

    // Wheel up and wheel down should produce different byte sequences.
    XCTAssertEqual(
      upLen, downLen, "wheel up and down should produce same length (both are SGR events)")
    let upSlice = upBuf[0..<Int(upLen)]
    let downSlice = downBuf[0..<Int(downLen)]
    XCTAssertNotEqual(
      [UInt8](upSlice), [UInt8](downSlice),
      "wheel up and down should produce different encodings")
  }

  func testMouseEncodingWithoutTrackingReturnsNoBytes() {
    guard let session = makeFixtureSession(rows: 5, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // No mouse tracking enabled (default) — encoding should produce zero bytes.
    var event = LabanMouseEvent()
    event.action = LABAN_MOUSE_ACTION_PRESS
    event.button = LABAN_MOUSE_BUTTON_LEFT
    event.x = 100
    event.y = 100
    event.screen_width = 400
    event.screen_height = 200
    event.cell_width = 8
    event.cell_height = 16

    var buf = [UInt8](repeating: 0, count: 64)
    var outLen: size_t = 0

    let result = laban_session_encode_mouse(session, &event, &buf, buf.count, &outLen)
    XCTAssertEqual(result, 0, "encode should succeed even without tracking")
    XCTAssertEqual(outLen, 0, "should produce zero bytes when mouse tracking is disabled")
  }

  func testSendMouseNoOpInFixtureMode() {
    guard let session = makeFixtureSession(rows: 5, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanMouseEvent()
    event.action = LABAN_MOUSE_ACTION_PRESS
    event.button = LABAN_MOUSE_BUTTON_LEFT
    event.x = 100
    event.y = 100
    event.screen_width = 400
    event.screen_height = 200
    event.cell_width = 8
    event.cell_height = 16

    // send_mouse should return 0 (no-op) in fixture mode.
    XCTAssertEqual(laban_session_send_mouse(session, &event), 0)
  }
}

private func visibleText(from snap: UnsafePointer<LabanSnapshot>) -> String {
  let snapshot = snap.pointee
  let rows = Int(snapshot.rows)
  let cols = Int(snapshot.cols)
  guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else { return "" }
  var lines: [String] = []
  for row in 0..<rows {
    var line = ""
    for col in 0..<cols {
      let cell = cells[row * cols + col]
      guard cell.utf8_length > 0 else { continue }
      let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
      let buf = UnsafeBufferPointer<UInt8>(
        start: ptr.assumingMemoryBound(to: UInt8.self),
        count: Int(cell.utf8_length)
      )
      if let text = String(bytes: buf, encoding: .utf8) { line += text }
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { lines.append(trimmed) }
  }
  return lines.joined(separator: "\n")
}
