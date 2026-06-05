import Darwin
import Foundation
import LabanCore
import LabanTerminalCore

/// Microbench for the labpty producer hot path:
///
///   event_loop → drain_session(session)
///     → read(master_fd, buf, 4096)              [kernel]
///     → labpty_byte_ring_write(ring, buf, n)    [memcpy + 2× atomic store + clock_gettime]
///
/// Modes:
///
/// - `daemon-drain`         end-to-end. Spawn labpty, open one or more
///                          sessions whose child writes a fixed payload,
///                          drain each byte ring from a per-session
///                          consumer thread using `LabptyByteRingReader`.
///                          Reports aggregate producer throughput (MiB/s)
///                          and consumer per-read latency percentiles.
///                          The only mode that exercises the compiled C
///                          in the labpty daemon.
///
/// - `daemon-drain-noread`  producer-only end-to-end. Same daemon and
///                          sessions but consumers only sample
///                          `outputWriteOffset()` — no `readSince()`, no
///                          payload copy. Isolates the producer (kernel
///                          read + byte-ring write + heartbeat) from any
///                          consumer-side memcpy cost.
///
/// - `ring-write`           writer microbench against the Swift
///                          `LabptyByteRingWriter`. No kernel, no IPC,
///                          no daemon. NOTE: this is the Swift reimpl of
///                          the ring writer, not labpty's C. Useful as a
///                          floor measurement; not a substitute for
///                          `daemon-drain`.
///
/// Flags:
///   --sessions N           parallel session count for daemon modes (default 1)
///   --producer cat|zero    child command emitting the payload (default cat).
///                          `zero` runs `dd if=/dev/zero bs=64k count=512`.
///                          `flood` runs ~/laban-flood-output.sh for
///                          --flood-seconds and uses quiet-after-exit rather
///                          than a fixed byte threshold.
///   --top-outliers N       print the N slowest consumer reads per iter
///                          for daemon-drain (default 0)
///   --control-probe-interval-us N
///                          while daemon modes run, issue listSessions RPCs
///                          from a separate client every N microseconds and
///                          report control-plane latency percentiles.
///
/// Usage:
///   bench-labpty-hot-path                                # all modes, defaults
///   bench-labpty-hot-path daemon-drain                   # one mode
///   bench-labpty-hot-path --sessions 8 daemon-drain
///   bench-labpty-hot-path --producer zero daemon-drain
///
/// The daemon modes expect `.build/{debug,release}/labpty` to exist.
/// Build it first with `swift build --product labpty` (release for a
/// meaningful number).

private let payloadBytes = 32 * 1024 * 1024  // 32 MiB
private let iterations = 5
private let warmup = 1
private let outputRingCapacity: UInt64 = 8 * 1024 * 1024  // matches labpty default
private let ringWriteChunkBytes = 4096  // matches LABPTY_READ_BUFFER_BYTES

enum Mode: String, CaseIterable {
  case daemonDrain = "daemon-drain"
  case daemonDrainNoRead = "daemon-drain-noread"
  case ringWrite = "ring-write"
}

enum Producer: String {
  case cat
  case zero
  case flood
}

struct Options {
  var sessions: Int = 1
  var producer: Producer = .cat
  var floodSeconds: Int = 8
  var controlProbeIntervalUs: UInt32 = 0
  var topOutliers: Int = 0
  var modes: [Mode] = Mode.allCases
}

private func parseOptions(_ args: [String]) throws -> Options {
  var options = Options()
  var modesSpecified = false
  var i = 0
  while i < args.count {
    let arg = args[i]
    switch arg {
    case "--sessions":
      guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
        throw BenchError("--sessions requires a positive integer")
      }
      options.sessions = value
      i += 2
    case "--producer":
      guard i + 1 < args.count, let value = Producer(rawValue: args[i + 1]) else {
        throw BenchError("--producer must be cat, zero, or flood")
      }
      options.producer = value
      i += 2
    case "--flood-seconds":
      guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
        throw BenchError("--flood-seconds requires a positive integer")
      }
      options.floodSeconds = value
      i += 2
    case "--control-probe-interval-us":
      guard i + 1 < args.count, let value = UInt32(args[i + 1]), value > 0 else {
        throw BenchError("--control-probe-interval-us requires a positive integer")
      }
      options.controlProbeIntervalUs = value
      i += 2
    case "--top-outliers":
      guard i + 1 < args.count, let value = Int(args[i + 1]), value >= 0 else {
        throw BenchError("--top-outliers requires a non-negative integer")
      }
      options.topOutliers = value
      i += 2
    default:
      guard let mode = Mode(rawValue: arg) else {
        let valid = Mode.allCases.map(\.rawValue).joined(separator: ", ")
        throw BenchError("unknown argument: \(arg). valid modes: \(valid)")
      }
      if !modesSpecified {
        options.modes = []
        modesSpecified = true
      }
      options.modes.append(mode)
      i += 1
    }
  }
  return options
}

private func timevalNs(_ tv: timeval) -> UInt64 {
  UInt64(tv.tv_sec) &* 1_000_000_000 &+ UInt64(tv.tv_usec) &* 1_000
}

private func childrenCpuNs() -> UInt64 {
  var usage = rusage()
  guard getrusage(RUSAGE_CHILDREN, &usage) == 0 else { return 0 }
  return timevalNs(usage.ru_utime) &+ timevalNs(usage.ru_stime)
}

private struct Sample {
  var producerBytes: UInt64
  var producerWallNs: UInt64
  var childCpuNs: UInt64
  /// Consumer per-read latencies (ns). Empty for noread / ring-write modes.
  /// Concatenated across all sessions in a multi-session iter.
  var consumerReadNs: [UInt64]
  /// Control RPC latencies (ns). Empty unless --control-probe-interval-us is set.
  var controlProbeNs: [UInt64]
  /// Total bytes the consumer actually copied across all sessions.
  var consumerBytes: UInt64
  var overflowed: Bool
}

private func makePayloadFile() throws -> URL {
  let url = URL(
    fileURLWithPath: NSTemporaryDirectory()
      .appending("bench-labpty-hot-path-payload-\(payloadBytes).bin"))
  let fm = FileManager.default
  if let attrs = try? fm.attributesOfItem(atPath: url.path),
    let size = attrs[.size] as? Int, size == payloadBytes
  {
    return url
  }
  // A deterministic mix of printable bytes and newlines. The labpty
  // producer doesn't parse — any bytes are fine — but this keeps the
  // payload reproducible across runs and machines.
  let line: [UInt8] = Array(
    "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \n".utf8)
  var data = Data(capacity: payloadBytes)
  while data.count + line.count <= payloadBytes {
    data.append(contentsOf: line)
  }
  while data.count < payloadBytes {
    data.append(0x0A)
  }
  try data.write(to: url)
  return url
}

private func childArgv(producer: Producer, payload: URL, options: Options) -> [String] {
  switch producer {
  case .cat:
    // `cat <payload>` reads a 32 MiB file and writes it to the PTY. The
    // PTY's line discipline translates \n -> \r\n so the consumer sees
    // slightly more than 32 MiB.
    return ["/bin/sh", "-c", "exec cat \(payload.path)"]
  case .zero:
    // dd writing 64 KiB chunks of zero to the PTY. No newlines → no CRLF
    // expansion → exact 32 MiB through the ring. Larger child-side write
    // chunks isolate the labpty drain from `cat`'s per-line overhead.
    let totalBytes = payloadBytes
    let blockSize = 65536
    let count = totalBytes / blockSize
    return ["/bin/sh", "-c", "exec dd if=/dev/zero bs=\(blockSize) count=\(count) 2>/dev/null"]
  case .flood:
    return ["/bin/sh", "-c", "exec \"$HOME/laban-flood-output.sh\" \(options.floodSeconds)"]
  }
}

private struct Harness {
  let socketPath: String
  let shmDir: String
  let tempRoot: URL
  let process: Process
}

private func locateLabptyBinary() -> (url: URL, isDebug: Bool)? {
  if let override = ProcessInfo.processInfo.environment["LABPTY_BINARY"], !override.isEmpty {
    let url = URL(fileURLWithPath: override)
    if FileManager.default.isExecutableFile(atPath: url.path) {
      return (url, false)
    }
  }
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let release = root.appendingPathComponent(".build/release/labpty")
  if FileManager.default.isExecutableFile(atPath: release.path) {
    return (release, false)
  }
  let debug = root.appendingPathComponent(".build/debug/labpty")
  if FileManager.default.isExecutableFile(atPath: debug.path) {
    return (debug, true)
  }
  return nil
}

private var labptyBinaryWarned = false

private func launchLabpty() throws -> Harness {
  guard let located = locateLabptyBinary() else {
    throw BenchError(
      "labpty binary not found. Build it first: swift build --product labpty -c release")
  }
  if located.isDebug && !labptyBinaryWarned {
    FileHandle.standardError.write(
      Data("bench-labpty-hot-path: warning: using debug labpty binary; numbers are not meaningful.\n".utf8))
    labptyBinaryWarned = true
  }
  // macOS sockaddr_un.sun_path is 104 bytes. NSTemporaryDirectory() alone
  // is already ~57 chars on most setups, so a UUID-suffixed sub-path runs
  // out of room. Use a short suffix and put it in /tmp directly.
  let shortId = String(UUID().uuidString.prefix(8))
  let tempRoot = URL(fileURLWithPath: "/tmp/blp-\(shortId)", isDirectory: true)
  let shmDir = tempRoot.appendingPathComponent("shm", isDirectory: true)
  try FileManager.default.createDirectory(at: shmDir, withIntermediateDirectories: true)
  let socketPath = tempRoot.appendingPathComponent("s").path

  let process = Process()
  process.executableURL = located.url
  process.arguments = ["--socket", socketPath, "--shm-dir", shmDir.path]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()

  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    if FileManager.default.fileExists(atPath: socketPath) { break }
    usleep(20_000)
  }
  guard FileManager.default.fileExists(atPath: socketPath) else {
    Darwin.kill(pid_t(process.processIdentifier), SIGKILL)
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: tempRoot)
    throw BenchError("labpty socket \(socketPath) did not appear within 5s")
  }
  return Harness(
    socketPath: socketPath,
    shmDir: shmDir.path,
    tempRoot: tempRoot,
    process: process)
}

private func shutdown(_ harness: Harness) {
  if harness.process.isRunning {
    Darwin.kill(pid_t(harness.process.processIdentifier), SIGTERM)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline && harness.process.isRunning { usleep(20_000) }
    if harness.process.isRunning {
      Darwin.kill(pid_t(harness.process.processIdentifier), SIGKILL)
      harness.process.waitUntilExit()
    }
  }
  try? FileManager.default.removeItem(at: harness.tempRoot)
}

private struct BenchError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

private final class AtomicFlag {
  private var raw: Int32 = 0
  func set() { OSAtomicCompareAndSwap32(0, 1, &raw) }
  func isSet() -> Bool { OSAtomicAdd32(0, &raw) != 0 }
}

private final class ControlProbe {
  private let stopFlag = AtomicFlag()
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var samples: [UInt64] = []
  private var failure: String?

  init(socketPath: String, intervalUs: UInt32) throws {
    let client = try LabptyTerminalSessionClient(
      socketPath: socketPath, rpcTimeoutMilliseconds: 5_000)
    _ = try client.hello()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async { [client, stopFlag] in
      defer {
        client.close()
        self.group.leave()
      }
      while !stopFlag.isSet() {
        let t0 = clockMonotonicNs()
        do {
          _ = try client.listLabptySessions()
        } catch {
          self.lock.withLock {
            if self.failure == nil { self.failure = "\(error)" }
          }
          break
        }
        let t1 = clockMonotonicNs()
        self.lock.withLock {
          self.samples.append(t1 &- t0)
        }
        usleep(intervalUs)
      }
    }
  }

  func stopAndWait() throws -> [UInt64] {
    stopFlag.set()
    group.wait()
    return try lock.withLock {
      if let failure {
        throw BenchError("control probe failed: \(failure)")
      }
      return samples
    }
  }
}

private struct SessionResult {
  var producerBytes: UInt64
  var consumerBytes: UInt64
  var consumerReadNs: [UInt64]
  var overflowed: Bool
}

/// Drains one already-opened session until its writer offset reaches the
/// expected payload size and stays quiet for a stall threshold. When
/// `readPayload` is false, only the writer offset is sampled.
private func drainSession(
  reader: LabptyByteRingReader,
  expectedBytes: UInt64,
  readPayload: Bool
) -> SessionResult {
  let startNs = clockMonotonicNs()
  var lastProgressNs = startNs
  var offset: UInt64 = 0
  var consumerBytes: UInt64 = 0
  var overflowed = false
  var readNs: [UInt64] = []
  if readPayload {
    readNs.reserveCapacity(4096)
  }
  let stallThresholdNs: UInt64 = 50_000_000
  let maxRunNs: UInt64 = 30_000_000_000  // 30s safety
  while true {
    let nowNs = clockMonotonicNs()
    let writerOffset = reader.outputWriteOffset()
    if writerOffset > offset { lastProgressNs = nowNs }

    if readPayload {
      let t0 = clockMonotonicNs()
      let result = reader.readSince(offset)
      let t1 = clockMonotonicNs()
      readNs.append(t1 &- t0)
      if result.overflowed { overflowed = true }
      consumerBytes += UInt64(result.bytes.count)
      offset = result.newOffset
    } else {
      offset = writerOffset
    }

    let producerDone = offset >= expectedBytes
    let quiet = nowNs &- lastProgressNs > stallThresholdNs
    if producerDone && quiet { break }
    if nowNs &- startNs > maxRunNs { break }

    if readPayload {
      usleep(200)
    } else {
      usleep(2_000)
    }
  }
  return SessionResult(
    producerBytes: offset,
    consumerBytes: consumerBytes,
    consumerReadNs: readNs,
    overflowed: overflowed)
}

/// Spawn labpty, open `sessions` parallel sessions each running the
/// `producer` command, drain them concurrently. Wall time is end-to-end
/// (longest session). Producer/consumer bytes are summed across sessions.
private func runDaemonDrain(
  payload: URL,
  options: Options,
  readPayload: Bool
) throws -> Sample {
  let cpuBefore = childrenCpuNs()
  let harness = try launchLabpty()
  var didShutdown = false
  defer {
    if !didShutdown { shutdown(harness) }
  }
  let client = try LabptyTerminalSessionClient(
    socketPath: harness.socketPath, rpcTimeoutMilliseconds: 5_000)
  defer { client.close() }
  _ = try client.hello()

  // Open all hot sessions first, then start the consumer threads, so the
  // wall-clock measurement starts the moment the first byte could be
  // produced.
  var descriptors: [LabptySessionDescriptor] = []
  var readers: [LabptyByteRingReader] = []
  descriptors.reserveCapacity(options.sessions)
  readers.reserveCapacity(options.sessions)
  for slot in 0..<options.sessions {
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 50,
        cols: 200,
        outputRingCapacity: outputRingCapacity,
        argv: childArgv(producer: options.producer, payload: payload, options: options),
        logicalSessionId: "bench-\(slot)-\(UUID().uuidString)"))
    descriptors.append(descriptor)
    readers.append(try LabptyByteRingReader(path: descriptor.byteRingShmPath))
  }

  // Per-session result slots, written by exactly one thread each.
  var results: [SessionResult] = Array(
    repeating: SessionResult(
      producerBytes: 0, consumerBytes: 0, consumerReadNs: [], overflowed: false),
    count: options.sessions)
  let resultsLock = NSLock()
  let expectedBytes: UInt64 = {
    switch options.producer {
    case .cat:
      // CRLF expansion adds ~1 byte per newline. We don't know the exact
      // count without scanning the payload, so use a slightly low
      // threshold and let the stall detector handle the tail.
      return UInt64(payloadBytes)
    case .zero:
      return UInt64(payloadBytes)
    case .flood:
      return 0
    }
  }()

  let group = DispatchGroup()
  let controlProbe = options.controlProbeIntervalUs > 0
    ? try ControlProbe(
        socketPath: harness.socketPath,
        intervalUs: options.controlProbeIntervalUs)
    : nil
  let startNs = clockMonotonicNs()
  for slot in 0..<options.sessions {
    group.enter()
    let reader = readers[slot]
    DispatchQueue.global(qos: .userInitiated).async {
      let result = drainSession(
        reader: reader, expectedBytes: expectedBytes, readPayload: readPayload)
      resultsLock.withLock {
        results[slot] = result
      }
      group.leave()
    }
  }
  group.wait()
  let endNs = clockMonotonicNs()
  let controlProbeNs = try controlProbe?.stopAndWait() ?? []

  for descriptor in descriptors {
    _ = try? client.terminate(handle: descriptor.ptyHandle)
  }
  shutdown(harness)
  didShutdown = true
  let cpuAfter = childrenCpuNs()

  let totalProducerBytes = results.reduce(UInt64(0)) { $0 &+ $1.producerBytes }
  let totalConsumerBytes = results.reduce(UInt64(0)) { $0 &+ $1.consumerBytes }
  let mergedReads = results.flatMap { $0.consumerReadNs }
  let overflowed = results.contains { $0.overflowed }

  return Sample(
    producerBytes: totalProducerBytes,
    producerWallNs: endNs &- startNs,
    childCpuNs: cpuAfter &- cpuBefore,
    consumerReadNs: mergedReads,
    controlProbeNs: controlProbeNs,
    consumerBytes: totalConsumerBytes,
    overflowed: overflowed)
}

/// Pure Swift writer microbench. Allocates a `LabptyByteRingWriter`,
/// writes the payload in 4 KiB chunks, measures wall time.
private func runRingWrite() throws -> Sample {
  let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("bench-labpty-ring-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tempRoot) }
  let ringPath = tempRoot.appendingPathComponent("ring.br").path

  let writer = try LabptyByteRingWriter(
    path: ringPath,
    outputRingCapacity: outputRingCapacity,
    logicalSessionId: "bench-ring-write")

  var chunk = [UInt8](repeating: 0, count: ringWriteChunkBytes)
  for i in 0..<ringWriteChunkBytes {
    chunk[i] = UInt8((i * 31 + 7) & 0x7F)
  }

  let startNs = clockMonotonicNs()
  var written = 0
  chunk.withUnsafeBytes { raw in
    let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                    count: ringWriteChunkBytes, deallocator: .none)
    while written < payloadBytes {
      writer.write(data)
      written += ringWriteChunkBytes
    }
  }
  let endNs = clockMonotonicNs()

  return Sample(
    producerBytes: UInt64(written),
    producerWallNs: endNs &- startNs,
    childCpuNs: 0,
    consumerReadNs: [],
    controlProbeNs: [],
    consumerBytes: 0,
    overflowed: false)
}

private func runOnce(mode: Mode, payload: URL, options: Options) throws -> Sample {
  switch mode {
  case .daemonDrain: return try runDaemonDrain(payload: payload, options: options, readPayload: true)
  case .daemonDrainNoRead: return try runDaemonDrain(payload: payload, options: options, readPayload: false)
  case .ringWrite: return try runRingWrite()
  }
}

private func percentileNs(_ xs: [UInt64], _ q: Double) -> UInt64 {
  guard !xs.isEmpty else { return 0 }
  let sorted = xs.sorted()
  let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded(.toNearestOrAwayFromZero))))
  return sorted[i]
}

private func summarize(mode: Mode, samples: [Sample], options: Options) {
  let walls = samples.map { Double($0.producerWallNs) / 1_000_000.0 }
  let meanWallMs = walls.reduce(0, +) / Double(walls.count)
  let avgBytes = samples.map { Double($0.producerBytes) }.reduce(0, +) / Double(samples.count)
  let mbps = avgBytes / (meanWallMs / 1000.0) / (1024.0 * 1024.0)
  let overflows = samples.filter { $0.overflowed }.count
  let childCpuMeanMs =
    samples.map { Double($0.childCpuNs) / 1_000_000.0 }.reduce(0, +) / Double(samples.count)
  let childCpuPerMiB = avgBytes > 0
    ? childCpuMeanMs / (avgBytes / (1024.0 * 1024.0))
    : 0

  var line = String(
    format:
      "SUMMARY[%@]  iters=%d  sessions=%d  producer=%@  wall_mean=%.1f ms  throughput=%.1f MiB/s  child_cpu_mean=%.1f ms  child_cpu_per_mib=%.2f ms/MiB  overflows=%d/%d",
    mode.rawValue, samples.count, options.sessions, options.producer.rawValue,
    meanWallMs, mbps, childCpuMeanMs, childCpuPerMiB, overflows, samples.count)

  let allConsumerNs = samples.flatMap { $0.consumerReadNs }
  if !allConsumerNs.isEmpty {
    let p50 = Double(percentileNs(allConsumerNs, 0.50)) / 1000.0
    let p95 = Double(percentileNs(allConsumerNs, 0.95)) / 1000.0
    let p99 = Double(percentileNs(allConsumerNs, 0.99)) / 1000.0
    let p999 = Double(percentileNs(allConsumerNs, 0.999)) / 1000.0
    let maxUs = Double(allConsumerNs.max() ?? 0) / 1000.0
    line += String(
      format:
        "  read_n=%d  read_p50=%.1fµs  read_p95=%.1fµs  read_p99=%.1fµs  read_p99.9=%.1fµs  read_max=%.1fµs",
      allConsumerNs.count, p50, p95, p99, p999, maxUs)
  }
  let allControlNs = samples.flatMap { $0.controlProbeNs }
  if !allControlNs.isEmpty {
    let p50 = Double(percentileNs(allControlNs, 0.50)) / 1000.0
    let p95 = Double(percentileNs(allControlNs, 0.95)) / 1000.0
    let p99 = Double(percentileNs(allControlNs, 0.99)) / 1000.0
    let p999 = Double(percentileNs(allControlNs, 0.999)) / 1000.0
    let maxUs = Double(allControlNs.max() ?? 0) / 1000.0
    line += String(
      format:
        "  control_n=%d  control_p50=%.1fµs  control_p95=%.1fµs  control_p99=%.1fµs  control_p99.9=%.1fµs  control_max=%.1fµs",
      allControlNs.count, p50, p95, p99, p999, maxUs)
  }
  print(line)

  if options.topOutliers > 0 && !allConsumerNs.isEmpty {
    let sorted = allConsumerNs.sorted(by: >)
    let top = Array(sorted.prefix(options.topOutliers))
    let formatted = top.map { String(format: "%.1fµs", Double($0) / 1000.0) }.joined(separator: ", ")
    print("  top-\(options.topOutliers) outliers: \(formatted)")
  }
}

private func runMode(_ mode: Mode, payload: URL, options: Options) {
  print(
    "bench-labpty-hot-path[\(mode.rawValue)]: payload=\(payloadBytes) B, "
      + "ring_capacity=\(outputRingCapacity) B, "
      + "sessions=\(options.sessions), producer=\(options.producer.rawValue), "
      + "flood_seconds=\(options.floodSeconds), "
      + "iter=\(iterations) (after \(warmup) warmup)")
  for _ in 0..<warmup {
    do {
      _ = try runOnce(mode: mode, payload: payload, options: options)
    } catch {
      FileHandle.standardError.write(Data("bench[\(mode.rawValue)] warmup failed: \(error)\n".utf8))
      return
    }
  }
  var samples: [Sample] = []
  for i in 0..<iterations {
    do {
      let s = try runOnce(mode: mode, payload: payload, options: options)
      samples.append(s)
      let mbps = Double(s.producerBytes) / (Double(s.producerWallNs) / 1e9) / (1024.0 * 1024.0)
      let extra: String
      let controlExtra: String
      if !s.consumerReadNs.isEmpty {
        extra = String(
          format: "  reads=%d  consumer_bytes=%llu", s.consumerReadNs.count, s.consumerBytes)
      } else {
        extra = ""
      }
      if !s.controlProbeNs.isEmpty {
        controlExtra = String(format: "  control_rpc=%d", s.controlProbeNs.count)
      } else {
        controlExtra = ""
      }
      print(
        String(
          format: "  iter %d: wall=%.1f ms  bytes=%llu  throughput=%.1f MiB/s%@%@%@",
          i,
          Double(s.producerWallNs) / 1_000_000.0,
          s.producerBytes,
          mbps,
          s.overflowed ? "  overflowed" : "",
          extra,
          controlExtra))
    } catch {
      FileHandle.standardError.write(
        Data("bench[\(mode.rawValue)] iter \(i) failed: \(error)\n".utf8))
      return
    }
  }
  summarize(mode: mode, samples: samples, options: options)
  print("---")
}

private func clockMonotonicNs() -> UInt64 {
  var ts = timespec()
  clock_gettime(CLOCK_MONOTONIC, &ts)
  return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

let payload: URL
do {
  payload = try makePayloadFile()
} catch {
  FileHandle.standardError.write(Data("bench-labpty-hot-path: payload error: \(error)\n".utf8))
  exit(1)
}

let options: Options
do {
  options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
} catch let error as BenchError {
  FileHandle.standardError.write(Data("bench-labpty-hot-path: \(error.description)\n".utf8))
  exit(2)
} catch {
  FileHandle.standardError.write(Data("bench-labpty-hot-path: \(error)\n".utf8))
  exit(2)
}

for mode in options.modes {
  runMode(mode, payload: payload, options: options)
}
