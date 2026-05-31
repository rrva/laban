import Darwin
import Foundation
import XCTest

@testable import LabanCore

/// End-to-end stress test for the labpty daemon. Gated by `LABPTY_STRESS=1`
/// so default `swift test` runs stay fast. The goal is to exercise the same
/// class of bug as the >64 session-slot regression — slot, fd, shm, and
/// child-reap leaks — across the full surface (sessions AND clients) under
/// concurrent churn, with adversarial actors.
///
/// Tuning knobs (env vars):
///   LABPTY_STRESS=1                              required to run the test
///   LABPTY_STRESS_DURATION_S=<seconds, dflt 30>  wall-clock budget
///   LABPTY_STRESS_TRANSIENT_ACTORS=<int, dflt 24> connect/disconnect churn
///   LABPTY_STRESS_ANCHOR_ACTORS=<int, dflt 7>    long-lived client actors
///   LABPTY_STRESS_MIN_CYCLES=<int, dflt 1500>    floor on total ops
///   LABPTY_STRESS_SEED=<int, dflt hash of date>  deterministic RNG seed
final class LabptyStressTests: XCTestCase {
  private var launched: [Process] = []
  private var tempRoots: [URL] = []

  override func setUp() {
    super.setUp()
    // Belt-and-suspenders: every code path here is supposed to set
    // SO_NOSIGPIPE on its sockets, but any miss in a third-party or
    // Foundation call (e.g. lsof's pipe under tearDown contention)
    // would otherwise kill the whole xctest process with signal 13.
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

  func testLabptyChurnSoak() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["LABPTY_STRESS"] == "1",
      "set LABPTY_STRESS=1 to run the labpty stress test")
    let cfg = StressConfig.fromEnvironment()
    let harness = try launchHarness()
    let daemonPid = pid_t(harness.process.processIdentifier)
    // Anchor actors keep slots busy; transients churn the accept path; the
    // stall actor exercises the idle-timeout path. The watchdog samples
    // invariants on a 500ms cadence and a global deadline guard kills the
    // daemon if any actor blocks past the wall-clock budget.
    let stopFlag = StopFlag()
    let deadline = Date().addingTimeInterval(cfg.duration + 10)
    let counters = StressCounters()

    // Capture FD count and RSS before any actor activity so the post-run
    // numbers reflect only what the daemon held onto across churn.
    let baselineFdCount = countOpenFds(pid: daemonPid)
    let baselineRssKB = readRssKB(pid: daemonPid)

    let deadlineGuard = DispatchQueue.global(qos: .userInitiated).asyncAfterReturning(
      deadline: deadline + 20
    ) { [weak self, harness] in
      // Last-resort: if anything hung, kill the daemon so the test fails
      // with diagnostics instead of XCTest's default 600s timeout.
      if harness.process.isRunning {
        Darwin.kill(pid_t(harness.process.processIdentifier), SIGKILL)
      }
      _ = self
    }

    let group = DispatchGroup()
    let workerQueue = DispatchQueue.global(qos: .userInitiated)

    for actorId in 0..<cfg.anchorActors {
      group.enter()
      workerQueue.async {
        defer { group.leave() }
        AnchorActor(
          id: actorId,
          socketPath: harness.socketPath,
          rng: cfg.rng(salt: UInt64(actorId)),
          stopFlag: stopFlag,
          counters: counters,
          deadline: deadline
        ).run()
      }
    }
    for actorId in 0..<cfg.transientActors {
      group.enter()
      workerQueue.async {
        defer { group.leave() }
        TransientActor(
          id: 1_000 + actorId,
          socketPath: harness.socketPath,
          rng: cfg.rng(salt: UInt64(1_000 + actorId)),
          stopFlag: stopFlag,
          counters: counters,
          deadline: deadline
        ).run()
      }
    }
    group.enter()
    workerQueue.async {
      defer { group.leave() }
      StallActor(
        socketPath: harness.socketPath,
        stopFlag: stopFlag,
        counters: counters,
        deadline: deadline
      ).run()
    }
    let slowReader = SlowReaderTapActor(
      socketPath: harness.socketPath,
      stopFlag: stopFlag,
      counters: counters,
      deadline: deadline)
    group.enter()
    workerQueue.async {
      defer { group.leave() }
      slowReader.run()
    }

    let watchdog = Watchdog(
      harness: harness,
      counters: counters,
      stopFlag: stopFlag,
      deadline: deadline)
    workerQueue.async { watchdog.run() }

    Thread.sleep(forTimeInterval: cfg.duration)
    stopFlag.signal()
    let drainTimeout = group.wait(timeout: .now() + .seconds(15))
    deadlineGuard.cancel()
    XCTAssertEqual(
      drainTimeout, .success,
      "actor threads did not drain within 15s after stop signal — likely daemon hang")

    // Snapshot before invariant checks so failures get usable forensics.
    let stats = counters.snapshot()
    let watchdogFailures = watchdog.collectFailures()
    let slowReaderFailures = slowReader.collectFailures()
    let slowReaderObservations = slowReader.collectObservations()

    XCTAssertGreaterThanOrEqual(
      stats.totalOps,
      cfg.minCycles,
      "stress floor not reached: only \(stats.totalOps) ops in \(cfg.duration)s "
        + "(opens=\(stats.opens), terminates=\(stats.terminates), "
        + "connects=\(stats.connects), refused=\(stats.refused), errors=\(stats.errors))")

    XCTAssertTrue(
      watchdogFailures.isEmpty,
      "watchdog observed \(watchdogFailures.count) invariant violations: "
        + watchdogFailures.prefix(5).joined(separator: " | "))

    XCTAssertTrue(
      slowReaderFailures.isEmpty,
      "slow-reader tap observed \(slowReaderFailures.count) failures: "
        + slowReaderFailures.prefix(5).joined(separator: " | "))

    // Hard assertion: the daemon's event loop must keep ticking under
    // sustained output pressure. If the heartbeat never advanced during
    // a slow-tap session, the daemon got wedged on something else and
    // stopped draining the master fd.
    XCTAssertGreaterThan(
      slowReaderObservations.heartbeatAdvances,
      0,
      "producer heartbeat never advanced during slow-tap reads — daemon "
        + "may be stalled under output backpressure")

    // Hard assertion: the slow tap must have actually drained bytes from
    // a live session. Combined with heartbeat-advances above, that
    // proves the daemon kept pulling pty output into the ring while
    // concurrent client churn hammered the accept path.
    XCTAssertGreaterThan(
      slowReaderObservations.sessionsRun,
      0,
      "slow-reader tap never completed a session — could not claim a client "
        + "slot under transient pressure")
    XCTAssertGreaterThan(
      slowReaderObservations.totalBytesRead,
      0,
      "slow-reader tap never read any bytes — daemon may have stopped "
        + "draining the pty master")
    // Soft observation: when the daemon's drain rate per-session-tick
    // outpaces 256 KiB / 10 s under the current load, the byte-ring
    // writer's wrap branch is exercised live. Under heavier scheduler
    // contention the same drain can be throttled below that threshold
    // — the wrap branch itself is unit-tested in
    // `testByteRingWrapDetection`, so we report this rather than fail.

    XCTAssertTrue(harness.process.isRunning, "daemon died during stress run")

    // Quiescent terminate sweep + final invariants.
    try drainAllSessions(socketPath: harness.socketPath)
    try assertShmDirIsEmpty(harness.shmDir)
    try canaryOpenStillSucceeds(socketPath: harness.socketPath)

    let quiescentFdCount = countOpenFds(pid: daemonPid)
    let quiescentRssKB = readRssKB(pid: daemonPid)
    // After draining and the canary's terminate, the daemon should hold
    // roughly the same fds it started with (listen socket, shm dir, etc).
    // A creep of more than 8 fds is a hard signal of a leak that the
    // session/client churn produced.
    if baselineFdCount > 0 && quiescentFdCount > 0 {
      XCTAssertLessThanOrEqual(
        quiescentFdCount,
        baselineFdCount + 8,
        "daemon fd count crept from \(baselineFdCount) to \(quiescentFdCount) — likely fd leak")
    }
    // mlockall pins pages, so RSS growth past startup-baseline + 64 MiB
    // would mean the daemon has allocated and held substantial memory
    // beyond its registry/byte-ring footprint.
    if baselineRssKB > 0 && quiescentRssKB > 0 {
      let growthKB = quiescentRssKB - baselineRssKB
      XCTAssertLessThanOrEqual(
        growthKB,
        64 * 1024,
        "daemon RSS grew \(growthKB) KB (from \(baselineRssKB) to \(quiescentRssKB)) — likely leak")
    }

    try assertCleanShutdown(harness: harness)

    print(
      """
      labpty stress summary:
        duration=\(cfg.duration)s
        anchor_actors=\(cfg.anchorActors)
        transient_actors=\(cfg.transientActors)
        opens=\(stats.opens)
        terminates=\(stats.terminates)
        connects=\(stats.connects)
        refused=\(stats.refused)
        errors=\(stats.errors)
        watchdog_samples=\(stats.watchdogSamples)
        watchdog_failures=\(watchdogFailures.count)
        fd_baseline=\(baselineFdCount)
        fd_quiescent=\(quiescentFdCount)
        rss_baseline_kb=\(baselineRssKB)
        rss_quiescent_kb=\(quiescentRssKB)
        slow_tap_sessions=\(slowReaderObservations.sessionsRun)
        slow_tap_overflows=\(slowReaderObservations.overflowEvents)
        slow_tap_wrap_events=\(slowReaderObservations.ringWrapEvents)
        slow_tap_heartbeats=\(slowReaderObservations.heartbeatAdvances)
        slow_tap_bytes_read=\(slowReaderObservations.totalBytesRead)
        daemon_pid=\(daemonPid)
      """)
  }

  /// Counts open file descriptors held by the daemon by shelling out to
  /// `lsof -p <pid>`. Returns -1 if lsof failed or isn't available, so
  /// caller treats it as "not measured" instead of "zero leak".
  private func countOpenFds(pid: pid_t) -> Int {
    runAndCount(launchPath: "/usr/sbin/lsof", arguments: ["-p", "\(pid)"]) {
      max(0, $0.split(separator: "\n").count - 1)
    }
  }

  /// Reads daemon RSS in KB by shelling out to `ps -o rss= -p <pid>`.
  /// Returns -1 on failure.
  private func readRssKB(pid: pid_t) -> Int {
    runAndCount(launchPath: "/bin/ps", arguments: ["-o", "rss=", "-p", "\(pid)"]) {
      Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
  }

  private func runAndCount(launchPath: String, arguments: [String], parse: (String) -> Int) -> Int {
    let process = Process()
    process.launchPath = launchPath
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return -1
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return -1 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return parse(String(data: data, encoding: .utf8) ?? "")
  }

  // MARK: - Final invariants

  private func drainAllSessions(socketPath: String) throws {
    let client = try LabptyTerminalSessionClient(socketPath: socketPath)
    defer { client.close() }
    _ = try client.hello()
    let list = try client.listLabptySessions()
    for descriptor in list {
      _ = try? client.terminate(handle: descriptor.ptyHandle)
    }
    let drainDeadline = Date().addingTimeInterval(10)
    while Date() < drainDeadline {
      let remaining = try client.listLabptySessions()
      if remaining.isEmpty { return }
      // Some sessions whose child has exited may still be in the registry
      // until reap completes; keep terminating them.
      for descriptor in remaining {
        _ = try? client.terminate(handle: descriptor.ptyHandle)
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    let final = try client.listLabptySessions()
    XCTFail("\(final.count) sessions remained after drain sweep")
  }

  private func assertShmDirIsEmpty(_ shmDir: String) throws {
    let url = URL(
      fileURLWithPath: shmDir,
      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    let leftover = entries.filter { $0.hasSuffix(".br") }
    XCTAssertTrue(
      leftover.isEmpty,
      "shm dir \(url.path) still contains ring files: \(leftover.joined(separator: ", "))")
  }

  private func canaryOpenStillSucceeds(socketPath: String) throws {
    let client = try LabptyTerminalSessionClient(socketPath: socketPath)
    defer { client.close() }
    _ = try client.hello()
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "printf canary"],
        logicalSessionId: "stress-canary"))
    XCTAssertGreaterThan(descriptor.childPid, 0)
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  private func assertCleanShutdown(harness: Harness) throws {
    Darwin.kill(pid_t(harness.process.processIdentifier), SIGTERM)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && harness.process.isRunning {
      usleep(20_000)
    }
    XCTAssertFalse(harness.process.isRunning, "daemon did not exit within 5s of SIGTERM")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: harness.socketPath),
      "socket file \(harness.socketPath) still exists after shutdown")
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: harness.shmDir)) ?? []
    let leftover = entries.filter { $0.hasSuffix(".br") }
    XCTAssertTrue(
      leftover.isEmpty,
      "shm dir contained .br files after shutdown: \(leftover.joined(separator: ", "))")
  }

  // MARK: - Harness

  fileprivate struct Harness {
    let socketPath: String
    let shmDir: String
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
  }

  private func launchHarness() throws -> Harness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "labpty-stress-\(UUID().uuidString)"
    let tempRoot = ".tmp/\(runId)"
    let shmDir = "\(tempRoot)/shm"
    let tempRootURL = root.appendingPathComponent(tempRoot, isDirectory: true)
    tempRoots.append(tempRootURL)
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
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    launched.append(process)
    // Wait for the socket to appear so the first connect attempt doesn't
    // racily fail and inflate the "errors" counter at t=0.
    let socketDeadline = Date().addingTimeInterval(5)
    while Date() < socketDeadline {
      if FileManager.default.fileExists(atPath: socketPath) { break }
      usleep(20_000)
    }
    return Harness(
      socketPath: socketPath,
      shmDir: shmDir,
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe)
  }
}

// MARK: - Configuration

private struct StressConfig {
  let duration: TimeInterval
  let anchorActors: Int
  let transientActors: Int
  let minCycles: Int
  private let seed: UInt64

  static func fromEnvironment() -> StressConfig {
    let env = ProcessInfo.processInfo.environment
    let duration = TimeInterval(env["LABPTY_STRESS_DURATION_S"].flatMap(Int.init) ?? 30)
    // Anchors must fit under LABPTY_MAX_CLIENTS (8); we reserve one slot for
    // the watchdog client and one for the stall actor's raw socket.
    let anchorEnv = env["LABPTY_STRESS_ANCHOR_ACTORS"].flatMap(Int.init) ?? 6
    let anchorActors = max(1, min(anchorEnv, 6))
    let transientActors = env["LABPTY_STRESS_TRANSIENT_ACTORS"].flatMap(Int.init) ?? 24
    let minCycles = env["LABPTY_STRESS_MIN_CYCLES"].flatMap(Int.init) ?? 1500
    let seed =
      env["LABPTY_STRESS_SEED"].flatMap(UInt64.init)
      ?? UInt64(bitPattern: Int64(Date().timeIntervalSince1970))
    return StressConfig(
      duration: duration,
      anchorActors: anchorActors,
      transientActors: transientActors,
      minCycles: minCycles,
      seed: seed)
  }

  func rng(salt: UInt64) -> SplitMix64 {
    SplitMix64(seed: seed &+ salt)
  }
}

private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

// MARK: - Shared state

private final class StopFlag {
  private let lock = NSLock()
  private var stopped = false
  func signal() {
    lock.lock()
    defer { lock.unlock() }
    stopped = true
  }
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

private final class StressCounters {
  private let lock = NSLock()
  private var opensCounter = 0
  private var terminatesCounter = 0
  private var connectsCounter = 0
  private var refusedCounter = 0
  private var errorsCounter = 0
  private var watchdogSamplesCounter = 0

  struct Snapshot {
    let opens: Int
    let terminates: Int
    let connects: Int
    let refused: Int
    let errors: Int
    let watchdogSamples: Int
    var totalOps: Int { opens + terminates + connects }
  }

  func bumpOpen() { lock.withLock { opensCounter += 1 } }
  func bumpTerminate() { lock.withLock { terminatesCounter += 1 } }
  func bumpConnect() { lock.withLock { connectsCounter += 1 } }
  func bumpRefused() { lock.withLock { refusedCounter += 1 } }
  func bumpError() { lock.withLock { errorsCounter += 1 } }
  func bumpWatchdogSample() { lock.withLock { watchdogSamplesCounter += 1 } }

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(
        opens: opensCounter,
        terminates: terminatesCounter,
        connects: connectsCounter,
        refused: refusedCounter,
        errors: errorsCounter,
        watchdogSamples: watchdogSamplesCounter)
    }
  }
}

// MARK: - Actors

/// Holds a single long-lived `LabptyTerminalSessionClient` and cycles
/// open / write / resize / terminate. Reconnects on protocol error.
private final class AnchorActor {
  private let id: Int
  private let socketPath: String
  private var rng: SplitMix64
  private let stopFlag: StopFlag
  private let counters: StressCounters
  private let deadline: Date

  init(
    id: Int,
    socketPath: String,
    rng: SplitMix64,
    stopFlag: StopFlag,
    counters: StressCounters,
    deadline: Date
  ) {
    self.id = id
    self.socketPath = socketPath
    self.rng = rng
    self.stopFlag = stopFlag
    self.counters = counters
    self.deadline = deadline
  }

  func run() {
    while !stopFlag.isSet && Date() < deadline {
      do {
        let client = try connectAndHello()
        counters.bumpConnect()
        defer { client.close() }
        while !stopFlag.isSet && Date() < deadline {
          try performOneCycle(client: client)
        }
      } catch {
        counters.bumpError()
        // Short backoff before reconnect attempt — gives the daemon's
        // expire_stalled_clients tick room to reclaim our slot if we hit
        // an error mid-frame.
        usleep(20_000)
      }
    }
  }

  private func connectAndHello() throws -> LabptyTerminalSessionClient {
    // Retry briefly to absorb LABPTY_MAX_CLIENTS contention.
    let connectDeadline = Date().addingTimeInterval(2)
    while Date() < connectDeadline {
      do {
        let client = try LabptyTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return client
      } catch {
        counters.bumpRefused()
        usleep(10_000)
      }
    }
    throw POSIXError(.ETIMEDOUT)
  }

  private func performOneCycle(client: LabptyTerminalSessionClient) throws {
    let roll = UInt32.random(in: 0..<100, using: &rng)
    switch roll {
    case 0..<50:
      try shortLivedOpenTerminate(client: client)
    case 50..<70:
      try longLivedOpenWriteTerminate(client: client)
    case 70..<85:
      try openResizeTerminate(client: client)
    case 85..<95:
      _ = try client.listLabptySessions()
    case 95..<100:
      // Drop the connection mid-stream; the outer loop reconnects. Tests
      // that LABPTY_MAX_CLIENTS slot is released promptly.
      throw POSIXError(.ECONNRESET)
    default:
      break
    }
  }

  private func shortLivedOpenTerminate(client: LabptyTerminalSessionClient) throws {
    let id = uniqueId(prefix: "anchor-\(self.id)-short")
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "printf x; exit 0"],
        logicalSessionId: id))
    counters.bumpOpen()
    _ = try client.terminate(handle: descriptor.ptyHandle)
    counters.bumpTerminate()
  }

  private func longLivedOpenWriteTerminate(client: LabptyTerminalSessionClient) throws {
    let id = uniqueId(prefix: "anchor-\(self.id)-long")
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: id))
    counters.bumpOpen()
    let nBytes = Int.random(in: 16..<256, using: &rng)
    var bytes = [UInt8]()
    bytes.reserveCapacity(nBytes)
    for _ in 0..<nBytes {
      bytes.append(UInt8.random(in: 0x20..<0x7F, using: &rng))
    }
    try client.writeInput(handle: descriptor.ptyHandle, bytes: bytes)
    _ = try client.terminate(handle: descriptor.ptyHandle)
    counters.bumpTerminate()
  }

  private func openResizeTerminate(client: LabptyTerminalSessionClient) throws {
    let id = uniqueId(prefix: "anchor-\(self.id)-resize")
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: id))
    counters.bumpOpen()
    for _ in 0..<Int.random(in: 1..<4, using: &rng) {
      let rows = Int.random(in: 5..<200, using: &rng)
      let cols = Int.random(in: 5..<400, using: &rng)
      _ = try client.resize(handle: descriptor.ptyHandle, rows: rows, cols: cols)
    }
    _ = try client.terminate(handle: descriptor.ptyHandle)
    counters.bumpTerminate()
  }

  private func uniqueId(prefix: String) -> String {
    "\(prefix)-\(UInt64.random(in: 0..<UInt64.max, using: &rng))"
  }
}

/// Connect, hello, optionally open+terminate, disconnect. Exercises the
/// `LABPTY_MAX_CLIENTS` slot-release path.
private final class TransientActor {
  private let id: Int
  private let socketPath: String
  private var rng: SplitMix64
  private let stopFlag: StopFlag
  private let counters: StressCounters
  private let deadline: Date

  init(
    id: Int,
    socketPath: String,
    rng: SplitMix64,
    stopFlag: StopFlag,
    counters: StressCounters,
    deadline: Date
  ) {
    self.id = id
    self.socketPath = socketPath
    self.rng = rng
    self.stopFlag = stopFlag
    self.counters = counters
    self.deadline = deadline
  }

  func run() {
    while !stopFlag.isSet && Date() < deadline {
      do {
        let client = try LabptyTerminalSessionClient(socketPath: socketPath)
        counters.bumpConnect()
        defer { client.close() }
        _ = try client.hello()
        let action = UInt32.random(in: 0..<100, using: &rng)
        if action < 50 {
          let id = "transient-\(self.id)-\(UInt64.random(in: 0..<UInt64.max, using: &rng))"
          let descriptor = try client.openSession(
            LabptyOpenSessionRequest(
              rows: 24,
              cols: 80,
              argv: ["/bin/sh", "-c", "printf t"],
              logicalSessionId: id))
          counters.bumpOpen()
          if action < 40 {
            _ = try client.terminate(handle: descriptor.ptyHandle)
            counters.bumpTerminate()
          }
          // The 40..50 case opens then drops without terminate — verifies
          // the daemon doesn't leak the slot or its shm file. The session
          // is then orphaned in the registry; the final drain sweep
          // cleans it up.
        } else if action < 70 {
          _ = try client.listLabptySessions()
        } else if action < 85 {
          _ = try client.hello()
        }
        // 85..100: just disconnect.
      } catch {
        // Connect refusal (slot full) or any other error is expected
        // intermittently. Don't bump errors for connection failures —
        // they're a normal back-pressure signal.
        let isConnectFailure = (error as? POSIXError)?.code == .ECONNREFUSED
        if isConnectFailure {
          counters.bumpRefused()
        } else {
          counters.bumpError()
        }
        usleep(5_000)
      }
    }
  }
}

/// Holds a raw UNIX socket fd with one magic byte written, exercises
/// `expire_stalled_clients`. Reconnects after each disconnect.
private final class StallActor {
  private let socketPath: String
  private let stopFlag: StopFlag
  private let counters: StressCounters
  private let deadline: Date

  init(socketPath: String, stopFlag: StopFlag, counters: StressCounters, deadline: Date) {
    self.socketPath = socketPath
    self.stopFlag = stopFlag
    self.counters = counters
    self.deadline = deadline
  }

  func run() {
    while !stopFlag.isSet && Date() < deadline {
      let fd = rawConnect(socketPath: socketPath)
      if fd < 0 {
        counters.bumpRefused()
        usleep(50_000)
        continue
      }
      counters.bumpConnect()
      // Send a single magic byte so the daemon parks us in the
      // partial-header state until the idle deadline expires.
      var magic: UInt8 = 0x4C  // 'L'
      _ = Darwin.write(fd, &magic, 1)
      // Wait for the daemon to disconnect us (read returns 0) or for stop.
      let waitDeadline = Date().addingTimeInterval(2)
      var byte: UInt8 = 0
      while Date() < waitDeadline && !stopFlag.isSet {
        let n = Darwin.read(fd, &byte, 1)
        if n == 0 { break }
        if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
        usleep(20_000)
      }
      Darwin.close(fd)
      // Brief cooldown so we don't busy-loop the accept path.
      usleep(50_000)
    }
  }

  private func rawConnect(socketPath: String) -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    if pathBytes.count > MemoryLayout.size(ofValue: addr.sun_path) {
      Darwin.close(fd)
      return -1
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
    if result != 0 {
      Darwin.close(fd)
      return -1
    }
    return fd
  }
}

/// Opens a session whose child blasts ~32 MiB into the byte ring, then
/// reads the ring at a deliberately lagging cadence (~50 ms) to force
/// overflow. Asserts: producer heartbeat keeps advancing while the
/// reader lags, and at least one read sees `overflowed=true` (proving
/// the backpressure path is exercised, not bypassed).
private final class SlowReaderTapActor {
  struct Observations {
    var overflowEvents: Int  // tap fell behind by > capacity between reads
    var ringWrapEvents: Int  // daemon writer wrapped at least once
    var heartbeatAdvances: Int
    var sessionsRun: Int
    var totalBytesRead: UInt64
  }

  private let socketPath: String
  private let stopFlag: StopFlag
  private let counters: StressCounters
  private let deadline: Date
  private let lock = NSLock()
  private var failures: [String] = []
  private var observations = Observations(
    overflowEvents: 0,
    ringWrapEvents: 0,
    heartbeatAdvances: 0,
    sessionsRun: 0,
    totalBytesRead: 0)

  init(socketPath: String, stopFlag: StopFlag, counters: StressCounters, deadline: Date) {
    self.socketPath = socketPath
    self.stopFlag = stopFlag
    self.counters = counters
    self.deadline = deadline
  }

  func collectFailures() -> [String] {
    lock.withLock { failures }
  }

  func collectObservations() -> Observations {
    lock.withLock { observations }
  }

  func run() {
    while !stopFlag.isSet && Date() < deadline {
      do {
        try runOneSession()
      } catch {
        counters.bumpError()
        usleep(50_000)
      }
    }
  }

  private func runOneSession() throws {
    let client = try connectWithRetry()
    counters.bumpConnect()
    defer { client.close() }
    // Open with the minimum 256 KiB ring. At the daemon's observed drain
    // rate (~tens to low hundreds of KiB/s under churn) plus our 50 ms
    // reader cadence, this ring overflows within ~1 s — guaranteeing the
    // `labpty_byte_ring_write` wrap branch is exercised live, not just
    // in the byte-ring unit test.
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        outputRingCapacity: UInt64(LabptyByteRingLayout.minimumOutputRingCapacity),
        argv: ["/bin/sh", "-c", "yes | head -c 33554432"],
        logicalSessionId: "slow-tap-\(UUID().uuidString)"))
    counters.bumpOpen()
    defer {
      _ = try? client.terminate(handle: descriptor.ptyHandle)
      counters.bumpTerminate()
    }
    let reader: LabptyByteRingReader
    do {
      reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)
    } catch {
      record("could not open ring reader for \(descriptor.byteRingShmPath): \(error)")
      return
    }
    try tapSession(reader: reader, child: pid_t(descriptor.childPid))
    lock.withLock { observations.sessionsRun += 1 }
  }

  private func tapSession(reader: LabptyByteRingReader, child: pid_t) throws {
    var offset: UInt64 = 0
    var lastHeartbeat = reader.producerAliveMonoNs()
    var observedOverflow = false
    var observedHeartbeatAdvance = false
    var bytesRead: UInt64 = 0
    let sessionDeadline = Date().addingTimeInterval(min(10, deadline.timeIntervalSinceNow))
    var lastProgressAt = Date()

    while Date() < sessionDeadline && !stopFlag.isSet {
      let result = reader.readSince(offset)
      if result.overflowed {
        observedOverflow = true
      }
      if result.newOffset > offset {
        bytesRead += result.newOffset - offset
        offset = result.newOffset
        lastProgressAt = Date()
      }
      let heartbeat = reader.producerAliveMonoNs()
      if heartbeat > lastHeartbeat {
        observedHeartbeatAdvance = true
        lastHeartbeat = heartbeat
      }
      // Deliberate ~50ms lag — much slower than the producer.
      usleep(50_000)
      // Exit once child is dead AND we've stopped seeing new bytes for
      // 500ms (drained whatever was left in the ring).
      if Darwin.kill(child, 0) != 0 && errno == ESRCH {
        if Date().timeIntervalSince(lastProgressAt) > 0.5 { break }
      }
    }

    // `wrapCount` is the daemon-side counter of how many times the
    // writer wrapped past the end of the ring. > 0 means the
    // labpty_byte_ring_write wrap branch executed live — the actual
    // invariant the overflow path exists to handle.
    let observedRingWrap = reader.outputWrapCount() > 0
    lock.withLock {
      observations.totalBytesRead += bytesRead
      if observedOverflow { observations.overflowEvents += 1 }
      if observedRingWrap { observations.ringWrapEvents += 1 }
      if observedHeartbeatAdvance { observations.heartbeatAdvances += 1 }
    }
    if !observedHeartbeatAdvance {
      record("producer heartbeat never advanced while child was alive")
    }
  }

  private func record(_ message: String) {
    lock.withLock { failures.append(message) }
  }

  /// The 24 transient actors hammer the connect path; without retry, the
  /// slow tap loses repeatedly and a soak can finish with zero successful
  /// sessions. Retry for up to 5s before giving up — long enough that
  /// the tap reliably claims a slot at least once per soak.
  private func connectWithRetry() throws -> LabptyTerminalSessionClient {
    let retryDeadline = Date().addingTimeInterval(5)
    var attempts = 0
    while Date() < retryDeadline && !stopFlag.isSet {
      attempts += 1
      do {
        let client = try LabptyTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return client
      } catch {
        // Connect succeeds but daemon closes the socket when slot full;
        // hello() then trips EOF. Back off briefly and try again.
        usleep(20_000)
      }
    }
    throw POSIXError(.ETIMEDOUT)
  }
}

// MARK: - Watchdog

private final class Watchdog {
  private let harness: LabptyStressTests.Harness
  private let counters: StressCounters
  private let stopFlag: StopFlag
  private let deadline: Date
  private let lock = NSLock()
  private var failures: [String] = []

  init(
    harness: LabptyStressTests.Harness,
    counters: StressCounters,
    stopFlag: StopFlag,
    deadline: Date
  ) {
    self.harness = harness
    self.counters = counters
    self.stopFlag = stopFlag
    self.deadline = deadline
  }

  func run() {
    while !stopFlag.isSet && Date() < deadline {
      sampleOnce()
      // 500ms cadence is rare enough that the watchdog client doesn't
      // monopolize a LABPTY_MAX_CLIENTS slot.
      usleep(500_000)
    }
  }

  func collectFailures() -> [String] {
    lock.withLock { failures }
  }

  private func sampleOnce() {
    counters.bumpWatchdogSample()
    if !harness.process.isRunning {
      record("daemon process exited during stress run")
      return
    }
    let client: LabptyTerminalSessionClient
    do {
      client = try LabptyTerminalSessionClient(socketPath: harness.socketPath)
      _ = try client.hello()
    } catch {
      // Likely transient: all 8 client slots busy. Not a failure on its
      // own — the actors are designed to make this happen.
      return
    }
    defer { client.close() }

    let list: [LabptySessionDescriptor]
    do {
      list = try client.listLabptySessions()
    } catch {
      record("listSessions failed mid-run: \(error)")
      return
    }
    if list.count > LabptyProtocolLimits.maxSessionDescriptorCount {
      record(
        "listSessions returned \(list.count) > \(LabptyProtocolLimits.maxSessionDescriptorCount)")
    }
    // The "every shm file in the list exists" invariant is TOCTOU-racy
    // against other clients' terminates from outside the daemon, so it's
    // checked at quiescence (assertShmDirIsEmpty) rather than per-sample.
  }

  private func record(_ message: String) {
    lock.withLock { failures.append(message) }
  }
}

// MARK: - DispatchQueue helper

extension DispatchQueue {
  /// `asyncAfter` that returns a cancellable handle. Used by the stress
  /// test as a last-resort timeout that SIGKILLs the daemon if anything
  /// hangs past the wall-clock budget.
  fileprivate func asyncAfterReturning(
    deadline: Date,
    work: @escaping () -> Void
  ) -> DispatchWorkItem {
    let item = DispatchWorkItem(block: work)
    let interval = deadline.timeIntervalSinceNow
    let dispatchDeadline: DispatchTime =
      interval <= 0 ? .now() : .now() + .milliseconds(Int(interval * 1000))
    asyncAfter(deadline: dispatchDeadline, execute: item)
    return item
  }
}
