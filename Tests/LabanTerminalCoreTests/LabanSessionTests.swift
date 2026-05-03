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
}
