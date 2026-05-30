import Darwin
import Foundation
import XCTest

@testable import LabanCore

/// Adversarial end-to-end tests that complement `LabptyStressTests`
/// (concurrent churn) and `LabptyDaemonTests` (happy paths). Each test
/// here picks a single attack surface and verifies the daemon either
/// responds correctly or disconnects the offending client — and stays
/// alive and responsive to the next well-behaved client.
final class LabptyAdversarialTests: XCTestCase {
  private var launched: [Process] = []
  private var tempRoots: [URL] = []

  override func setUp() {
    super.setUp()
    signal(SIGPIPE, SIG_IGN)
  }

  override func tearDown() {
    for process in launched where process.isRunning {
      Darwin.kill(pid_t(process.processIdentifier), SIGKILL)
      process.waitUntilExit()
    }
    // Gate the observability hook (daemon commit d4177eb): an established
    // client force-expired by the idle/frame deadline means the event loop
    // stalled — the ECONNRESET-stall shape that commit 02cb0e6 fixed. If the
    // daemon ever logs that marker during a test, fail here so the regression
    // is self-catching instead of resurfacing as an unexplained client reset.
    for process in launched {
      guard let pipe = process.standardError as? Pipe,
            let data = try? pipe.fileHandleForReading.readToEnd(),
            let text = String(data: data, encoding: .utf8)
      else { continue }
      XCTAssertFalse(
        text.contains("force-expiring established client"),
        "daemon reported an event-loop stall (force-expiring established client): \(text)")
    }
    launched.removeAll()
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  // MARK: - Bogus handles

  func testBogusHandlesReturnErrorWithoutCrashingDaemon() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    // handle=0 and handle=UINT64_MAX never matched a real session;
    // every state-mutating op must return a clean error rather than
    // dereferencing a missing slot. Regression: an earlier `assert(handle
    // > 0)` in labpty_registry_find aborted the daemon on handle=0.
    for handle: UInt64 in [0, .max, 999_999_999] {
      XCTAssertThrowsError(try client.terminate(handle: handle))
      XCTAssertTrue(harness.process.isRunning, "daemon died after terminate(\(handle))")
      XCTAssertThrowsError(try client.signal(handle: handle, signal: Int32(SIGTERM)))
      XCTAssertTrue(harness.process.isRunning, "daemon died after signal(\(handle))")
      XCTAssertThrowsError(try client.resize(handle: handle, rows: 24, cols: 80))
      XCTAssertTrue(harness.process.isRunning, "daemon died after resize(\(handle))")
      XCTAssertThrowsError(
        try client.writeInput(handle: handle, bytes: [UInt8]("hi".utf8)))
      XCTAssertTrue(harness.process.isRunning, "daemon died after writeInput(\(handle))")
    }
    // Daemon must still serve a normal request after the abuse.
    XCTAssertNoThrow(try client.listLabptySessions())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Use after terminate

  func testOperationsOnTerminatedHandleReturnErrorNotCrash() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "use-after-terminate"))

    _ = try client.terminate(handle: descriptor.ptyHandle)

    // Every subsequent operation on the dead handle must error, not
    // touch freed registry state. Terminate-after-terminate is the
    // most interesting one — it re-enters labpty_session_close on a
    // slot that's already been torn down.
    XCTAssertThrowsError(try client.writeInput(
      handle: descriptor.ptyHandle, bytes: [UInt8]("x".utf8)))
    XCTAssertThrowsError(try client.resize(
      handle: descriptor.ptyHandle, rows: 30, cols: 100))
    XCTAssertThrowsError(try client.signal(
      handle: descriptor.ptyHandle, signal: Int32(SIGTERM)))
    XCTAssertThrowsError(try client.terminate(handle: descriptor.ptyHandle))

    XCTAssertNoThrow(try client.listLabptySessions())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Concurrent terminate race

  func testConcurrentTerminateOnSameHandleSurvives() throws {
    let harness = try launchHarness()
    let opener = try waitForClient(socketPath: harness.socketPath)
    defer { opener.close() }
    let descriptor = try opener.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "double-terminate"))

    // Two more clients race terminate against each other. The daemon
    // is single-threaded so one will succeed first; the other should
    // see SESSION_NOT_FOUND (slot freed) or a no-op double-terminate.
    let racerA = try waitForClient(socketPath: harness.socketPath)
    defer { racerA.close() }
    let racerB = try waitForClient(socketPath: harness.socketPath)
    defer { racerB.close() }

    let group = DispatchGroup()
    let lock = NSLock()
    var oks = 0
    var fails = 0
    for racer in [racerA, racerB] {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          _ = try racer.terminate(handle: descriptor.ptyHandle)
          lock.withLock { oks += 1 }
        } catch {
          lock.withLock { fails += 1 }
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + .seconds(5)), .success)
    XCTAssertEqual(oks + fails, 2)
    // Daemon survived and the child is reaped.
    XCTAssertNoThrow(try opener.listLabptySessions())
    try waitForDead(pid: pid_t(descriptor.childPid))
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Colliding logical id

  func testCollidingLogicalIdRaceLeavesExactlyOneSession() throws {
    let harness = try launchHarness()
    let observer = try waitForClient(socketPath: harness.socketPath)
    defer { observer.close() }

    // Both clients race to claim the same logical id. The registry's
    // find_logical step must serialize them so exactly one wins; a
    // race that double-occupies the slot would either crash or list
    // two sessions with the same id.
    let attempts = 8
    let logicalId = "collision-target"
    let group = DispatchGroup()
    let lock = NSLock()
    var winners: [LabptySessionDescriptor] = []
    var losers = 0
    for index in 0..<attempts {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          let client = try LabptyTerminalSessionClient(
            socketPath: harness.socketPath)
          defer { client.close() }
          _ = try client.hello()
          let descriptor = try client.openSession(
            LabptyOpenSessionRequest(
              rows: 24,
              cols: 80,
              argv: ["/bin/sleep", "30"],
              logicalSessionId: logicalId))
          lock.withLock { winners.append(descriptor) }
          _ = index
        } catch {
          lock.withLock { losers += 1 }
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + .seconds(10)), .success)
    // Exactly one open should have succeeded; the rest see
    // SESSION_ID_IN_USE or transient client-slot contention.
    XCTAssertEqual(winners.count, 1, "expected exactly one winner, got \(winners.count)")
    XCTAssertEqual(winners.count + losers, attempts)

    let listed = try observer.listLabptySessions()
    let same = listed.filter { $0.logicalSessionId == logicalId }
    XCTAssertEqual(same.count, 1, "registry has \(same.count) sessions with id \(logicalId)")
    for descriptor in same { _ = try? observer.terminate(handle: descriptor.ptyHandle) }
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Frame fragmentation

  func testFragmentedRequestIsReassembledByDaemon() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let fd = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(fd) }
    let payload = try LabptyHelloRequest(clientId: "frag-test").encode()
    let frame = try LabptyFraming.encodeRequest(
      operation: .hello, sequence: 42, payload: payload)
    // Drip the frame one byte at a time with a sleep between, forcing
    // the daemon's read loop to assemble the header and body across
    // many short reads.
    for byte in frame {
      var b = byte
      let n = Darwin.write(fd, &b, 1)
      XCTAssertEqual(n, 1)
      usleep(1_000)
    }
    let response = try readFrameRaw(fd: fd)
    XCTAssertEqual(response.header.sequence, 42)
    XCTAssertEqual(response.header.operationRaw, LabptyFrameHeader.responseOperation)
    XCTAssertEqual(response.header.responseCode, .ok)
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Garbage / wrong magic

  func testGarbageHeaderDisconnectsClientPreservesDaemon() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)

    let bad = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(bad) }
    // Random non-magic bytes filling a header slot. The daemon's
    // decoder must reject and close the connection; it must not keep
    // reading hoping for valid bytes.
    var junk = Array<UInt8>(repeating: 0, count: 24)
    for i in 0..<junk.count { junk[i] = UInt8.random(in: 0..<255) }
    junk[0] = 0x00  // never matches 'L' so magic mismatch is immediate
    junk[8] = 24   // frameLength = 24 so the decoder reads exactly the bad header
    try writeAllRaw(fd: bad, data: Data(junk))
    try waitForSocketClosed(fd: bad)

    // Daemon still answers a fresh well-formed client.
    let good = try waitForClient(socketPath: harness.socketPath)
    defer { good.close() }
    XCTAssertNoThrow(try good.hello())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Oversize frame claim

  func testOversizeFrameClaimDisconnectsClientPreservesDaemon() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let fd = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(fd) }

    // Valid magic + abi but frame_len claims 200 KiB (over the 128 KiB
    // cap). The daemon must reject the header outright rather than
    // attempt to read 200 KiB into its 128 KiB read_buf.
    var header = [UInt8]()
    header.append(contentsOf: LabptyFrameHeader.magic)
    header.appendUInt16(LabptyFrameHeader.abiMajor)
    header.appendUInt16(LabptyFrameHeader.abiMinor)
    header.appendUInt32(UInt32(200 * 1024))
    header.appendUInt16(LabptyOperation.hello.rawValue)
    header.appendUInt16(0)
    header.appendUInt64(1)
    XCTAssertEqual(header.count, LabptyFrameHeader.headerByteCount)
    try writeAllRaw(fd: fd, data: Data(header))
    try waitForSocketClosed(fd: fd)

    let good = try waitForClient(socketPath: harness.socketPath)
    defer { good.close() }
    XCTAssertNoThrow(try good.hello())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Undersize frame claim (frame_len < header)

  func testUndersizeFrameClaimDisconnectsClientPreservesDaemon() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let fd = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(fd) }

    var header = [UInt8]()
    header.append(contentsOf: LabptyFrameHeader.magic)
    header.appendUInt16(LabptyFrameHeader.abiMajor)
    header.appendUInt16(LabptyFrameHeader.abiMinor)
    header.appendUInt32(8)  // < header size
    header.appendUInt16(LabptyOperation.hello.rawValue)
    header.appendUInt16(0)
    header.appendUInt64(1)
    try writeAllRaw(fd: fd, data: Data(header))
    try waitForSocketClosed(fd: fd)

    let good = try waitForClient(socketPath: harness.socketPath)
    defer { good.close() }
    XCTAssertNoThrow(try good.hello())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Unknown operation code

  func testUnknownOperationReturnsErrorAndConnectionStaysOpen() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let fd = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(fd) }

    // Valid frame shape, but op=0xABCD — not in the daemon's switch.
    var bytes = [UInt8]()
    bytes.append(contentsOf: LabptyFrameHeader.magic)
    bytes.appendUInt16(LabptyFrameHeader.abiMajor)
    bytes.appendUInt16(LabptyFrameHeader.abiMinor)
    bytes.appendUInt32(UInt32(LabptyFrameHeader.headerByteCount))
    bytes.appendUInt16(0xABCD)
    bytes.appendUInt16(0)
    bytes.appendUInt64(7)
    try writeAllRaw(fd: fd, data: Data(bytes))
    let response = try readFrameRaw(fd: fd)
    XCTAssertEqual(response.header.sequence, 7)
    XCTAssertEqual(response.header.operationRaw, LabptyFrameHeader.responseOperation)
    XCTAssertNotEqual(
      response.header.responseCode, .ok,
      "unknown op must produce a non-OK response code")
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Wrong abi major in hello

  func testWrongAbiMajorDisconnectsClientPreservesDaemon() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let fd = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(fd) }

    var bytes = [UInt8]()
    bytes.append(contentsOf: LabptyFrameHeader.magic)
    bytes.appendUInt16(99)  // wrong major
    bytes.appendUInt16(0)
    bytes.appendUInt32(UInt32(LabptyFrameHeader.headerByteCount))
    bytes.appendUInt16(LabptyOperation.hello.rawValue)
    bytes.appendUInt16(0)
    bytes.appendUInt64(1)
    try writeAllRaw(fd: fd, data: Data(bytes))
    try waitForSocketClosed(fd: fd)

    let good = try waitForClient(socketPath: harness.socketPath)
    defer { good.close() }
    XCTAssertNoThrow(try good.hello())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Resize storm

  func testResizeStormOnOneHandleSurvives() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "resize-storm"))

    for index in 0..<500 {
      let rows = 5 + (index % 60)
      let cols = 5 + (index % 200)
      _ = try client.resize(handle: descriptor.ptyHandle, rows: rows, cols: cols)
    }
    let final = try client.resize(handle: descriptor.ptyHandle, rows: 30, cols: 100)
    XCTAssertEqual(final.rows, 30)
    XCTAssertEqual(final.cols, 100)
    _ = try client.terminate(handle: descriptor.ptyHandle)
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Signal storm

  func testSignalStormDoesNotWedgeDaemon() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "signal-storm"))

    // 200 SIGCONT (no-op for sleep) — daemon's handle_signal has a
    // retry-on-ESRCH loop, this exercises the fast-path repeatedly.
    for _ in 0..<200 {
      _ = try client.signal(handle: descriptor.ptyHandle, signal: Int32(SIGCONT))
    }
    _ = try client.terminate(handle: descriptor.ptyHandle)
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Argv at LABPTY_ARGV_MAX

  func testArgvAtMaxBoundarySucceedsOversizeRejected() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    // Exactly 64 entries: argv0 + 63 args. /bin/echo accepts arbitrary
    // args; the session opens and exits quickly.
    var argv = ["/bin/echo"]
    for index in 1..<LabptyProtocolLimits.maxArgvCount { argv.append("arg-\(index)") }
    XCTAssertEqual(argv.count, LabptyProtocolLimits.maxArgvCount)
    XCTAssertNoThrow(
      try client.openSession(
        LabptyOpenSessionRequest(
          rows: 24,
          cols: 80,
          argv: argv,
          logicalSessionId: "argv-max")))

    // 65 entries: rejected by the encoder before reaching the daemon —
    // but we want to verify the protocol layer rejects it cleanly.
    var oversize = argv
    oversize.append("one-too-many")
    XCTAssertThrowsError(
      try client.openSession(
        LabptyOpenSessionRequest(
          rows: 24,
          cols: 80,
          argv: oversize,
          logicalSessionId: "argv-oversize")))
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Rapid reuse of same logical id (serial)

  func testRapidOpenTerminateSameLogicalIdSurvives() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    for index in 0..<200 {
      let descriptor = try client.openSession(
        LabptyOpenSessionRequest(
          rows: 24,
          cols: 80,
          argv: ["/bin/sh", "-c", "exit 0"],
          logicalSessionId: "rapid-reuse"))
      _ = try client.terminate(handle: descriptor.ptyHandle)
      _ = index
    }
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Silent slowloris (F1 regression)

  func testSilentSlowlorisSocketsAreReclaimed() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    // Connect exactly LABPTY_MAX_CLIENTS sockets but send NO bytes — the
    // earlier expire path exempted clients with empty buffers, letting
    // them hold all eight slots forever.
    var silent: [Int32] = []
    for _ in 0..<8 {
      let fd = try connectRaw(socketPath: harness.socketPath)
      silent.append(fd)
    }
    defer { for fd in silent { Darwin.close(fd) } }

    // Idle deadline is 250 ms; 1 s gives expire two ticks to fire.
    Thread.sleep(forTimeInterval: 1.0)

    // A fresh well-behaved client must now claim a slot.
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    XCTAssertNoThrow(try client.hello())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Winsize cap (F7 regression)

  func testResizeBeyondCapIsRejected() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "winsize-cap"))
    // 8000 > the new 4096 cap; 4096 itself succeeds.
    XCTAssertThrowsError(
      try client.resize(handle: descriptor.ptyHandle, rows: 8000, cols: 80))
    XCTAssertNoThrow(
      try client.resize(handle: descriptor.ptyHandle, rows: 4096, cols: 80))
    XCTAssertTrue(harness.process.isRunning)
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  // MARK: - Slowloris with one written byte

  func testSlowlorisSocketsAreReclaimedByExpireTick() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    // Open exactly LABPTY_MAX_CLIENTS slowloris sockets — partial
    // frame, never finished. The daemon's expire_stalled_clients
    // tick should reclaim them within the idle deadline.
    var stalls: [Int32] = []
    for _ in 0..<8 {
      let fd = try connectRaw(socketPath: harness.socketPath)
      stalls.append(fd)
      var magic: UInt8 = LabptyFrameHeader.magic[0]
      _ = Darwin.write(fd, &magic, 1)
    }
    defer { for fd in stalls { Darwin.close(fd) } }

    // Wait for the daemon to reclaim the slots — the daemon's idle
    // deadline is 250 ms, plus 500 ms for an eviction tick to fire.
    Thread.sleep(forTimeInterval: 1.5)

    // A fresh well-behaved client must now be able to connect and
    // hello successfully — proving the slots were freed.
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    XCTAssertNoThrow(try client.hello())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Trickle slowloris (absolute frame deadline)

  /// `expire_stalled_clients` reclaims silent or one-byte-then-quiet
  /// slots via the 250ms idle deadline — but a *trickle* attacker that
  /// sends one byte every ~200ms keeps `deadline_ns` moving forward
  /// indefinitely. `Sources/Labpty/main.c::client_pump_read` arms an
  /// absolute `frame_deadline_ns` on the first byte of a frame and
  /// `expire_stalled_clients` honours it regardless of idle bumps.
  /// Without that absolute deadline, 8 raw sockets could hold all
  /// LABPTY_MAX_CLIENTS slots forever and starve every Swift client.
  func testTrickleFrameCannotOccupyAllClientSlotsForever() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)

    var fds: [Int32] = []
    defer { for fd in fds { Darwin.close(fd) } }

    // Open all 8 control slots with the first magic byte of a request
    // frame — that arms the absolute frame deadline on the daemon.
    for _ in 0..<8 {
      let fd = try connectRaw(socketPath: harness.socketPath)
      fds.append(fd)
      var byte: UInt8 = LabptyFrameHeader.magic[0]
      _ = Darwin.write(fd, &byte, 1)
    }

    // Drip one byte every 200ms (under the 250ms idle deadline) for
    // 1.5s — the idle deadline keeps getting refreshed, so the
    // pre-fix daemon would never reclaim these slots. Stay below the
    // 24-byte header size so the daemon doesn't parse a header and
    // reject for a non-magic-mismatch reason.
    let stop = Date().addingTimeInterval(1.5)
    while Date() < stop {
      for fd in fds {
        var byte: UInt8 = LabptyFrameHeader.magic[0]
        _ = Darwin.write(fd, &byte, 1)
      }
      usleep(200_000)
    }

    // The absolute frame deadline is 2s from the first byte. Wait
    // long enough for it to fire plus an expire tick.
    Thread.sleep(forTimeInterval: 1.5)

    // A fresh well-behaved client must now claim a slot — proof that
    // the trickle sockets were reclaimed.
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    XCTAssertNoThrow(try client.hello())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Terminate is non-blocking on the event loop

  /// Previously `handle_terminate` -> `labpty_session_close` ran a
  /// synchronous waitpid loop that could block the single-threaded
  /// event loop for up to ~700 ms while a HUP-ignoring child sat
  /// through the SIGKILL window. Async terminate splits the request
  /// (SIGHUP + arm deadline) from the reap (SIGKILL escalation +
  /// WNOHANG reap, both inside `labpty_registry_reap`), so other
  /// clients keep getting served while the dying child waits out the
  /// budget.
  func testTerminateOfHupIgnoringChildDoesNotBlockOtherControlRPCs() throws {
    let harness = try launchHarness()
    let killer = try waitForClient(socketPath: harness.socketPath)
    defer { killer.close() }
    let observer = try waitForClient(socketPath: harness.socketPath)
    defer { observer.close() }

    let victim = try killer.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "trap '' HUP; sleep 30"],
        logicalSessionId: "slow-terminate"))

    let terminateGroup = DispatchGroup()
    terminateGroup.enter()
    DispatchQueue.global().async {
      defer { terminateGroup.leave() }
      _ = try? killer.terminate(handle: victim.ptyHandle)
    }

    // Give the terminate RPC a head start so it's the in-flight
    // request when the observer's listLabptySessions arrives.
    usleep(20_000)

    // Observer's RPC must complete promptly. Pre-fix this could
    // wait up to ~700 ms because the synchronous terminate held the
    // event loop. We allow a generous 250 ms — well below the old
    // ceiling, well above any reasonable RTT plus reap-tick budget.
    let start = Date()
    XCTAssertNoThrow(try observer.listLabptySessions())
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(
      elapsed, 0.250,
      "observer RPC took \(elapsed)s; terminate of a HUP-ignoring child should not block the event loop")

    // The terminate itself must finish within the SIGKILL budget plus
    // a comfortable margin.
    XCTAssertEqual(
      terminateGroup.wait(timeout: .now() + .seconds(3)),
      .success,
      "terminate of HUP-ignoring child did not complete within 3 s")

    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Ring symlink hardening

  /// `labpty_byte_ring_create` previously opened the predictable
  /// `labpty-N.br` path with `O_RDWR|O_CREAT|O_TRUNC` — `open(2)`
  /// follows symlinks, so a same-uid attacker who pre-staged a
  /// symlink at the predictable next-handle path could trick the
  /// daemon into truncating an arbitrary writable file owned by the
  /// user when the next session opened. `open_ring_backing` now uses
  /// `O_EXCL|O_NOFOLLOW` and refuses any pre-existing non-regular
  /// path. The ring file is the daemon's data, not the symlink
  /// target's.
  func testPreexistingRingSymlinkIsRefusedAndDoesNotClobberTarget() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)

    // The first session opens with handle = 1 (registry next_handle
    // initializes to 1). Pre-stage a symlink at that exact path
    // pointing at a sentinel file we own. If the open follows the
    // link the daemon will truncate the sentinel.
    let shmDirURL = URL(fileURLWithPath: harness.shmDir)
    let target = shmDirURL.deletingLastPathComponent()
      .appendingPathComponent("do-not-clobber-\(UUID().uuidString).txt")
    let sentinel = "sentinel-payload-must-survive"
    try Data(sentinel.utf8).write(to: target)

    let attackPath = shmDirURL.appendingPathComponent("labpty-1.br").path
    let attackPathCString = (attackPath as NSString).utf8String!
    let targetPathCString = (target.path as NSString).utf8String!
    XCTAssertEqual(symlink(targetPathCString, attackPathCString), 0)

    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    XCTAssertThrowsError(
      try client.openSession(
        LabptyOpenSessionRequest(
          rows: 24,
          cols: 80,
          argv: ["/bin/sleep", "1"],
          logicalSessionId: "symlink-attack")),
      "openSession must fail when the ring path is a symlink to a foreign target")

    // The sentinel must be untouched; otherwise the daemon followed
    // the symlink and clobbered it.
    let postContents = try String(contentsOf: target, encoding: .utf8)
    XCTAssertEqual(postContents, sentinel)
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - UTF-8 validation for descriptor strings

  /// `labpty_protocol.c::read_string` accepts any non-NUL bytes, but
  /// Swift's `LabptyPayloadReader.readString` decodes UTF-8 strictly.
  /// Without daemon-side UTF-8 validation a raw same-uid client could
  /// open a session with a non-UTF-8 `logical_id` (e.g. a single
  /// 0xFF byte); every subsequent `listLabptySessions` from the
  /// first-party Swift client would then throw `invalidUTF8` on the
  /// whole response, breaking the only first-party catalog reader
  /// until the bad session was terminated.
  func testInvalidUTF8LogicalIdIsRejectedAndCannotPoisonListSessions() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)

    let fd = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(fd) }

    // Negotiate the connection so the daemon will dispatch our open.
    let helloPayload = try LabptyHelloRequest(clientId: "utf8-rejector").encode()
    try writeAllRaw(
      fd: fd,
      data: try LabptyFraming.encodeRequest(
        operation: .hello, sequence: 1, payload: helloPayload))
    let helloResp = try readFrameRaw(fd: fd)
    XCTAssertEqual(helloResp.header.responseCode, .ok)

    // Hand-build an open_session payload with a non-UTF-8 logical_id.
    // We can't go through LabptyOpenSessionRequest.encode because the
    // Swift String would enforce UTF-8 before the daemon ever sees
    // the bytes — the wire format is what we need to exercise.
    var open = [UInt8]()
    open.appendUInt32(24)   // rows
    open.appendUInt32(80)   // cols
    open.appendUInt64(UInt64(LabptyByteRingLayout.defaultOutputRingCapacity))
    // argv ["/bin/sleep", "1"]
    open.appendUInt32(2)
    let argv0 = Array("/bin/sleep".utf8)
    open.appendUInt32(UInt32(argv0.count))
    open.append(contentsOf: argv0)
    let argv1 = Array("1".utf8)
    open.appendUInt32(UInt32(argv1.count))
    open.append(contentsOf: argv1)
    // envp empty
    open.appendUInt32(0)
    // cwd empty
    open.appendUInt32(0)
    // logical_id = single 0xFF byte: no NUL (clears the existing
    // memchr guard), but not a valid UTF-8 sequence.
    open.appendUInt32(1)
    open.append(0xff)

    try writeAllRaw(
      fd: fd,
      data: try LabptyFraming.encodeRequest(
        operation: .openSession, sequence: 2, payload: Data(open)))
    let openResp = try readFrameRaw(fd: fd)
    XCTAssertNotEqual(
      openResp.header.responseCode, .ok,
      "non-UTF-8 logical_id must be rejected before reaching the registry")

    // The session catalog stayed clean; a normal Swift client can
    // still listLabptySessions without tripping invalidUTF8.
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    XCTAssertNoThrow(try client.listLabptySessions())
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - writeInput backpressure semantics

  /// `Sources/Labpty/main.c::handle_write` writes the full payload to
  /// the PTY master under a 100 ms wall-clock budget and returns
  /// `LABPTY_OK` once `write(2)` has returned `request.len` bytes. The
  /// Phase 1 protocol design (`execplans/active/labpty-protocol-design.md`
  /// §"Backpressure") promises that `writeInput` is synchronous and
  /// that returning ok means the bytes reached the master.
  ///
  /// Under canonical-mode backpressure that contract leaks: when the
  /// slave's canonical line buffer fills (MAX_CANON, ~1 KiB on macOS,
  /// with `IMAXBEL` set in `init_sane_termios`), the line discipline
  /// silently **drops** further bytes — but the master `write(2)`
  /// still returns the full count, so `handle_write` reports
  /// `LABPTY_OK`. The caller sees success; the child sees ~1 KiB.
  /// Echoes flow back to the master read side, where labpty drains
  /// them into the byte ring — that ring is the only signal a caller
  /// has that bytes actually reached the slave.
  ///
  /// This test pins the property a year-horizon caller needs: when
  /// `writeInput` returns ok, the slave must have observed the full
  /// payload. Today it fails (echoed ≈ MAX_CANON of 65536), which is
  /// the correct, loud surface for the bug. Fixing it likely means
  /// having `handle_write` poll the slave-side queue with a deadline,
  /// or returning a delivered-count to the client. Either way, this
  /// test should drive the change — do not soften the assertion to
  /// match current behavior without an ADR.
  ///
  /// Secondary properties pinned here:
  /// - the daemon survives the abuse (no event-loop wedge, no crash);
  /// - subsequent RPCs on the same control connection still work.
  func testWriteInputOkPromisesDeliveryAndDaemonSurvivesBackpressure() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "60"],
        logicalSessionId: "writeinput-backpressure"))
    defer { _ = try? client.terminate(handle: descriptor.ptyHandle) }

    // 64 KiB — the Phase 1 writeInput payload ceiling
    // (`LabptyProtocolLimits.maxWriteInputBytes`). The child never
    // reads stdin, so any bytes the line discipline rejects are gone.
    let payloadByte: UInt8 = 0x41  // 'A' — printable, ICANON+ECHO echoes 1:1
    let payload = [UInt8](repeating: payloadByte, count: 64 * 1024)

    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    var writeError: Error?
    do {
      try client.writeInput(handle: descriptor.ptyHandle, bytes: payload)
    } catch {
      writeError = error
    }

    XCTAssertTrue(
      harness.process.isRunning, "daemon must survive backpressure on writeInput")

    let result = drainEchoes(
      reader: reader, expecting: payloadByte, maxWait: 1.5)

    if writeError == nil {
      // Daemon reported success. The Phase 1 contract says synchronous
      // ok means the bytes reached the master; in practice a caller
      // can only verify "reached the slave" via the echo stream. If
      // ICANON drops bytes past MAX_CANON, this fails LOUDLY.
      XCTAssertGreaterThanOrEqual(
        result.matchingCount, payload.count - 256,
        "writeInput returned ok but only \(result.matchingCount) of "
          + "\(payload.count) payload bytes were observed at the slave "
          + "(total ring bytes=\(result.totalCount)). Phase 1 contract "
          + "says ok ⇒ delivered; canonical-mode line discipline (MAX_CANON, "
          + "IMAXBEL) is silently dropping the tail. Fix `handle_write` to "
          + "either honor delivery to the slave queue or surface a partial-"
          + "delivery error code; do not relax this assertion.")
    } else {
      // Daemon reported an error. Then the operation must NOT have
      // committed a prefix that the caller will see on the next retry
      // (i.e. atomic semantics under failure). If echoes > 0, the
      // partial write is observable and a retry would duplicate.
      XCTAssertEqual(
        result.matchingCount, 0,
        "writeInput failed (\(writeError!)) but \(result.matchingCount) "
          + "payload bytes already reached the slave — non-atomic semantics; "
          + "a caller-side retry would duplicate the prefix. Either fix "
          + "`handle_write` to commit all-or-nothing, or document the partial-"
          + "delivery contract in ADR 0007 and update this test.")
    }

    // Daemon stays responsive after the abuse.
    XCTAssertNoThrow(try client.listLabptySessions())
  }

  /// Companion to the preceding test. After ADR 0008, an oversized
  /// canonical-mode write is rejected with a typed `inputBackpressure`
  /// error before any byte reaches the master — `Sources/Labpty/main.c::
  /// handle_write` runs a preflight admission check against
  /// MAX_INPUT/MAX_CANON. This test pins the typed-error surface so a
  /// future "let's just rename the code" refactor cannot quietly fold
  /// backpressure back into a generic internal error and re-introduce
  /// the ambiguity callers had before the ADR.
  func testWriteInputBackpressureSurfacesTypedError() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "60"],
        logicalSessionId: "writeinput-backpressure-typed"))
    defer { _ = try? client.terminate(handle: descriptor.ptyHandle) }

    let payload = [UInt8](repeating: 0x42, count: 64 * 1024)

    do {
      try client.writeInput(handle: descriptor.ptyHandle, bytes: payload)
      XCTFail("expected LabptyResponseError(.inputBackpressure), got ok")
    } catch let error as LabptyResponseError {
      XCTAssertEqual(
        error.code, .inputBackpressure,
        "writeInput must reject oversized canonical-mode payloads with the "
          + "typed .inputBackpressure code (ADR 0008). Got code=\(error.code) "
          + "rawCode=\(error.rawCode) message=\(error.message). Generic "
          + "internalError flattening means future callers cannot distinguish "
          + "backpressure from a real daemon fault.")
    } catch {
      XCTFail(
        "expected LabptyResponseError, got \(type(of: error)): \(error). "
          + "Non-OK responses must surface as the typed LabptyResponseError "
          + "so callers can pattern-match on code.")
    }

    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)
    let result = drainEchoes(reader: reader, expecting: 0x42, maxWait: 0.5)
    XCTAssertEqual(
      result.matchingCount, 0,
      "backpressure rejection must be externally atomic: no payload byte "
        + "may reach the slave. Found \(result.matchingCount) echoed.")
    XCTAssertNoThrow(try client.listLabptySessions())
  }

  private struct EchoDrain {
    var totalCount: Int
    var matchingCount: Int
  }

  /// Drains the byte ring until it stops growing for ~250 ms or
  /// `maxWait` elapses. Returns the total byte count plus the count of
  /// bytes equal to `expecting`. The total tells us whether labpty is
  /// still producing echoes; the matching count tells us how many of
  /// our payload bytes the line discipline actually accepted.
  private func drainEchoes(
    reader: LabptyByteRingReader,
    expecting: UInt8,
    maxWait: TimeInterval
  ) -> EchoDrain {
    let deadline = Date().addingTimeInterval(maxWait)
    var offset: UInt64 = 0
    var data = Data()
    var lastGrowth = Date()
    while Date() < deadline {
      let result = reader.readSince(offset)
      offset = result.newOffset
      if !result.bytes.isEmpty {
        data.append(result.bytes)
        lastGrowth = Date()
      } else if Date().timeIntervalSince(lastGrowth) > 0.25 {
        break
      }
      usleep(10_000)
    }
    let matching = data.reduce(0) { $0 + ($1 == expecting ? 1 : 0) }
    return EchoDrain(totalCount: data.count, matchingCount: matching)
  }

  // MARK: - Coverage-driven edge cases (drive daemon MC/DC up)

  func testOpenWithEmptyLogicalIdGetsSyntheticId() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    // An empty logical id exercises make_logical_id's default branch
    // (snprintf "labpty-<handle>") instead of the requested-id branch.
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sleep", "30"], logicalSessionId: ""))
    XCTAssertTrue(descriptor.logicalSessionId.hasPrefix("labpty-"),
      "daemon must synthesize an id, got \(descriptor.logicalSessionId)")
    _ = try? client.terminate(handle: descriptor.ptyHandle)
    XCTAssertTrue(harness.process.isRunning)
  }

  func testInvalidOutputCapacityIsRejected() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    // Each value flips a distinct condition of valid_output_capacity
    // (>= MIN && <= MAX && power-of-two) to false *independently*, which is
    // what MC/DC requires: 300000 is in range but not a power of two (only it
    // reaches and fails the power-of-two test); 1024 is a power of two below
    // the 256 KiB minimum; 128 MiB is a power of two above the 64 MiB maximum.
    for cap: UInt64 in [300_000, 1024, 128 * 1024 * 1024] {
      XCTAssertThrowsError(
        try client.openSession(LabptyOpenSessionRequest(
          rows: 24, cols: 80, outputRingCapacity: cap,
          argv: ["/bin/sleep", "30"], logicalSessionId: "badcap-\(cap)")),
        "capacity \(cap) must be rejected")
    }
    XCTAssertTrue(harness.process.isRunning)
  }

  func testSignalReachesLiveSessionThenErrorsAfterTerminate() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sleep", "30"], logicalSessionId: "signal-target"))
    // SIGCONT is harmless but drives handle_signal's live-session success
    // path (session found, alive, killpg succeeds).
    XCTAssertNoThrow(try client.signal(handle: descriptor.ptyHandle, signal: Int32(SIGCONT)))
    _ = try client.terminate(handle: descriptor.ptyHandle)
    // A terminated session is no longer alive, so handle_signal's
    // `!session->alive` guard must reject it rather than touch a dead slot.
    XCTAssertThrowsError(try client.signal(handle: descriptor.ptyHandle, signal: Int32(SIGCONT)))
    XCTAssertTrue(harness.process.isRunning)
  }

  func testTerminateHupIgnoringChildEscalatesToSigkill() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    // A child that ignores SIGHUP forces the reap tick's SIGKILL-escalation
    // path: labpty_registry_reap's deadline + sigkill_sent conditions.
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80,
        argv: ["/bin/sh", "-c", "trap '' HUP; sleep 30"],
        logicalSessionId: "hup-ignorer"))
    _ = try client.terminate(handle: descriptor.ptyHandle)
    // SIGHUP is ignored; after the budget the reap escalates to SIGKILL and
    // reaps. The child must end up dead and the daemon must survive.
    try waitForDead(pid: pid_t(descriptor.childPid))
    XCTAssertTrue(harness.process.isRunning)
  }

  func testNaturalChildExitDeadLeakIsReclaimedOnReopen() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    // Open a child that exits on its own and do NOT terminate it: the reap
    // tick folds the slot into a dead leak (used, !alive, child=none,
    // close_pending=0). Reopening the same id must reclaim it through
    // is_reclaimable_dead_session, not fail SESSION_ID_IN_USE.
    let first = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sh", "-c", "exit 0"],
        logicalSessionId: "dead-leak"))
    try waitForDead(pid: pid_t(first.childPid))
    usleep(300_000) // let the reap tick fold the zombie into a dead leak
    let second = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sleep", "30"],
        logicalSessionId: "dead-leak"))
    XCTAssertNotEqual(second.ptyHandle, first.ptyHandle)
    _ = try? client.terminate(handle: second.ptyHandle)
    XCTAssertTrue(harness.process.isRunning)
  }

  func testWriteInputWithCanonicalNewlinesIsAccepted() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/cat"], logicalSessionId: "canon-write"))
    // Newline-delimited bytes drive is_canonical_delimiter's '\n' branch and
    // handle_write's canonical-pending accounting (ADR 0008 preflight).
    XCTAssertNoThrow(try client.writeInput(
      handle: descriptor.ptyHandle, bytes: [UInt8]("echo one\necho two\n".utf8)))
    _ = try? client.terminate(handle: descriptor.ptyHandle)
    XCTAssertTrue(harness.process.isRunning)
  }

  // MARK: - Harness (shared style with LabptyDaemonTests)

  private struct Harness {
    let socketPath: String
    let shmDir: String
    let process: Process
  }

  private func launchHarness() throws -> Harness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "labpty-adversarial-\(UUID().uuidString)"
    let tempRoot = ".tmp/\(runId)"
    let shmDir = "\(tempRoot)/shm"
    tempRoots.append(root.appendingPathComponent(tempRoot, isDirectory: true))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(shmDir),
      withIntermediateDirectories: true)
    let socketPath = "\(tempRoot)/s.sock"
    let executable = root.appendingPathComponent(".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("build labpty first: swift build --product labpty")
    }
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--shm-dir", shmDir]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    launched.append(process)
    return Harness(socketPath: socketPath, shmDir: shmDir, process: process)
  }

  private func waitForClient(socketPath: String) throws -> LabptyTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        do {
          let client = try LabptyTerminalSessionClient(socketPath: socketPath)
          _ = try client.hello()
          return client
        } catch {
          lastError = error
        }
      }
      usleep(50_000)
    }
    if let lastError { throw lastError }
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForSocketFile(socketPath: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) { return }
      usleep(50_000)
    }
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForDead(pid: pid_t) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if Darwin.kill(pid, 0) != 0 && errno == ESRCH { return }
      usleep(50_000)
    }
    XCTFail("pid \(pid) was still alive")
  }

  private func waitForSocketClosed(fd: Int32) throws {
    let deadline = Date().addingTimeInterval(3)
    var byte: UInt8 = 0
    while Date() < deadline {
      let n = Darwin.read(fd, &byte, 1)
      if n == 0 { return }
      if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        usleep(20_000)
        continue
      }
      if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    XCTFail("daemon did not disconnect stalled socket")
  }

  private func connectRaw(socketPath: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      for index in 0..<pathBytes.count {
        ptr.advanced(by: index).pointee = pathBytes[index]
      }
    }
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let err = errno
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
    return fd
  }

  private func writeAllRaw(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
  }

  private func readExactRaw(fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    let deadline = Date().addingTimeInterval(3)
    while offset < count {
      let n = data.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(fd, base.advanced(by: offset), count - offset)
      }
      if n == 0 { throw POSIXError(.ECONNRESET) }
      if n < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          if Date() > deadline { throw POSIXError(.ETIMEDOUT) }
          usleep(10_000)
          continue
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
    return data
  }

  private func readFrameRaw(fd: Int32) throws -> LabptyFrame {
    let header = try readExactRaw(fd: fd, count: LabptyFrameHeader.headerByteCount)
    let headerBytes = [UInt8](header)
    let totalLength = Int(
      UInt32(headerBytes[8])
        | (UInt32(headerBytes[9]) << 8)
        | (UInt32(headerBytes[10]) << 16)
        | (UInt32(headerBytes[11]) << 24))
    guard totalLength >= LabptyFrameHeader.headerByteCount else {
      throw LabptyProtocolError.truncatedFrame
    }
    let body = try readExactRaw(fd: fd, count: totalLength - LabptyFrameHeader.headerByteCount)
    return try LabptyFraming.decode(header + body)
  }
}

// Local extensions on Array<UInt8> to mirror the appendUInt* helpers
// used elsewhere in the test bundle without pulling in extra deps.
extension Array where Element == UInt8 {
  fileprivate mutating func appendUInt16(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
  }
  fileprivate mutating func appendUInt32(_ value: UInt32) {
    for shift in stride(from: 0, through: 24, by: 8) {
      append(UInt8((value >> shift) & 0xFF))
    }
  }
  fileprivate mutating func appendUInt64(_ value: UInt64) {
    for shift in stride(from: 0, through: 56, by: 8) {
      append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
  }
}
