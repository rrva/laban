import Darwin
import LabanTerminalCore
import XCTest

private func canonicalPath(_ path: String) -> String {
  path.withCString { cPath in
    guard let resolved = realpath(cPath, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

private func waitForForegroundProcess(
  _ session: OpaquePointer,
  named expected: String,
  timeout: TimeInterval = 2.0
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    _ = laban_session_poll(session)
    var childPid: Int32 = -1
    var foregroundPid: Int32 = -1
    var process = [CChar](repeating: 0, count: 256)
    var command = [CChar](repeating: 0, count: 1024)
    var cwd = [CChar](repeating: 0, count: 1024)
    let metadataRC = process.withUnsafeMutableBufferPointer { processPtr in
      command.withUnsafeMutableBufferPointer { commandPtr in
        cwd.withUnsafeMutableBufferPointer { cwdPtr in
          laban_session_process_metadata(
            session,
            &childPid,
            &foregroundPid,
            processPtr.baseAddress,
            processPtr.count,
            commandPtr.baseAddress,
            commandPtr.count,
            cwdPtr.baseAddress,
            cwdPtr.count
          )
        }
      }
    }
    if metadataRC == 0, foregroundPid > 0, String(cString: process).contains(expected) {
      return true
    }
    Thread.sleep(forTimeInterval: 0.02)
  }
  return false
}

private func shellSingleQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func processExists(_ pid: pid_t) -> Bool {
  if kill(pid, 0) == 0 { return true }
  return errno == EPERM
}

private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval = 2.0) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if !processExists(pid) { return true }
    Thread.sleep(forTimeInterval: 0.02)
  }
  return !processExists(pid)
}

private final class TabStatusProbe {
  var calls = 0
  var status: String?
}

private let tabStatusProbeCallback: LabanTabStatusCallback = { userdata, _, status, _ in
  guard let userdata else { return }
  let probe = Unmanaged<TabStatusProbe>.fromOpaque(userdata).takeUnretainedValue()
  probe.calls += 1
  probe.status = status.map { String(cString: $0) }
}

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

  func testExitStateNullSessionReturnsZeroState() {
    let exit = laban_session_exit_state(nil)
    XCTAssertEqual(exit.status, 0)
    XCTAssertEqual(exit.exit_status, 0)
  }

  func testSnapshotRejectsNullSessionAndClearsOutPointer() {
    var snapshot = UnsafeMutablePointer<LabanSnapshot>(bitPattern: 0x1)
    XCTAssertEqual(laban_session_snapshot(nil, &snapshot), -1)
    XCTAssertNil(snapshot)
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
      _ = laban_session_write(
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

  func testSnapshotAllowsZeroSizedGrid() {
    guard let session = makeFixtureSession(rows: 2, cols: 2) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var zeroSize = LabanTerminalSize()
    zeroSize.rows = 0
    zeroSize.cols = 0
    XCTAssertEqual(laban_session_resize(session, zeroSize), 0)

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }

    guard let snap = snapshot else {
      XCTFail("snapshot is nil")
      return
    }
    XCTAssertEqual(snap.pointee.rows, 0)
    XCTAssertEqual(snap.pointee.cols, 0)
    XCTAssertEqual(snap.pointee.cell_count, 0)
    XCTAssertEqual(snap.pointee.utf8_storage_len, 0)
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

  func testSnapshotTitleCopyIsBoundedAndOwned() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let longTitle = String(repeating: "a", count: 600)
    let osc = "\u{1B}]0;\(longTitle)\u{07}"
    let bytes = Array(osc.utf8)
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }

    guard let title = snapshot?.pointee.title else {
      XCTFail("snapshot title is nil")
      return
    }
    XCTAssertLessThanOrEqual(strlen(title), 1024)
    XCTAssertEqual(String(cString: title), String(repeating: "a", count: Int(strlen(title))))
  }

  func testSnapshotAndConsumeTitleDoNotSplitUTF8AtCapacity() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let prefix = String(repeating: "a", count: 1023)
    let title = prefix + "\u{20AC}"
    let osc = "\u{1B}]0;\(title)\u{07}"
    let bytes = Array(osc.utf8)
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }

    guard let titlePtr = snapshot?.pointee.title else {
      XCTFail("snapshot title is nil")
      return
    }
    XCTAssertEqual(strlen(titlePtr), 1023)
    XCTAssertEqual(String(cString: titlePtr), prefix)

    var consumed = [CChar](repeating: 0, count: 1025)
    let dirty = consumed.withUnsafeMutableBufferPointer { buf in
      laban_session_consume_title(session, buf.baseAddress, buf.count)
    }
    XCTAssertEqual(dirty, 1)
    consumed.withUnsafeBufferPointer { buf in
      guard let baseAddress = buf.baseAddress else {
        XCTFail("consume title buffer is nil")
        return
      }
      XCTAssertEqual(strlen(baseAddress), 1023)
      XCTAssertEqual(String(cString: baseAddress), prefix)
    }
  }

  func testSnapshotPreservesLongSingleCellGraphemeCluster() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let cluster = "a" + String(repeating: "\u{0301}", count: 20)
    let bytes = Array(cluster.utf8)
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }

    guard let snap = snapshot?.pointee,
      let cells = snap.cells,
      let storage = snap.utf8_storage
    else {
      XCTFail("snapshot storage is nil")
      return
    }

    let first = cells[0]
    XCTAssertEqual(Int(first.utf8_length), bytes.count)
    let ptr = UnsafeRawPointer(storage).advanced(by: Int(first.utf8_offset))
    let buf = UnsafeBufferPointer<UInt8>(
      start: ptr.assumingMemoryBound(to: UInt8.self),
      count: Int(first.utf8_length)
    )
    XCTAssertEqual(String(bytes: buf, encoding: .utf8), cluster)
  }

  func testOversizedTabStatusPayloadIsDroppedAndScannerRecovers() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let probe = TabStatusProbe()
    let userdata = Unmanaged.passUnretained(probe).toOpaque()
    XCTAssertEqual(
      laban_session_set_tab_status_callback(session, tabStatusProbeCallback, userdata), 0)

    let oversized = "\u{1B}]21337;status=\(String(repeating: "x", count: 1_100))\u{07}"
    writeBytes(session, Array(oversized.utf8))
    XCTAssertEqual(probe.calls, 0, "oversized OSC 21337 payload must not fire truncated")

    let valid = "\u{1B}]21337;status=ok\u{07}"
    writeBytes(session, Array(valid.utf8))
    XCTAssertEqual(probe.calls, 1)
    XCTAssertEqual(probe.status, "ok")
  }

  func testProcessMetadataReportsForegroundProcessAndCwd() {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-process-metadata-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    } catch {
      XCTFail("failed to create temp directory: \(error)")
      return
    }
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let tempPath = canonicalPath(tempURL.path)

    let exe = "/bin/sleep"
    let argStrings = ["/bin/sleep", "2"]
    exe.withCString { exeCStr in
      tempPath.withCString { cwdCStr in
        withCArgv(argStrings) { argvPtr in
          var config = LabanLaunchConfig()
          config.executable = exeCStr
          config.argv = argvPtr
          config.cwd = cwdCStr
          config.fixture_mode = 0

          var size = LabanTerminalSize()
          size.rows = 24
          size.cols = 80

          var session: OpaquePointer?
          guard laban_session_create(&config, size, &session) == 0, let session else {
            XCTFail("laban_session_create failed for process metadata test")
            return
          }
          defer { laban_session_destroy(session) }

          var childPid: Int32 = -1
          var foregroundPid: Int32 = -1
          var process = [CChar](repeating: 0, count: 256)
          var command = [CChar](repeating: 0, count: 1024)
          var cwd = [CChar](repeating: 0, count: 1024)

          let deadline = Date().addingTimeInterval(2.0)
          var rc: Int32 = -1
          while Date() < deadline {
            _ = laban_session_poll(session)
            process = [CChar](repeating: 0, count: 256)
            command = [CChar](repeating: 0, count: 1024)
            cwd = [CChar](repeating: 0, count: 1024)
            rc = process.withUnsafeMutableBufferPointer { processPtr in
              command.withUnsafeMutableBufferPointer { commandPtr in
                cwd.withUnsafeMutableBufferPointer { cwdPtr in
                  laban_session_process_metadata(
                    session,
                    &childPid,
                    &foregroundPid,
                    processPtr.baseAddress,
                    processPtr.count,
                    commandPtr.baseAddress,
                    commandPtr.count,
                    cwdPtr.baseAddress,
                    cwdPtr.count
                  )
                }
              }
            }
            if String(cString: process) == "sleep" {
              break
            }
            Thread.sleep(forTimeInterval: 0.01)
          }

          XCTAssertEqual(rc, 0)
          XCTAssertGreaterThan(childPid, 0)
          XCTAssertGreaterThan(foregroundPid, 0)
          XCTAssertEqual(String(cString: process), "sleep")
          let commandPath = String(cString: command)
          XCTAssertTrue(commandPath.isEmpty || commandPath.hasSuffix("/sleep"))
          XCTAssertEqual(String(cString: cwd), tempPath)
        }
      }
    }
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

  func testDestroyTerminatesProcessGroupChildrenThatIgnoreHangup() {
    let pidURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-destroy-child-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidURL) }

    let exe = "/bin/sh"
    let command =
      "trap '' HUP TERM; sleep 30 & printf '%s\\n' \"$!\" > "
      + shellSingleQuote(pidURL.path) + "; wait"
    let argStrings = ["/bin/sh", "-lc", command]

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
        guard laban_session_create(&config, size, &session) == 0, let created = session else {
          XCTFail("laban_session_create failed for destroy process-group test")
          return
        }

        let deadline = Date().addingTimeInterval(2.0)
        var sleepPid: pid_t = -1
        while Date() < deadline {
          _ = laban_session_poll(created)
          if let text = try? String(contentsOf: pidURL, encoding: .utf8),
            let parsed = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
          {
            sleepPid = parsed
            break
          }
          Thread.sleep(forTimeInterval: 0.02)
        }

        guard sleepPid > 0 else {
          laban_session_destroy(created)
          XCTFail("shell did not report child sleep pid")
          return
        }
        XCTAssertTrue(processExists(sleepPid), "sleep child should be alive before destroy")

        laban_session_destroy(created)
        session = nil

        let exited = waitForProcessExit(sleepPid)
        if !exited {
          kill(sleepPid, SIGKILL)
        }
        XCTAssertTrue(
          exited,
          "destroy must terminate shell-launched children in the PTY process group")
      }
    }
  }

  func testControlCInterruptsForegroundPTYProcess() {
    let exe = "/bin/cat"
    let argStrings = ["/bin/cat"]

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
        guard laban_session_create(&config, size, &session) == 0, let session else {
          XCTFail("laban_session_create failed for Ctrl-C PTY test")
          return
        }
        defer { laban_session_destroy(session) }

        XCTAssertTrue(
          waitForForegroundProcess(session, named: "cat"),
          "test process must own the foreground PTY before Ctrl-C")

        var event = LabanKeyEvent()
        event.action = LABAN_KEY_ACTION_PRESS
        event.key = LABAN_KEY_C
        event.modifiers = 2  // control
        let encodedCapacity = 16
        var encoded = [UInt8](repeating: 0, count: encodedCapacity)
        var encodedLen = 0
        XCTAssertEqual(
          encoded.withUnsafeMutableBytes { buf in
            laban_session_encode_key(
              session,
              &event,
              buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
              encodedCapacity,
              &encodedLen
            )
          },
          0
        )
        XCTAssertEqual(Array(encoded.prefix(encodedLen)), [0x03])
        XCTAssertEqual(laban_session_send_key(session, &event), 0)

        var exit = LabanExitState()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
          XCTAssertEqual(laban_session_poll(session), 0)
          exit = laban_session_exit_state(session)
          if exit.status != 0 { break }
          Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertEqual(exit.status, 2, "Ctrl-C must deliver SIGINT to the foreground PTY process")
        XCTAssertEqual(exit.exit_status, SIGINT)
      }
    }
  }

  func testControlZSendsSuspendCharacterThroughForegroundPTY() {
    let exe = "/bin/sh"
    let command = "trap 'printf TSTP-TRAP\\\\n; exit 42' TSTP; printf READY\\\\n; read line"
    let argStrings = ["/bin/sh", "-lc", command]

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
        guard laban_session_create(&config, size, &session) == 0, let session else {
          XCTFail("laban_session_create failed for Ctrl-Z PTY test")
          return
        }
        defer { laban_session_destroy(session) }

        XCTAssertTrue(
          waitForForegroundProcess(session, named: "sh"),
          "shell must own the foreground PTY before Ctrl-Z")

        var event = LabanKeyEvent()
        event.action = LABAN_KEY_ACTION_PRESS
        event.key = LABAN_KEY_Z
        event.modifiers = 2  // control
        XCTAssertEqual(laban_session_send_key(session, &event), 0)

        var snap: UnsafeMutablePointer<LabanSnapshot>?
        let deadline = Date().addingTimeInterval(2.0)
        var visible = ""
        while Date() < deadline {
          XCTAssertEqual(laban_session_poll(session), 0)
          if let current = snap {
            laban_snapshot_destroy(current)
            snap = nil
          }
          guard laban_session_snapshot(session, &snap) == 0, let s = snap else { break }
          visible = visibleText(from: UnsafePointer(s))
          if visible.contains("TSTP-TRAP") { break }
          Thread.sleep(forTimeInterval: 0.02)
        }
        defer { laban_snapshot_destroy(snap) }

        XCTAssertTrue(
          visible.contains("TSTP-TRAP"),
          "Ctrl-Z must reach the foreground shell as VSUSP/SIGTSTP; visible text: \(visible)")
      }
    }
  }

  func testPTYInitialSizeIsVisibleAtShellStartup() {
    let exe = "/bin/sh"
    let argStrings = ["/bin/sh", "-lc", "stty size"]

    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        var config = LabanLaunchConfig()
        config.executable = exeCStr
        config.argv = argvPtr
        config.fixture_mode = 0

        var size = LabanTerminalSize()
        size.rows = 13
        size.cols = 42
        size.pixel_width = 420
        size.pixel_height = 260
        size.cell_width = 10
        size.cell_height = 20

        var session: OpaquePointer?
        guard laban_session_create(&config, size, &session) == 0, let session else {
          XCTFail("laban_session_create failed for initial PTY size test")
          return
        }
        defer { laban_session_destroy(session) }

        var snap: UnsafeMutablePointer<LabanSnapshot>?
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
          XCTAssertEqual(laban_session_poll(session), 0)
          if let current = snap {
            laban_snapshot_destroy(current)
            snap = nil
          }
          guard laban_session_snapshot(session, &snap) == 0, let s = snap else { break }
          if s.pointee.status != 0 { break }
          Thread.sleep(forTimeInterval: 0.02)
        }
        defer { laban_snapshot_destroy(snap) }

        guard let s = snap else {
          XCTFail("no snapshot obtained after polling for stty output")
          return
        }

        let text = visibleText(from: UnsafePointer(s))
        XCTAssertTrue(
          text.contains("13 42"),
          "shell must see initial PTY size before startup command runs; got \(text.debugDescription)"
        )
      }
    }
  }

  func testPTYWriteToNonReadingChildIsBounded() {
    let exe = "/bin/sleep"
    let argStrings = ["/bin/sleep", "2"]

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
        guard laban_session_create(&config, size, &session) == 0, let session else {
          XCTFail("laban_session_create failed for non-reading PTY write test")
          return
        }
        defer { laban_session_destroy(session) }

        let input = [UInt8](repeating: UInt8(ascii: "x"), count: 16 * 1024 * 1024)
        let start = Date()
        let result = input.withUnsafeBytes { buf in
          laban_session_write(
            session,
            buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
            input.count)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
          result, -1, "write should report incomplete delivery under PTY back-pressure")
        XCTAssertLessThan(
          elapsed, 0.25,
          "writing to a child that is not reading must not block the UI path for one second")
      }
    }
  }

  func testPTYSpawnEnvironmentAppliesDefaultsAndOverrides() {
    let exe = "/bin/sh"
    let command =
      "printf '%s|%s|%s|%s\\n' \"$TERM\" \"$COLORTERM\" \"${NO_COLOR-unset}\" \"$LABAN_SPAWN_ENV_TEST\""
    let argStrings = ["/bin/sh", "-lc", command]
    let envStrings = [
      "TERM=laban-term",
      "NO_COLOR=explicit",
      "LABAN_SPAWN_ENV_TEST=ok",
    ]

    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        withCArgv(envStrings) { envPtr in
          var config = LabanLaunchConfig()
          config.executable = exeCStr
          config.argv = argvPtr
          config.envp = envPtr
          config.fixture_mode = 0

          var size = LabanTerminalSize()
          size.rows = 8
          size.cols = 80

          var session: OpaquePointer?
          guard laban_session_create(&config, size, &session) == 0, let session else {
            XCTFail("laban_session_create failed for spawn environment test")
            return
          }
          defer { laban_session_destroy(session) }

          var snap: UnsafeMutablePointer<LabanSnapshot>?
          let deadline = Date().addingTimeInterval(2.0)
          while Date() < deadline {
            XCTAssertEqual(laban_session_poll(session), 0)
            if let current = snap {
              laban_snapshot_destroy(current)
              snap = nil
            }
            guard laban_session_snapshot(session, &snap) == 0, let s = snap else { break }
            if s.pointee.status != 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
          }
          defer { laban_snapshot_destroy(snap) }

          guard let s = snap else {
            XCTFail("no snapshot obtained after polling for environment output")
            return
          }

          let text = visibleText(from: UnsafePointer(s))
          XCTAssertTrue(
            text.contains("laban-term|truecolor|explicit|ok"),
            "spawn env should preserve overrides and Laban defaults; got \(text.debugDescription)")
        }
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

  func testPTYZeroSizedResizeDoesNotPropagateToChildWinsize() {
    let captureURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-zero-resize-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: captureURL) }

    let exe = "/bin/sh"
    let argStrings = ["/bin/sh", "-lc", "read line; stty size"]

    exe.withCString { exeCStr in
      captureURL.path.withCString { capturePath in
        withCArgv(argStrings) { argvPtr in
          var config = LabanLaunchConfig()
          config.executable = exeCStr
          config.argv = argvPtr
          config.fixture_mode = 0

          var size = LabanTerminalSize()
          size.rows = 24
          size.cols = 80

          var session: OpaquePointer?
          guard laban_session_create(&config, size, &session) == 0, let session else {
            XCTFail("laban_session_create failed for zero-sized PTY resize test")
            return
          }
          defer { laban_session_destroy(session) }

          XCTAssertEqual(laban_session_capture_start(session, capturePath), 0)
          defer { _ = laban_session_capture_stop(session) }

          var zeroSize = LabanTerminalSize()
          zeroSize.rows = 0
          zeroSize.cols = 0
          XCTAssertEqual(laban_session_resize(session, zeroSize), 0)

          let newline = [UInt8(ascii: "\n")]
          newline.withUnsafeBytes { buf in
            XCTAssertEqual(
              laban_session_write(
                session,
                buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                newline.count
              ),
              0
            )
          }

          var exit = LabanExitState()
          let deadline = Date().addingTimeInterval(2.0)
          while Date() < deadline {
            XCTAssertEqual(laban_session_poll(session), 0)
            exit = laban_session_exit_state(session)
            if exit.status != 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
          }

          XCTAssertNotEqual(exit.status, 0, "shell should exit after reporting stty size")
          XCTAssertEqual(laban_session_capture_stop(session), 0)

          let output = (try? String(contentsOf: captureURL, encoding: .utf8)) ?? ""
          XCTAssertTrue(
            output.contains("24 80"),
            "zero-sized AppKit view resize must not set child PTY winsize to 0x0; "
              + "captured output: \(output.debugDescription)"
          )
          XCTAssertFalse(
            output.contains("0 0"),
            "child PTY winsize must preserve the last non-empty geometry during empty views")
        }
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
      _ = laban_session_write(
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

  func testCursorReportsInvisibleWhenScrolledIntoHistory() {
    guard let session = makeFixtureSession(rows: 5, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var allBytes = [UInt8]()
    for i in 0..<10 {
      allBytes += Array("line-\(i)\r\n".utf8)
    }
    allBytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self), allBytes.count)
    }

    var snapAtBottom: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapAtBottom), 0)
    guard let bottom = snapAtBottom else {
      XCTFail("snapshot nil")
      return
    }
    XCTAssertEqual(
      bottom.pointee.cursor_visible, 1,
      "cursor on the active screen must be visible while viewport is at the bottom")
    laban_snapshot_destroy(snapAtBottom)

    XCTAssertEqual(laban_session_scroll_viewport(session, -4), 0)

    var snapInHistory: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapInHistory), 0)
    defer { laban_snapshot_destroy(snapInHistory) }
    guard let history = snapInHistory else {
      XCTFail("snapshot nil")
      return
    }
    XCTAssertEqual(
      history.pointee.cursor_visible, 0,
      "cursor must be reported invisible when the viewport is scrolled off the active screen")
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
      _ = laban_session_write(
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
      _ = laban_session_write(
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
      _ = laban_session_write(
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
      _ = laban_session_write(
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
      _ = laban_session_write(
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
      _ = laban_session_write(
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

  // MARK: - Paste encoding tests

  func testBracketedPasteDisabledByDefault() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var enabled: Int32 = 1
    XCTAssertEqual(laban_session_bracketed_paste_enabled(session, &enabled), 0)
    XCTAssertEqual(enabled, 0, "bracketed paste must be disabled by default")
  }

  func testBracketedPasteEnabledAfterEscapeSequence() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Enable bracketed paste mode: ESC[?2004h
    let enableSeq = Array("\u{1b}[?2004h".utf8)
    enableSeq.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        enableSeq.count)
    }

    var enabled: Int32 = 0
    XCTAssertEqual(laban_session_bracketed_paste_enabled(session, &enabled), 0)
    XCTAssertEqual(enabled, 1, "bracketed paste must be enabled after ESC[?2004h")
  }

  func testEncodePastePlainModeConvertsNewlinesToCR() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Plain mode (no bracketed paste): newlines become CRs.
    let input = Array("hello\nworld".utf8)
    var outBuf = [UInt8](repeating: 0, count: 64)
    var outLen: size_t = 0
    var bracketed: Int32 = 1

    let r = input.withUnsafeBytes { buf in
      laban_session_encode_paste(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        input.count,
        &outBuf, outBuf.count,
        &outLen, &bracketed)
    }

    XCTAssertEqual(r, 0)
    XCTAssertEqual(bracketed, 0, "bracketed must be 0 in plain mode")
    let result = String(bytes: outBuf.prefix(Int(outLen)), encoding: .utf8)
    // In plain mode, \n is replaced with \r.
    XCTAssertEqual(result, "hello\rworld", "newlines must become CRs in plain paste mode")
  }

  func testEncodePasteBracketedModeAddsWrappingSequences() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Enable bracketed paste mode.
    let enableSeq = Array("\u{1b}[?2004h".utf8)
    enableSeq.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        enableSeq.count)
    }

    let input = Array("hello mvp".utf8)
    var outBuf = [UInt8](repeating: 0, count: 128)
    var outLen: size_t = 0
    var bracketed: Int32 = 0

    let r = input.withUnsafeBytes { buf in
      laban_session_encode_paste(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        input.count,
        &outBuf, outBuf.count,
        &outLen, &bracketed)
    }

    XCTAssertEqual(r, 0)
    XCTAssertEqual(bracketed, 1, "bracketed must be 1 when bracketed paste mode is active")

    let result = String(bytes: outBuf.prefix(Int(outLen)), encoding: .utf8) ?? ""
    XCTAssertTrue(result.hasPrefix("\u{1b}[200~"), "must begin with ESC[200~")
    XCTAssertTrue(result.hasSuffix("\u{1b}[201~"), "must end with ESC[201~")
    XCTAssertTrue(result.contains("hello mvp"), "encoded output must contain original text")
  }

  func testEncodePasteRejectsNullInputWhenLenIsNonZero() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var outBuf = [UInt8](repeating: 0xAA, count: 16)
    var outLen: size_t = 99
    var bracketed: Int32 = 1

    XCTAssertEqual(
      laban_session_encode_paste(
        session,
        nil,
        4,
        &outBuf, outBuf.count,
        &outLen, &bracketed),
      -1)
    XCTAssertEqual(outLen, 0)
    XCTAssertEqual(bracketed, 0)
  }

  // MARK: - Capability response tests
  //
  // These verify that programs like tmux and vim, which probe terminal
  // capabilities at startup, get a reply written back to the PTY instead of
  // hanging. In fixture mode the bytes the terminal would write to the PTY
  // are captured and exposed via laban_session_drain_response.

  private func drainResponse(_ session: OpaquePointer) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 256)
    var len: size_t = 0
    let r = laban_session_drain_response(session, &buf, buf.count, &len)
    XCTAssertEqual(r, 0, "drain_response must succeed")
    return Array(buf.prefix(Int(len)))
  }

  private func writeBytes(_ session: OpaquePointer, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
  }

  private func feedOutput(_ session: OpaquePointer, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { buf in
      _ = laban_session_feed_output(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
  }

  func testNoQueryProducesNoResponse() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("hello".utf8))
    let response = drainResponse(session)
    XCTAssertEqual(response.count, 0, "plain text must not produce a capability response")
  }

  func testDA1QueryProducesPrimaryDeviceAttributesResponse() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // CSI c — primary device attributes query
    writeBytes(session, [0x1b, 0x5b, 0x63])

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    // Keep DA1 conservative: VT220 conformance (62) plus ANSI color (22).
    // Do not claim 132-column mode or OSC-52 clipboard support from the MVP bridge.
    XCTAssertEqual(
      asString, "\u{1b}[?62;22c",
      "DA1 reply should be conservative; got \(asString.debugDescription)")
  }

  func testCapabilityResponseIsNotBufferedWhenPTYWriteFails() {
    let exe = "/usr/bin/true"
    let argStrings = ["/usr/bin/true"]

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
        guard laban_session_create(&config, size, &session) == 0, let session else {
          XCTFail("laban_session_create failed for terminal-response failure test")
          return
        }
        defer { laban_session_destroy(session) }

        var exit = LabanExitState()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
          XCTAssertEqual(laban_session_poll(session), 0)
          exit = laban_session_exit_state(session)
          if exit.status != 0 { break }
          Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNotEqual(exit.status, 0, "child must exit before the response write")

        // CSI c triggers a terminal-generated DA1 reply. With the PTY slave
        // gone, the reply cannot be delivered and should not appear in the
        // drain buffer as if it had been committed.
        feedOutput(session, [0x1b, 0x5b, 0x63])
        XCTAssertEqual(drainResponse(session), [])
      }
    }
  }

  func testDA2QueryProducesSecondaryDeviceAttributesResponse() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // CSI > c — secondary device attributes query
    writeBytes(session, [0x1b, 0x5b, 0x3e, 0x63])

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    // DA2 format: ESC[>Pp;Pv;Pc c. We report Pp=1 (VT220), Pv=1, Pc=0.
    XCTAssertEqual(
      asString, "\u{1b}[>1;1;0c",
      "DA2 reply mismatch; got \(asString.debugDescription)")
  }

  func testDA3QueryProducesTertiaryDeviceAttributesResponse() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // CSI = c — tertiary device attributes query.
    writeBytes(session, [0x1b, 0x5b, 0x3d, 0x63])

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    XCTAssertEqual(
      asString, "\u{1b}P!|00000000\u{1b}\\",
      "DA3 reply mismatch; got \(asString.debugDescription)")
  }

  func testEnquiryProducesAnswerbackResponse() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // ENQ (0x05) requests a terminal answerback string.
    writeBytes(session, [0x05])

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    XCTAssertEqual(
      asString, "laban",
      "ENQ answerback mismatch; got \(asString.debugDescription)")
  }

  func testDECRQMModeQueryUsesTerminalState() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // DECRQM for wraparound mode. libghostty reports wraparound as set by default.
    writeBytes(session, Array("\u{1b}[?7$p".utf8))

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    XCTAssertEqual(
      asString, "\u{1b}[?7;1$y",
      "DECRQM wraparound reply mismatch; got \(asString.debugDescription)")
  }

  func testInBandResizeReportIsEmittedWhenMode2048IsEnabled() {
    guard let session = makeFixtureSession(rows: 24, cols: 80) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("\u{1b}[?2048h".utf8))
    XCTAssertEqual(drainResponse(session), [], "enabling mode 2048 should not reply immediately")

    var size = LabanTerminalSize()
    size.rows = 40
    size.cols = 100
    size.cell_width = 9
    size.cell_height = 18
    XCTAssertEqual(laban_session_resize(session, size), 0)

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    XCTAssertEqual(
      asString, "\u{1b}[48;40;100;720;900t",
      "mode 2048 resize report mismatch; got \(asString.debugDescription)")
  }

  func testXTVersionQueryReportsLaban() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // CSI > q — XTVERSION query
    writeBytes(session, [0x1b, 0x5b, 0x3e, 0x71])

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    // Response is a DCS string: ESC P > | laban ESC \
    XCTAssertTrue(
      asString.contains("laban"),
      "XTVERSION reply must contain \"laban\"; got \(asString.debugDescription)")
  }

  func testXTWINOPSCharacterSizeQueryReturnsConfiguredGeometry() {
    guard let session = makeFixtureSession(rows: 24, cols: 80) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // CSI 18 t — XTWINOPS request for text-area size in characters.
    // Reply format: CSI 8 ; rows ; cols t.
    writeBytes(session, Array("\u{1b}[18t".utf8))

    let response = drainResponse(session)
    let asString = String(bytes: response, encoding: .utf8) ?? ""
    XCTAssertEqual(
      asString, "\u{1b}[8;24;80t",
      "XTWINOPS 18t reply mismatch; got \(asString.debugDescription)")
  }

  func testColorSchemeQueryUsesStoredSessionScheme() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_DARK)), 0)
    writeBytes(session, Array("\u{1b}[?996n".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}[?997;1n",
      "dark color-scheme query must return CSI ? 997 ; 1 n")

    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_LIGHT)), 0)
    writeBytes(session, Array("\u{1b}[?996n".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}[?997;2n",
      "light color-scheme query must return CSI ? 997 ; 2 n")
  }

  func testColorSchemeModeReportsThemeChanges() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_DARK)), 0)
    writeBytes(session, Array("\u{1b}[?2031h".utf8))
    _ = drainResponse(session)

    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_LIGHT)), 0)
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}[?997;2n",
      "mode 2031 should report a switch to a light host scheme")

    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_DARK)), 0)
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}[?997;1n",
      "mode 2031 should report a switch back to a dark host scheme")
  }

  func testFocusReportingModeGatesFocusEncoding() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var enabled: Int32 = -1
    XCTAssertEqual(laban_session_focus_reporting_enabled(session, &enabled), 0)
    XCTAssertEqual(enabled, 0)

    var buf = [UInt8](repeating: 0, count: 16)
    var len: size_t = 99
    XCTAssertEqual(laban_session_encode_focus(session, 1, &buf, buf.count, &len), 0)
    XCTAssertEqual(len, 0, "focus bytes must be suppressed before mode 1004 is enabled")

    writeBytes(session, Array("\u{1b}[?1004h".utf8))
    XCTAssertEqual(laban_session_focus_reporting_enabled(session, &enabled), 0)
    XCTAssertEqual(enabled, 1)

    XCTAssertEqual(laban_session_encode_focus(session, 1, &buf, buf.count, &len), 0)
    XCTAssertEqual(Array(buf.prefix(Int(len))), Array("\u{1b}[I".utf8))

    XCTAssertEqual(laban_session_encode_focus(session, 0, &buf, buf.count, &len), 0)
    XCTAssertEqual(Array(buf.prefix(Int(len))), Array("\u{1b}[O".utf8))

    writeBytes(session, Array("\u{1b}[?1004l".utf8))
    XCTAssertEqual(laban_session_focus_reporting_enabled(session, &enabled), 0)
    XCTAssertEqual(enabled, 0)
    XCTAssertEqual(laban_session_encode_focus(session, 1, &buf, buf.count, &len), 0)
    XCTAssertEqual(len, 0, "focus bytes must be suppressed after mode 1004 is disabled")
  }

  func testSnapshotTracksCursorStyleAndBlinking() {
    guard let session = makeFixtureSession(rows: 4, cols: 10) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    func snapshotAfter(_ sequence: String) -> LabanSnapshot? {
      writeBytes(session, Array(sequence.utf8))
      var snap: UnsafeMutablePointer<LabanSnapshot>?
      guard laban_session_snapshot(session, &snap) == 0, let snap else { return nil }
      let value = snap.pointee
      laban_snapshot_destroy(snap)
      return value
    }

    let blinkingBar = snapshotAfter("\u{1b}[5 q")
    XCTAssertEqual(blinkingBar?.cursor_style, Int32(LABAN_CURSOR_STYLE_BAR))
    XCTAssertEqual(blinkingBar?.cursor_blinking, 1)

    let steadyUnderline = snapshotAfter("\u{1b}[4 q")
    XCTAssertEqual(steadyUnderline?.cursor_style, Int32(LABAN_CURSOR_STYLE_UNDERLINE))
    XCTAssertEqual(steadyUnderline?.cursor_blinking, 0)

    let steadyBlock = snapshotAfter("\u{1b}[2 q")
    XCTAssertEqual(steadyBlock?.cursor_style, Int32(LABAN_CURSOR_STYLE_BLOCK))
    XCTAssertEqual(steadyBlock?.cursor_blinking, 0)
  }

  func testDrainReturnsBytesOnceAndClearsBuffer() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, [0x1b, 0x5b, 0x63])  // CSI c
    let first = drainResponse(session)
    XCTAssertGreaterThan(first.count, 0, "first drain should return the DA1 reply")

    let second = drainResponse(session)
    XCTAssertEqual(second.count, 0, "second drain should be empty — buffer cleared")
  }

  func testDrainRejectsNullOutputBufferWithoutConsumingResponse() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, [0x1b, 0x5b, 0x63])  // CSI c

    var len: size_t = 99
    XCTAssertEqual(laban_session_drain_response(session, nil, 8, &len), -1)
    XCTAssertEqual(len, 0)

    let response = drainResponse(session)
    XCTAssertGreaterThan(response.count, 0, "failed drain must leave the response queued")
  }

  func testWritePasteInFixtureModeSucceeds() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let input = Array("paste me".utf8)
    var result = LabanPasteResult()
    let r = input.withUnsafeBytes { buf in
      laban_session_write_paste(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        input.count,
        &result)
    }

    XCTAssertEqual(r, 0, "write_paste must return 0 in fixture mode")
    XCTAssertEqual(result.bracketed, 0, "bracketed must be 0 without bracketed paste mode")
    XCTAssertGreaterThan(result.bytes_written, 0, "must report non-zero bytes written")
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
