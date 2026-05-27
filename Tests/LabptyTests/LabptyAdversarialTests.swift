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
