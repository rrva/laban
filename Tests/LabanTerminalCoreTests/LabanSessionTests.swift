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
  var awaiting: String?
}

private final class BellProbe {
  var counts: [UInt64] = []
}

private let tabStatusProbeCallback: LabanTabStatusCallback = { userdata, _, status, _, awaiting in
  guard let userdata else { return }
  let probe = Unmanaged<TabStatusProbe>.fromOpaque(userdata).takeUnretainedValue()
  probe.calls += 1
  probe.status = status.map { String(cString: $0) }
  probe.awaiting = awaiting.map { String(cString: $0) }
}

private let bellProbeCallback: LabanBellCallback = { userdata, _, count in
  guard let userdata else { return }
  let probe = Unmanaged<BellProbe>.fromOpaque(userdata).takeUnretainedValue()
  probe.counts.append(count)
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

  /// Exercises the env-override deep-copy (`dup_envp` / `free_stored_envp`
  /// in session_lifecycle.c) so Address Sanitizer covers the alloc/free of
  /// the stored envp array. The copy happens at create for every mode, so a
  /// fixture session is enough — no real spawn needed.
  func testCreateWithEnvOverridesIsSanitizerClean() {
    let exe = strdup("/bin/sh")!
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), nil]
    var envp: [UnsafeMutablePointer<CChar>?] = [
      strdup("ZDOTDIR=/tmp/overlay"), strdup("LABAN_REAL_ZDOTDIR=/home/u"), nil,
    ]
    let argvCount = argv.count
    let envCount = envp.count
    defer {
      free(exe)
      for p in argv where p != nil { free(p) }
      for p in envp where p != nil { free(p) }
    }

    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80

    let session: OpaquePointer? = argv.withUnsafeMutableBufferPointer { argvBuf in
      argvBuf.baseAddress!.withMemoryRebound(
        to: UnsafePointer<CChar>?.self, capacity: argvCount
      ) { argvRebound in
        envp.withUnsafeMutableBufferPointer { envBuf in
          envBuf.baseAddress!.withMemoryRebound(
            to: UnsafePointer<CChar>?.self, capacity: envCount
          ) { envRebound -> OpaquePointer? in
            config.executable = UnsafePointer(exe)
            config.argv = UnsafePointer(argvRebound)
            config.envp = UnsafePointer(envRebound)
            var s: OpaquePointer?
            return laban_session_create(&config, size, &s) == 0 ? s : nil
          }
        }
      }
    }
    XCTAssertNotNil(session, "create with env overrides should succeed")
    // Destroy frees the deep-copied envp; ASan flags any leak or double-free.
    laban_session_destroy(session)
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

  func testTabStatusAwaitingFieldIsParsedAndAbsentWhenOmitted() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let probe = TabStatusProbe()
    let userdata = Unmanaged.passUnretained(probe).toOpaque()
    XCTAssertEqual(
      laban_session_set_tab_status_callback(session, tabStatusProbeCallback, userdata), 0)

    writeBytes(session, Array("\u{1B}]21337;awaiting=1;status=needs input\u{07}".utf8))
    XCTAssertEqual(probe.calls, 1)
    XCTAssertEqual(probe.awaiting, "1")
    XCTAssertEqual(probe.status, "needs input")

    // Omitted key: NULL through the callback (preserve semantics upstream).
    writeBytes(session, Array("\u{1B}]21337;status=ok\u{07}".utf8))
    XCTAssertEqual(probe.calls, 2)
    XCTAssertNil(probe.awaiting)

    // Explicit clear: empty string, distinct from absent.
    writeBytes(session, Array("\u{1B}]21337;awaiting=\u{07}".utf8))
    XCTAssertEqual(probe.calls, 3)
    XCTAssertEqual(probe.awaiting, "")
  }

  /// The raw-output scanners' bulk skip states (tab_status.c, osc133.c,
  /// osc_host.c) jump with memchr instead of stepping the state machine per
  /// byte (laban_scan_skip_to_esc* in session_internal.h). The risk surface is
  /// a marker straddling a write boundary mid-skip, so feed an SGR-heavy
  /// stream containing an ignored OSC, a DCS string, a tab-status marker, and
  /// an OSC 133 marker — split at every byte position, plus byte-at-a-time —
  /// and require the scanners to fire exactly as they do for the unsplit
  /// stream.
  func testScannerMarkersSurviveChunkSplitsAtEveryByte() {
    let stream = Array(
      ("\u{1B}[31mplain text 0123456789 \u{1B}[0m"  // SGR runs: NORMAL-state skips
        + "\u{1B}]4711;ignored-osc-payload\u{1B}\\"  // unknown OSC: BODY_OTHER skip
        + "\u{1B}P+q544e\u{1B}\\"  // DCS: STRING skip (osc133/osc_host)
        + "\u{1B}]21337;status=ok\u{1B}\\"  // tab-status marker, ST-terminated
        + "\u{1B}]133;D;7\u{07}"  // OSC 133 command end, exit 7, BEL
        + "tail text\u{1B}[0m\n").utf8)

    final class OSC133Probe {
      var actions: [LabanOSC133Action] = []
      var exitCodes: [Int32?] = []
    }

    func run(_ chunks: [[UInt8]], _ label: String) {
      guard let session = makeFixtureSession() else {
        XCTFail("laban_session_create returned non-zero (\(label))")
        return
      }
      defer { laban_session_destroy(session) }

      let tabProbe = TabStatusProbe()
      XCTAssertEqual(
        laban_session_set_tab_status_callback(
          session, tabStatusProbeCallback,
          Unmanaged.passUnretained(tabProbe).toOpaque()),
        0)

      let oscProbe = OSC133Probe()
      XCTAssertEqual(
        laban_session_set_osc133_callback(
          session,
          { ud, _, action, hasExit, exit in
            guard let ud else { return }
            let probe = Unmanaged<OSC133Probe>.fromOpaque(ud).takeUnretainedValue()
            probe.actions.append(action)
            probe.exitCodes.append(hasExit != 0 ? exit : nil)
          },
          Unmanaged.passUnretained(oscProbe).toOpaque()),
        0)

      for chunk in chunks {
        writeBytes(session, chunk)
      }

      XCTAssertEqual(tabProbe.calls, 1, "tab status must fire exactly once (\(label))")
      XCTAssertEqual(tabProbe.status, "ok", "tab status payload (\(label))")
      XCTAssertEqual(
        oscProbe.actions, [LABAN_OSC133_COMMAND_END], "osc133 action (\(label))")
      XCTAssertEqual(oscProbe.exitCodes, [7], "osc133 exit code (\(label))")
    }

    run([stream], "unsplit")
    run(stream.map { [$0] }, "byte-at-a-time")
    for cut in 1..<stream.count {
      run([Array(stream[..<cut]), Array(stream[cut...])], "split@\(cut)")
    }
  }

  func testBellCallbackFiresAndCountTracksBel() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var count: UInt64 = 999
    XCTAssertEqual(laban_session_bell_count(session, &count), 0)
    XCTAssertEqual(count, 0)

    let probe = BellProbe()
    let userdata = Unmanaged.passUnretained(probe).toOpaque()
    XCTAssertEqual(laban_session_set_bell_callback(session, bellProbeCallback, userdata), 0)

    writeBytes(session, [0x07, 0x07])
    XCTAssertEqual(probe.counts, [1, 2])
    XCTAssertEqual(laban_session_bell_count(session, &count), 0)
    XCTAssertEqual(count, 2)

    XCTAssertEqual(laban_session_set_bell_callback(session, nil, nil), 0)
    writeBytes(session, [0x07])
    XCTAssertEqual(probe.counts, [1, 2])
    XCTAssertEqual(laban_session_bell_count(session, &count), 0)
    XCTAssertEqual(count, 3)
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

        var readySnap: UnsafeMutablePointer<LabanSnapshot>?
        let readyDeadline = Date().addingTimeInterval(2.0)
        var readyVisible = ""
        while Date() < readyDeadline {
          XCTAssertEqual(laban_session_poll(session), 0)
          if let current = readySnap {
            laban_snapshot_destroy(current)
            readySnap = nil
          }
          guard laban_session_snapshot(session, &readySnap) == 0, let s = readySnap else { break }
          readyVisible = visibleText(from: UnsafePointer(s))
          if readyVisible.contains("READY") { break }
          Thread.sleep(forTimeInterval: 0.02)
        }
        defer { laban_snapshot_destroy(readySnap) }
        XCTAssertTrue(
          readyVisible.contains("READY"),
          "shell must reach the read before Ctrl-Z; visible text: \(readyVisible)")
        guard readyVisible.contains("READY") else { return }

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

  func testSendKeyEncodedReturnsBytesAndSupportsSmallBufferRetry() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let text = String(repeating: "a", count: 256)
    text.withCString { cText in
      var event = LabanKeyEvent()
      event.action = LABAN_KEY_ACTION_PRESS
      event.key = LABAN_KEY_A
      event.utf8 = cText
      event.utf8_len = text.utf8.count

      var requiredLen = 0
      XCTAssertEqual(
        laban_session_send_key_encoded(session, &event, nil, 0, &requiredLen),
        1
      )
      XCTAssertEqual(requiredLen, text.utf8.count)

      var out = [UInt8](repeating: 0, count: requiredLen)
      let outCapacity = out.count
      var sentLen = 0
      XCTAssertEqual(
        out.withUnsafeMutableBytes { buf in
          laban_session_send_key_encoded(
            session,
            &event,
            buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
            outCapacity,
            &sentLen
          )
        },
        0
      )
      XCTAssertEqual(sentLen, text.utf8.count)
      XCTAssertEqual(Array(out.prefix(sentLen)), Array(text.utf8))
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

  func testPTYSpawnEnvironmentStripsInheritedColorSuppression() {
    let oldTerm = getenv("TERM").map { String(cString: $0) }
    let oldColorTerm = getenv("COLORTERM").map { String(cString: $0) }
    let oldNoColor = getenv("NO_COLOR").map { String(cString: $0) }
    setenv("TERM", "dumb", 1)
    setenv("COLORTERM", "disabled", 1)
    setenv("NO_COLOR", "inherited", 1)
    defer {
      if let oldTerm { setenv("TERM", oldTerm, 1) } else { unsetenv("TERM") }
      if let oldColorTerm {
        setenv("COLORTERM", oldColorTerm, 1)
      } else {
        unsetenv("COLORTERM")
      }
      if let oldNoColor { setenv("NO_COLOR", oldNoColor, 1) } else { unsetenv("NO_COLOR") }
    }

    let exe = "/bin/sh"
    let command =
      "printf '%s|%s|%s\\n' \"$TERM\" \"$COLORTERM\" \"${NO_COLOR-unset}\""
    let argStrings = ["/bin/sh", "-lc", command]

    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        var config = LabanLaunchConfig()
        config.executable = exeCStr
        config.argv = argvPtr
        config.fixture_mode = 0

        var size = LabanTerminalSize()
        size.rows = 8
        size.cols = 80

        var session: OpaquePointer?
        guard laban_session_create(&config, size, &session) == 0, let session else {
          XCTFail("laban_session_create failed for inherited spawn environment test")
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
          let text = visibleText(from: UnsafePointer(s))
          if text.contains("xterm-256color|truecolor|unset") { break }
          if s.pointee.status != 0 { break }
          Thread.sleep(forTimeInterval: 0.02)
        }
        defer { laban_snapshot_destroy(snap) }

        guard let s = snap else {
          XCTFail("no snapshot obtained after polling for inherited environment output")
          return
        }

        let text = visibleText(from: UnsafePointer(s))
        XCTAssertTrue(
          text.contains("xterm-256color|truecolor|unset"),
          "spawn env should replace inherited terminal/color suppression; got "
            + text.debugDescription)
      }
    }
  }

  func testPTYZshPromptColorSequencesReachSnapshot() throws {
    let exe = "/bin/zsh"
    guard access(exe, X_OK) == 0 else {
      throw XCTSkip("/bin/zsh is not available on this platform")
    }

    let command =
      "autoload -U colors; colors; "
      + "print -P '%F{#00ff00}HEX%f %F{46}IDX%f %K{#112233}BGHEX%k'"
    let argStrings = [exe, "-fc", command]

    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        var config = LabanLaunchConfig()
        config.executable = exeCStr
        config.argv = argvPtr
        config.fixture_mode = 0

        var size = LabanTerminalSize()
        size.rows = 8
        size.cols = 80

        var session: OpaquePointer?
        guard laban_session_create(&config, size, &session) == 0, let session else {
          XCTFail("laban_session_create failed for zsh color PTY test")
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
          let text = visibleText(from: UnsafePointer(s))
          if text.contains("HEX") && text.contains("IDX") && text.contains("BGHEX") {
            break
          }
          Thread.sleep(forTimeInterval: 0.02)
        }
        defer { laban_snapshot_destroy(snap) }

        guard let s = snap else {
          XCTFail("no snapshot obtained after polling for zsh color output")
          return
        }

        let text = visibleText(from: UnsafePointer(s))
        XCTAssertTrue(
          text.contains("HEX") && text.contains("IDX") && text.contains("BGHEX"),
          "zsh color output text should reach the terminal snapshot; got \(text.debugDescription)")

        guard let hex = cellColors(in: UnsafePointer(s), matchingASCII: "HEX") else {
          XCTFail("missing HEX cells in zsh color snapshot")
          return
        }
        XCTAssertEqual(hex.foreground, 0x00FF_00FF, "zsh truecolor foreground must survive PTY")

        guard let indexed = cellColors(in: UnsafePointer(s), matchingASCII: "IDX") else {
          XCTFail("missing IDX cells in zsh color snapshot")
          return
        }
        XCTAssertEqual(indexed.foreground, 0x00FF_00FF, "zsh 256-color foreground must survive PTY")

        guard let background = cellColors(in: UnsafePointer(s), matchingASCII: "BGHEX") else {
          XCTFail("missing BGHEX cells in zsh color snapshot")
          return
        }
        XCTAssertEqual(
          background.background, 0x1122_33FF, "zsh truecolor background must survive PTY")
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

  func testResizeReflowsScrollbackAfterScrollingAtNarrowWidth() {
    guard let session = makeFixtureSession(rows: 4, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let longLine = "ABCDEFGHIJKLMNOPQRSTabcdefghijklmnopqrst"
    writeBytes(session, Array((longLine + "\r\none\r\ntwo\r\nthree\r\nfour\r\n").utf8))

    var narrowSize = LabanTerminalSize()
    narrowSize.rows = 4
    narrowSize.cols = 10
    XCTAssertEqual(laban_session_resize(session, narrowSize), 0)
    XCTAssertEqual(laban_session_scroll_viewport(session, -3), 0)

    var wideSize = LabanTerminalSize()
    wideSize.rows = 4
    wideSize.cols = 20
    XCTAssertEqual(laban_session_resize(session, wideSize), 0)
    XCTAssertEqual(laban_session_scroll_viewport(session, -3), 0)

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }
    guard let snapshot else {
      XCTFail("snapshot nil")
      return
    }

    let rows = rawRows(from: UnsafePointer(snapshot)).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    XCTAssertTrue(
      rows.contains("ABCDEFGHIJKLMNOPQRST"),
      "wide scrollback should expose the first 20-column wrap row; rows: \(rows)")
    XCTAssertTrue(
      rows.contains("abcdefghijklmnopqrst"),
      "wide scrollback should expose the second 20-column wrap row; rows: \(rows)")
    XCTAssertFalse(
      rows.contains("ABCDEFGHIJ"),
      "scrollback must not remain wrapped at the prior 10-column geometry; rows: \(rows)")
  }

  func testScrollbackExtractionReflowsAfterNarrowResize() {
    guard let session = makeFixtureSession(rows: 4, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let longLine = "ABCDEFGHIJKLMNOPQRSTabcdefghijklmnopqrst"
    writeBytes(session, Array((longLine + "\r\none\r\ntwo\r\nthree\r\nfour\r\n").utf8))

    var narrowSize = LabanTerminalSize()
    narrowSize.rows = 4
    narrowSize.cols = 10
    XCTAssertEqual(laban_session_resize(session, narrowSize), 0)

    var wideSize = LabanTerminalSize()
    wideSize.rows = 4
    wideSize.cols = 20
    XCTAssertEqual(laban_session_resize(session, wideSize), 0)

    var textBuffer: UnsafeMutablePointer<CChar>?
    var rowOffsets: UnsafeMutablePointer<UInt32>?
    var outRows: size_t = 0
    var outTextLen: size_t = 0
    XCTAssertEqual(
      laban_session_scrollback_extract_alloc(
        session, 0, 0, &textBuffer, &rowOffsets, &outRows, &outTextLen),
      0
    )
    defer { laban_session_scrollback_extract_free(textBuffer) }
    defer { laban_session_scrollback_extract_free(rowOffsets) }
    guard let textBuffer else {
      XCTFail("scrollback extraction text nil")
      return
    }

    let extracted = String(cString: textBuffer)
    XCTAssertTrue(
      extracted.contains("ABCDEFGHIJKLMNOPQRST\nabcdefghijklmnopqrst"),
      "extracted scrollback should follow the current 20-column geometry; "
        + "text: \(extracted.debugDescription)")
    XCTAssertFalse(
      extracted.contains("ABCDEFGHIJ\nKLMNOPQRST"),
      "extracted scrollback must not stay at the prior 10-column geometry; "
        + "text: \(extracted.debugDescription)")
  }

  func testResizeReflowsLinesWrittenAtNarrowWidth() {
    guard let session = makeFixtureSession(rows: 4, cols: 10) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let longLine = "ABCDEFGHIJKLMNOPQRSTabcdefghijklmnopqrst"
    writeBytes(session, Array((longLine + "\r\none\r\ntwo\r\nthree\r\nfour\r\n").utf8))
    XCTAssertEqual(laban_session_scroll_viewport(session, -3), 0)

    var wideSize = LabanTerminalSize()
    wideSize.rows = 4
    wideSize.cols = 20
    XCTAssertEqual(laban_session_resize(session, wideSize), 0)
    XCTAssertEqual(laban_session_scroll_viewport(session, -3), 0)

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }
    guard let snapshot else {
      XCTFail("snapshot nil")
      return
    }

    let rows = rawRows(from: UnsafePointer(snapshot)).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    XCTAssertTrue(
      rows.contains("ABCDEFGHIJKLMNOPQRST"),
      "wide scrollback should expose the first 20-column wrap row for text written narrow; "
        + "rows: \(rows)")
    XCTAssertTrue(
      rows.contains("abcdefghijklmnopqrst"),
      "wide scrollback should expose the second 20-column wrap row for text written narrow; "
        + "rows: \(rows)")
    XCTAssertFalse(
      rows.contains("ABCDEFGHIJ"),
      "scrollback must not remain wrapped at the original 10-column geometry; rows: \(rows)")
  }

  func testResizeReflowsAfterRenderedNarrowScrollbackFrame() {
    guard let session = makeFixtureSession(rows: 4, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let longLine = "ABCDEFGHIJKLMNOPQRSTabcdefghijklmnopqrst"
    writeBytes(session, Array((longLine + "\r\none\r\ntwo\r\nthree\r\nfour\r\n").utf8))
    XCTAssertEqual(snapshotAndMarkRendered(session), 0)

    var narrowSize = LabanTerminalSize()
    narrowSize.rows = 4
    narrowSize.cols = 10
    XCTAssertEqual(laban_session_resize(session, narrowSize), 0)
    XCTAssertEqual(snapshotAndMarkRendered(session), 0)

    XCTAssertEqual(laban_session_scroll_viewport(session, -3), 0)
    XCTAssertEqual(snapshotAndMarkRendered(session), 0)

    var wideSize = LabanTerminalSize()
    wideSize.rows = 4
    wideSize.cols = 20
    XCTAssertEqual(laban_session_resize(session, wideSize), 0)
    XCTAssertEqual(snapshotAndMarkRendered(session), 0)

    XCTAssertEqual(laban_session_scroll_viewport(session, -3), 0)

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }
    guard let snapshot else {
      XCTFail("snapshot nil")
      return
    }

    let rows = rawRows(from: UnsafePointer(snapshot)).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    XCTAssertTrue(
      rows.contains("ABCDEFGHIJKLMNOPQRST"),
      "wide scrollback should reflow after a rendered narrow scrollback frame; rows: \(rows)")
    XCTAssertTrue(
      rows.contains("abcdefghijklmnopqrst"),
      "wide scrollback should reflow after a rendered narrow scrollback frame; rows: \(rows)")
    XCTAssertFalse(
      rows.contains("ABCDEFGHIJ"),
      "scrollback must not preserve the rendered narrow geometry; rows: \(rows)")
  }

  func testColumnResizeMarksAllSnapshotRowsDirty() {
    guard let session = makeFixtureSession(rows: 4, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("ABCDEFGHIJKLMNOPQRSTabcdefghijklmnopqrst\r\n".utf8))
    var initialSnapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &initialSnapshot), 0)
    laban_snapshot_destroy(initialSnapshot)
    XCTAssertEqual(laban_session_mark_rendered(session), 0)

    var narrowSize = LabanTerminalSize()
    narrowSize.rows = 4
    narrowSize.cols = 10
    XCTAssertEqual(laban_session_resize(session, narrowSize), 0)

    var snapshot: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
    defer { laban_snapshot_destroy(snapshot) }
    guard let snapshot else {
      XCTFail("snapshot nil")
      return
    }

    XCTAssertEqual(snapshot.pointee.dirty_row_count, 4)
    let dirtyRows = (0..<Int(snapshot.pointee.dirty_row_count)).map {
      snapshot.pointee.dirty_rows![$0]
    }
    XCTAssertEqual(
      dirtyRows,
      [1, 1, 1, 1],
      "column reflow must force full-row damage; dirty rows: \(dirtyRows)")
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

    XCTAssertEqual(laban_session_send_mouse(session, &press), 0)

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

  func testButtonModeDragMotionBelowSurfaceClampsToBottomRow() {
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

    XCTAssertEqual(laban_session_send_mouse(session, &press), 0)

    var motion = press
    motion.action = LABAN_MOUSE_ACTION_MOTION
    motion.button = LABAN_MOUSE_BUTTON_NONE
    motion.x = 16
    motion.y = 120

    var motionBuf = [UInt8](repeating: 0, count: 64)
    var motionLen: size_t = 0
    XCTAssertEqual(
      laban_session_encode_mouse(session, &motion, &motionBuf, motionBuf.count, &motionLen), 0)

    let seq = String(bytes: motionBuf.prefix(Int(motionLen)), encoding: .utf8)
    XCTAssertEqual(
      seq,
      "\u{1b}[<32;3;5M",
      "held left-button motion below the surface must be clamped to the bottom row")
  }

  func testExplicitButtonSgrMouseEncodingDoesNotRequireLocalTerminalMode() {
    guard let session = makeFixtureSession(rows: 5, cols: 30) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var press = LabanMouseEvent()
    press.action = LABAN_MOUSE_ACTION_PRESS
    press.button = LABAN_MOUSE_BUTTON_LEFT
    press.x = 8
    press.y = 16
    press.screen_width = 240
    press.screen_height = 80
    press.cell_width = 8
    press.cell_height = 16
    press.tracking_mode = LABAN_MOUSE_TRACKING_BUTTON
    press.format = LABAN_MOUSE_FORMAT_SGR

    var pressBuf = [UInt8](repeating: 0, count: 64)
    var pressLen: size_t = 0
    XCTAssertEqual(
      laban_session_send_mouse_encoded(session, &press, &pressBuf, pressBuf.count, &pressLen),
      0)
    XCTAssertEqual(
      String(bytes: pressBuf.prefix(Int(pressLen)), encoding: .utf8),
      "\u{1b}[<0;2;2M")

    var motion = press
    motion.action = LABAN_MOUSE_ACTION_MOTION
    motion.button = LABAN_MOUSE_BUTTON_NONE
    motion.x = 16
    motion.y = 120

    var motionBuf = [UInt8](repeating: 0, count: 64)
    var motionLen: size_t = 0
    XCTAssertEqual(
      laban_session_send_mouse_encoded(session, &motion, &motionBuf, motionBuf.count, &motionLen),
      0)
    XCTAssertEqual(
      String(bytes: motionBuf.prefix(Int(motionLen)), encoding: .utf8),
      "\u{1b}[<32;3;5M")
  }

  func testMouseEncodeDoesNotCommitHeldButtonState() {
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
    XCTAssertNotEqual(
      seq,
      "\u{1b}[<32;3;3M",
      "preview encoding a press must not make the later motion look like a held-button drag")
  }

  func testSendMouseEncodedReturnsBytesAndCommitsHeldButtonState() {
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
      laban_session_send_mouse_encoded(session, &press, &pressBuf, pressBuf.count, &pressLen),
      0)
    XCTAssertEqual(
      String(bytes: pressBuf.prefix(Int(pressLen)), encoding: .utf8),
      "\u{1b}[<0;2;2M")

    var motion = press
    motion.action = LABAN_MOUSE_ACTION_MOTION
    motion.button = LABAN_MOUSE_BUTTON_NONE
    motion.x = 16
    motion.y = 32

    var motionBuf = [UInt8](repeating: 0, count: 64)
    var motionLen: size_t = 0
    XCTAssertEqual(
      laban_session_send_mouse_encoded(session, &motion, &motionBuf, motionBuf.count, &motionLen),
      0)
    XCTAssertEqual(
      String(bytes: motionBuf.prefix(Int(motionLen)), encoding: .utf8),
      "\u{1b}[<32;3;3M",
      "send-and-capture must return the bytes for the committed held-button motion")
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

  func testMouseEncodingRejectsMissingOutputBufferWithCapacity() {
    guard let session = makeFixtureSession(rows: 5, cols: 20) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanMouseEvent()
    event.action = LABAN_MOUSE_ACTION_PRESS
    event.button = LABAN_MOUSE_BUTTON_LEFT

    var outLen: size_t = 99
    XCTAssertEqual(laban_session_encode_mouse(session, &event, nil, 16, &outLen), -1)
    XCTAssertEqual(outLen, 0)
  }

  func testSendMouseSucceedsInFixtureMode() {
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

    // Fixture mode has no PTY, but send_mouse still succeeds and commits local mouse state.
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

  func testEncodePasteBracketedModeDeliversEscapeBytesLiterally() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("\u{1b}[?2004h".utf8))

    // Pasted escape sequences are content, not terminal styling: the fence
    // protects them, so they must arrive byte-for-byte.
    let input = Array("hello \u{1b}[31m world".utf8)
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
    XCTAssertEqual(bracketed, 1)
    XCTAssertEqual(
      String(bytes: outBuf.prefix(Int(outLen)), encoding: .utf8),
      "\u{1b}[200~hello \u{1b}[31m world\u{1b}[201~",
      "bracketed paste must deliver embedded escape bytes literally")
  }

  func testEncodePasteBracketedModeNeutralizesEmbeddedEndFence() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("\u{1b}[?2004h".utf8))

    // An embedded end fence would close the bracket early and inject the
    // remainder as keyboard input; only its ESC is replaced by a space.
    let input = Array("safe\u{1b}[201~rm -rf /".utf8)
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
    XCTAssertEqual(bracketed, 1)
    XCTAssertEqual(
      String(bytes: outBuf.prefix(Int(outLen)), encoding: .utf8),
      "\u{1b}[200~safe [201~rm -rf /\u{1b}[201~",
      "an embedded end fence must be neutralized, everything else preserved")
  }

  func testEncodePasteBracketedModeEmptyPasteStillSendsBothFences() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("\u{1b}[?2004h".utf8))

    var outBuf = [UInt8](repeating: 0, count: 32)
    var outLen: size_t = 0
    var bracketed: Int32 = 0

    XCTAssertEqual(
      laban_session_encode_paste(
        session, nil, 0, &outBuf, outBuf.count, &outLen, &bracketed),
      0)
    XCTAssertEqual(bracketed, 1)
    XCTAssertEqual(
      String(bytes: outBuf.prefix(Int(outLen)), encoding: .utf8),
      "\u{1b}[200~\u{1b}[201~",
      "an empty bracketed paste must still send both fences")
  }

  func testEncodePastePlainModeStillStripsEscapes() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Without the fence there is nothing stopping interpretation, so the
    // legacy strip (ESC and friends become spaces) must stay.
    let input = Array("a\u{1b}b".utf8)
    var outBuf = [UInt8](repeating: 0, count: 32)
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
    XCTAssertEqual(bracketed, 0)
    XCTAssertEqual(
      String(bytes: outBuf.prefix(Int(outLen)), encoding: .utf8),
      "a b",
      "plain-mode paste must keep stripping escape bytes")
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
    // Do not claim 132-column mode here. (OSC 52 clipboard is supported via the
    // osc_host.c side channel, but it is not a DA1 attribute and never appeared
    // in this reply.)
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

  func testDECXCPRRepliesWithDECPrivateMarker() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // DECXCPR (CSI ? 6 n) must reply with the DEC-private marker so the
    // report cannot be confused with modified function-key input. The plain
    // DSR form (CSI 6 n) keeps the unmarked reply.
    writeBytes(session, Array("\u{1b}[4;7H\u{1b}[?6n".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}[?4;7R",
      "DECXCPR must reply CSI ? row ; col R")

    writeBytes(session, Array("\u{1b}[6n".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}[4;7R",
      "plain CPR must stay unmarked")
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

  // MARK: - OSC host-integration (color query + notifications)
  //
  // libghostty-vt parses OSC 9 and the OSC 10/11 color *query* form but its
  // VT-only C API neither answers the query nor surfaces the notification.
  // Laban's osc_host.c side-channel scanner closes both gaps. A coding-agent
  // TUI (OpenAI Codex) probes OSC 10/11 to match its theme to the window and
  // emits OSC 9 on turn-complete.

  func testOSCForegroundColorQueryEchoesEffectiveForeground() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Set the default foreground (OSC 10), as ThemePaletteInjector does.
    writeBytes(session, Array("\u{1b}]10;#1a2b3c\u{07}".utf8))
    XCTAssertEqual(drainResponse(session), [], "an OSC 10 set must not produce a reply")

    // Query it (OSC 10;?). Expect the xterm 4-hex reply, ST-terminated.
    writeBytes(session, Array("\u{1b}]10;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]10;rgb:1a1a/2b2b/3c3c\u{1b}\\",
      "OSC 10;? must reply with the effective foreground in rgb:RRRR/GGGG/BBBB")
  }

  func testOSCBackgroundColorQueryEchoesEffectiveBackground() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("\u{1b}]11;#ffcc00\u{07}".utf8))
    _ = drainResponse(session)
    writeBytes(session, Array("\u{1b}]11;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]11;rgb:ffff/cccc/0000\u{1b}\\",
      "OSC 11;? must reply with the effective background")
  }

  func testOSCColorReplyPrecedesCursorPositionReplyWithinOneChunk() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // gh auth login's startup probe (go-termenv): an OSC 11 color query
    // immediately fenced by DSR 6n, written as ONE chunk. termenv reads the
    // first reply; when the CPR fence arrives before the color reply it stops
    // listening and the stray OSC reply corrupts the next prompt reader
    // (survey aborts with `unexpected escape sequence: ['\x1b' ']']`).
    // Replies must come back in query order.
    writeBytes(session, Array("\u{1b}]11;?\u{1b}\\\u{1b}[6n".utf8))
    let reply = String(bytes: drainResponse(session), encoding: .utf8) ?? ""
    XCTAssertTrue(
      reply.hasPrefix("\u{1b}]11;rgb:"),
      "the OSC 11 reply must precede the CPR fence reply; got \(reply.debugDescription)")
    XCTAssertTrue(
      reply.hasSuffix("R"),
      "the CPR reply must still follow the OSC 11 reply; got \(reply.debugDescription)")
  }

  func testOSCColorQueryFallsBackToColorScheme() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // No theme configured: the reply is synthesized from the light/dark scheme
    // so the querying app always gets a usable pair. Dark -> white fg, black bg.
    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_DARK)), 0)
    writeBytes(session, Array("\u{1b}]11;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\",
      "dark scheme with no configured color must report a black background")

    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_LIGHT)), 0)
    writeBytes(session, Array("\u{1b}]11;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\",
      "light scheme with no configured color must report a white background")
  }

  func testOSCCursorColorQueryEchoesEffectiveCursorColor() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // An OSC 12 set is libghostty's job and must not produce a reply.
    writeBytes(session, Array("\u{1b}]12;#112233\u{07}".utf8))
    XCTAssertEqual(drainResponse(session), [], "an OSC 12 set must not produce a reply")

    writeBytes(session, Array("\u{1b}]12;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]12;rgb:1111/2222/3333\u{1b}\\",
      "OSC 12;? must reply with the effective cursor color in rgb:RRRR/GGGG/BBBB")
  }

  func testOSCCursorColorQueryFallsBackToSchemeInk() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // No cursor color configured: the cursor tracks the ink, so the fallback
    // follows the foreground for the active scheme. Dark -> white cursor.
    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_DARK)), 0)
    writeBytes(session, Array("\u{1b}]12;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]12;rgb:ffff/ffff/ffff\u{1b}\\",
      "dark scheme with no configured cursor color must report a white cursor")

    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_LIGHT)), 0)
    writeBytes(session, Array("\u{1b}]12;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]12;rgb:0000/0000/0000\u{1b}\\",
      "light scheme with no configured cursor color must report a black cursor")
  }

  func testOSC9NotificationFiresCallbackAndIgnoresProgress() {
    final class Sink { var messages: [String] = [] }
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = Sink()
    let userdata = Unmanaged.passUnretained(sink).toOpaque()
    XCTAssertEqual(
      laban_session_set_osc_notification_callback(
        session,
        { ud, _, text, len in
          guard let ud, let text else { return }
          let sink = Unmanaged<Sink>.fromOpaque(ud).takeUnretainedValue()
          let bytes = UnsafeBufferPointer(start: text, count: len)
          sink.messages.append(String(decoding: bytes, as: UTF8.self))
        },
        userdata),
      0)

    // OSC 9 desktop notification (BEL-terminated) fires the callback.
    writeBytes(session, Array("\u{1b}]9;Agent turn complete\u{07}".utf8))
    XCTAssertEqual(sink.messages, ["Agent turn complete"])

    // OSC 9 ST-terminated also works.
    writeBytes(session, Array("\u{1b}]9;Approval requested\u{1b}\\".utf8))
    XCTAssertEqual(sink.messages, ["Agent turn complete", "Approval requested"])

    // ConEmu progress (OSC 9 ; 4 ; ...) must NOT be treated as a notification.
    writeBytes(session, Array("\u{1b}]9;4;1;50\u{07}".utf8))
    XCTAssertEqual(
      sink.messages, ["Agent turn complete", "Approval requested"],
      "OSC 9;4 progress reports must not fire the notification callback")
  }

  // MARK: - Terminal-support spec conformance (escape-level)
  //
  // Byte-level cases from the terminal signalling spec's test list. The
  // multiplexer passthrough case (spec 9.18) is intentionally absent: Laban
  // is a terminal emulator, not a multiplexer, and that section is
  // informative for it.

  /// Spec 9.9-9.12: OSC 9;4 progress operations parse, percent clamps
  /// leniently, and a missing value reaches the callback as -1.
  func testProgressCallbackParsesOperationsAndClampsPercent() {
    final class ProgressSink {
      var events: [(op: Int32, percent: Int32)] = []
    }
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ProgressSink()
    let userdata = Unmanaged.passUnretained(sink).toOpaque()
    XCTAssertEqual(
      laban_session_set_progress_callback(
        session,
        { ud, op, percent in
          guard let ud else { return }
          let sink = Unmanaged<ProgressSink>.fromOpaque(ud).takeUnretainedValue()
          sink.events.append((op, percent))
        },
        userdata),
      0)

    writeBytes(session, Array("\u{1b}]9;4;1;42\u{07}".utf8))
    writeBytes(session, Array("\u{1b}]9;4;3;\u{07}".utf8))
    writeBytes(session, Array("\u{1b}]9;4;2;80\u{1b}\\".utf8))
    writeBytes(session, Array("\u{1b}]9;4;1;250\u{07}".utf8))
    writeBytes(session, Array("\u{1b}]9;4;0;\u{07}".utf8))
    writeBytes(session, Array("\u{1b}]9;4;7;10\u{07}".utf8))  // unknown op: ignored

    XCTAssertEqual(sink.events.map { $0.op }, [1, 3, 2, 1, 0])
    XCTAssertEqual(sink.events.map { $0.percent }, [42, -1, 80, 100, -1])
  }

  /// Spec 9.15: kitty OSC 99 chunks sharing an id assemble into one
  /// notification, delivered through the same callback as OSC 9.
  func testKittyNotificationAssemblesChunksAndDeliversOnce() {
    final class Sink { var messages: [String] = [] }
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = Sink()
    let userdata = Unmanaged.passUnretained(sink).toOpaque()
    XCTAssertEqual(
      laban_session_set_osc_notification_callback(
        session,
        { ud, _, text, len in
          guard let ud, let text else { return }
          let sink = Unmanaged<Sink>.fromOpaque(ud).takeUnretainedValue()
          let bytes = UnsafeBufferPointer(start: text, count: len)
          sink.messages.append(String(decoding: bytes, as: UTF8.self))
        },
        userdata),
      0)

    writeBytes(session, Array("\u{1b}]99;i=123:d=0:p=title;Agent App\u{07}".utf8))
    XCTAssertEqual(sink.messages, [], "an unfinished chunk must not notify")
    writeBytes(session, Array("\u{1b}]99;i=123:p=body;Permission needed\u{07}".utf8))
    XCTAssertEqual(sink.messages, ["Agent App: Permission needed"])
    // A trailing finalize for the already-delivered id must not duplicate.
    writeBytes(session, Array("\u{1b}]99;i=123:d=1:a=focus;\u{07}".utf8))
    XCTAssertEqual(sink.messages, ["Agent App: Permission needed"])
  }

  /// Spec 9.16: Ghostty-style OSC 777 notify joins title and body.
  func testOsc777NotificationJoinsTitleAndBody() {
    final class Sink { var messages: [String] = [] }
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = Sink()
    let userdata = Unmanaged.passUnretained(sink).toOpaque()
    XCTAssertEqual(
      laban_session_set_osc_notification_callback(
        session,
        { ud, _, text, len in
          guard let ud, let text else { return }
          let sink = Unmanaged<Sink>.fromOpaque(ud).takeUnretainedValue()
          let bytes = UnsafeBufferPointer(start: text, count: len)
          sink.messages.append(String(decoding: bytes, as: UTF8.self))
        },
        userdata),
      0)

    writeBytes(session, Array("\u{1b}]777;notify;Agent App;Permission needed\u{07}".utf8))
    XCTAssertEqual(sink.messages, ["Agent App: Permission needed"])

    // Non-notify 777 subcommands are not notifications.
    writeBytes(session, Array("\u{1b}]777;something;else\u{07}".utf8))
    XCTAssertEqual(sink.messages, ["Agent App: Permission needed"])
  }

  /// Spec 9.8: `\;` is a literal semicolon inside a tab-status value and
  /// `\\` a literal backslash — neither splits a new key/value pair.
  func testTabStatusEscapedSemicolonAndBackslash() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let probe = TabStatusProbe()
    let userdata = Unmanaged.passUnretained(probe).toOpaque()
    XCTAssertEqual(
      laban_session_set_tab_status_callback(session, tabStatusProbeCallback, userdata), 0)

    writeBytes(
      session, Array("\u{1b}]21337;status=Waiting\\; approve C:\\\\tmp\u{07}".utf8))
    XCTAssertEqual(probe.calls, 1)
    XCTAssertEqual(probe.status, "Waiting; approve C:\\tmp")
  }

  /// Spec 9.19: an unknown OSC is ignored without corrupting later parsing.
  func testUnknownOscIsIgnoredAndParsingRecovers() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let probe = TabStatusProbe()
    let userdata = Unmanaged.passUnretained(probe).toOpaque()
    XCTAssertEqual(
      laban_session_set_tab_status_callback(session, tabStatusProbeCallback, userdata), 0)

    writeBytes(session, Array("\u{1b}]99999;anything\u{07}".utf8))
    XCTAssertEqual(probe.calls, 0)
    writeBytes(session, Array("\u{1b}]21337;status=ok\u{07}".utf8))
    XCTAssertEqual(probe.calls, 1)
    XCTAssertEqual(probe.status, "ok")
  }

  // MARK: - OSC 52 clipboard bridge
  //
  // libghostty-vt parses OSC 52 but its VT-only API registers no clipboard
  // sink, so the sequence is dropped. osc_host.c picks it up: a *write* delivers
  // the base64 payload to a callback (the Swift bridge decodes + writes
  // NSPasteboard), and a *read* query is answered on the PTY only when read is
  // explicitly enabled. The headline use is copy-from-a-remote-program over SSH.

  final class ClipboardSink {
    var selection: String?
    var base64: String?
    var writes = 0
    var reads = 0
  }

  private func installClipboardWriteCapture(
    _ session: OpaquePointer, _ sink: ClipboardSink
  ) {
    let ud = Unmanaged.passUnretained(sink).toOpaque()
    XCTAssertEqual(
      laban_session_set_osc_clipboard_callbacks(
        session,
        { ud, _, sel, selLen, b64, b64Len in
          guard let ud else { return }
          let sink = Unmanaged<ClipboardSink>.fromOpaque(ud).takeUnretainedValue()
          sink.writes += 1
          if let sel, selLen > 0 {
            sink.selection = sel.withMemoryRebound(to: UInt8.self, capacity: selLen) {
              String(decoding: UnsafeBufferPointer(start: $0, count: selLen), as: UTF8.self)
            }
          } else {
            sink.selection = ""
          }
          if let b64, b64Len > 0 {
            sink.base64 = String(
              decoding: UnsafeBufferPointer(start: b64, count: b64Len), as: UTF8.self)
          }
        },
        nil,
        ud),
      0)
  }

  func testOSC52WriteFiresClipboardCallbackWithBase64AndSelection() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ClipboardSink()
    installClipboardWriteCapture(session, sink)

    // base64("hello") == "aGVsbG8=" — a program copying to the host clipboard.
    writeBytes(session, Array("\u{1b}]52;c;aGVsbG8=\u{07}".utf8))
    XCTAssertEqual(sink.writes, 1)
    XCTAssertEqual(sink.selection, "c")
    XCTAssertEqual(sink.base64, "aGVsbG8=")
    XCTAssertEqual(drainResponse(session), [], "a clipboard write must not reply on the PTY")
  }

  func testOSC52WriteAcceptsSTTerminatorAndEmptySelection() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ClipboardSink()
    installClipboardWriteCapture(session, sink)

    // Empty Pc (defaults to clipboard) + ST terminator. base64("world").
    writeBytes(session, Array("\u{1b}]52;;d29ybGQ=\u{1b}\\".utf8))
    XCTAssertEqual(sink.writes, 1)
    XCTAssertEqual(sink.selection, "")
    XCTAssertEqual(sink.base64, "d29ybGQ=")
  }

  func testOSC52EmptyWritePayloadIsIgnored() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ClipboardSink()
    installClipboardWriteCapture(session, sink)

    // `OSC 52 ; c ;` with no data clears the selection in xterm; Laban ignores
    // it so a stray sequence cannot silently wipe the user's clipboard.
    writeBytes(session, Array("\u{1b}]52;c;\u{07}".utf8))
    XCTAssertEqual(sink.writes, 0, "an empty OSC 52 write must not fire the callback")
  }

  func testOSC52OversizedWriteIsDropped() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ClipboardSink()
    installClipboardWriteCapture(session, sink)

    // 300 KiB of base64 is past OSC_HOST_OSC52_MAX (256 KiB): dropped, not
    // truncated — the clipboard is left untouched rather than set to a partial.
    let huge = String(repeating: "A", count: 300 * 1024)
    writeBytes(session, Array("\u{1b}]52;c;\(huge)\u{07}".utf8))
    XCTAssertEqual(sink.writes, 0, "an oversized OSC 52 write must be dropped")
  }

  func testOSC52ReadQueryDeniedByDefaultProducesNoResponse() {
    final class ReadSink { var reads = 0 }
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ReadSink()
    let ud = Unmanaged.passUnretained(sink).toOpaque()
    XCTAssertEqual(
      laban_session_set_osc_clipboard_callbacks(
        session,
        nil,
        { ud, _, _, _ in
          guard let ud else { return }
          Unmanaged<ReadSink>.fromOpaque(ud).takeUnretainedValue().reads += 1
        },
        ud),
      0)

    // Read is off by default: a `?` query must neither fire the callback nor
    // reply, so a remote program cannot read the host clipboard unasked.
    writeBytes(session, Array("\u{1b}]52;c;?\u{07}".utf8))
    XCTAssertEqual(sink.reads, 0, "read callback must not fire while read is disabled")
    XCTAssertEqual(drainResponse(session), [], "a denied OSC 52 read must not reply")
  }

  func testOSC52ReadQueryWhenEnabledRespondsOnPTY() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    XCTAssertEqual(laban_session_set_osc52_read_enabled(session, 1), 0)
    // The read handler answers with base64("world") == "d29ybGQ=" for "c".
    XCTAssertEqual(
      laban_session_set_osc_clipboard_callbacks(
        session,
        nil,
        { _, session, _, _ in
          guard let session else { return }
          let b64 = Array("d29ybGQ=".utf8)
          let sel = Array("c".utf8)
          sel.withUnsafeBufferPointer { s in
            s.withMemoryRebound(to: CChar.self) { sc in
              b64.withUnsafeBufferPointer { bb in
                _ = laban_session_respond_clipboard_osc52(
                  session, sc.baseAddress, sc.count, bb.baseAddress, bb.count)
              }
            }
          }
        },
        nil),
      0)

    writeBytes(session, Array("\u{1b}]52;c;?\u{07}".utf8))
    XCTAssertEqual(
      String(bytes: drainResponse(session), encoding: .utf8),
      "\u{1b}]52;c;d29ybGQ=\u{1b}\\",
      "an enabled OSC 52 read must reply with the clipboard as base64, ST-terminated")
  }

  // MARK: - OSC 7 working directory
  //
  // A shell emits `ESC ] 7 ; file://<host>/<path> ST` on each prompt. Laban
  // observes it and adopts a local-host path as the session's authoritative cwd
  // (preferred over proc_pidinfo). A remote-host report is ignored.

  /// Current cwd as reported by laban_session_process_metadata. In fixture mode
  /// the foreground pid is absent, so this returns the OSC 7 cwd when one has
  /// been adopted and the launch cwd otherwise.
  private func processCwd(_ session: OpaquePointer) -> String {
    var childPid: Int32 = -1
    var foregroundPid: Int32 = -1
    var process = [CChar](repeating: 0, count: 256)
    var command = [CChar](repeating: 0, count: 1024)
    var cwd = [CChar](repeating: 0, count: 1024)
    _ = process.withUnsafeMutableBufferPointer { processPtr in
      command.withUnsafeMutableBufferPointer { commandPtr in
        cwd.withUnsafeMutableBufferPointer { cwdPtr in
          laban_session_process_metadata(
            session, &childPid, &foregroundPid,
            processPtr.baseAddress, processPtr.count,
            commandPtr.baseAddress, commandPtr.count,
            cwdPtr.baseAddress, cwdPtr.count)
        }
      }
    }
    return String(cString: cwd)
  }

  private func installCwdCapture(_ session: OpaquePointer, _ sink: ClipboardSink) {
    // Reuse ClipboardSink.base64 as a generic captured-string slot.
    let ud = Unmanaged.passUnretained(sink).toOpaque()
    XCTAssertEqual(
      laban_session_set_osc_working_directory_callback(
        session,
        { ud, _, path, len in
          guard let ud, let path, len > 0 else { return }
          let sink = Unmanaged<ClipboardSink>.fromOpaque(ud).takeUnretainedValue()
          sink.reads += 1
          sink.base64 = path.withMemoryRebound(to: UInt8.self, capacity: len) {
            String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
          }
        },
        ud),
      0)
  }

  func testOSC7LocalReportFiresCallbackAndAdoptsCwd() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ClipboardSink()
    installCwdCapture(session, sink)

    writeBytes(session, Array("\u{1b}]7;file://localhost/Users/me/proj\u{07}".utf8))
    XCTAssertEqual(sink.reads, 1)
    XCTAssertEqual(sink.base64, "/Users/me/proj")
    XCTAssertEqual(
      processCwd(session), "/Users/me/proj",
      "an OSC 7 local-host report must become the session's authoritative cwd")
  }

  func testOSC7PercentDecodesPathAndAcceptsEmptyHost() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Empty authority (file:///...) plus a percent-encoded space.
    writeBytes(session, Array("\u{1b}]7;file:///Users/me/a%20b\u{1b}\\".utf8))
    XCTAssertEqual(processCwd(session), "/Users/me/a b")
  }

  func testOSC7RemoteHostIsIgnored() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    let sink = ClipboardSink()
    installCwdCapture(session, sink)

    // A clearly non-local host (reserved .invalid TLD): the path must NOT be
    // adopted, so a remote SSH shell can't set a bogus local cwd.
    writeBytes(session, Array("\u{1b}]7;file://remote-box.invalid/home/u\u{07}".utf8))
    XCTAssertEqual(sink.reads, 0, "a remote-host OSC 7 must not fire the callback")
    XCTAssertNotEqual(
      processCwd(session), "/home/u",
      "a remote-host OSC 7 path must not become the local cwd")
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

  func testKeyEncodingRejectsMissingOutputBufferWithCapacity() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var event = LabanKeyEvent()
    event.action = LABAN_KEY_ACTION_PRESS
    event.key = LABAN_KEY_ENTER

    var len: size_t = 99
    XCTAssertEqual(laban_session_encode_key(session, &event, nil, 16, &len), -1)
    XCTAssertEqual(len, 0)
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

  func testWritePasteEncodedReturnsCommittedBracketedBytes() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    writeBytes(session, Array("\u{1b}[?2004h".utf8))

    let input = Array("paste me".utf8)
    var requiredLen: size_t = 0
    var result = LabanPasteResult(bracketed: 1, bytes_written: 99)
    XCTAssertEqual(
      input.withUnsafeBytes { buf in
        laban_session_write_paste_encoded(
          session,
          buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
          input.count,
          nil,
          0,
          &requiredLen,
          &result
        )
      },
      1
    )
    XCTAssertGreaterThan(requiredLen, input.count)
    XCTAssertEqual(result.bracketed, 0)
    XCTAssertEqual(result.bytes_written, 0)

    var out = [UInt8](repeating: 0, count: Int(requiredLen))
    let outCapacity = out.count
    var outLen: size_t = 0
    XCTAssertEqual(
      input.withUnsafeBytes { inputBuf in
        out.withUnsafeMutableBytes { outBuf in
          laban_session_write_paste_encoded(
            session,
            inputBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
            input.count,
            outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
            outCapacity,
            &outLen,
            &result
          )
        }
      },
      0
    )
    let sent = String(bytes: out.prefix(Int(outLen)), encoding: .utf8) ?? ""
    XCTAssertEqual(result.bracketed, 1)
    XCTAssertEqual(result.bytes_written, outLen)
    XCTAssertTrue(sent.hasPrefix("\u{1b}[200~"))
    XCTAssertTrue(sent.hasSuffix("\u{1b}[201~"))
    XCTAssertTrue(sent.contains("paste me"))
  }

  func testWritePasteRejectsNullInputWhenLenIsNonZero() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    var result = LabanPasteResult(bracketed: 1, bytes_written: 99)
    XCTAssertEqual(laban_session_write_paste(session, nil, 4, &result), -1)
    XCTAssertEqual(result.bracketed, 0)
    XCTAssertEqual(result.bytes_written, 0)
  }
}

private func visibleText(from snap: UnsafePointer<LabanSnapshot>) -> String {
  rawRows(from: snap)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
}

private func rawRows(from snap: UnsafePointer<LabanSnapshot>) -> [String] {
  let snapshot = snap.pointee
  let rows = Int(snapshot.rows)
  let cols = Int(snapshot.cols)
  guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else { return [] }
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
    lines.append(line)
  }
  return lines
}

private func snapshotAndMarkRendered(_ session: OpaquePointer) -> Int32 {
  var snapshot: UnsafeMutablePointer<LabanSnapshot>?
  guard laban_session_snapshot(session, &snapshot) == 0 else { return -1 }
  laban_snapshot_destroy(snapshot)
  return laban_session_mark_rendered(session)
}

private func cellColors(
  in snap: UnsafePointer<LabanSnapshot>,
  matchingASCII needle: String
) -> (foreground: UInt32, background: UInt32)? {
  let scalars = needle.utf8.map(UInt32.init)
  guard !scalars.isEmpty else { return nil }

  let snapshot = snap.pointee
  let rows = Int(snapshot.rows)
  let cols = Int(snapshot.cols)
  guard let cells = snapshot.cells, scalars.count <= cols else { return nil }

  for row in 0..<rows {
    for col in 0...(cols - scalars.count) {
      var matched = true
      for offset in 0..<scalars.count {
        let cell = cells[row * cols + col + offset]
        if cell.codepoint != scalars[offset] {
          matched = false
          break
        }
      }
      if matched {
        let cell = cells[row * cols + col]
        return (cell.foreground_rgba, cell.background_rgba)
      }
    }
  }

  return nil
}
