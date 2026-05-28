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
/// - `daemon-drain`         end-to-end. Spawn labpty, open a session whose
///                          child writes a fixed payload via `cat`, drain
///                          the byte ring from a consumer thread using
///                          `LabptyByteRingReader.readSince`. Reports
///                          producer throughput (MiB/s based on the writer
///                          offset) and consumer per-read latency
///                          percentiles. The only mode that exercises the
///                          compiled C in the labpty daemon.
///
/// - `daemon-drain-noread`  producer-only end-to-end. Same daemon and
///                          session as `daemon-drain` but the consumer
///                          only samples `outputWriteOffset()` on a coarse
///                          cadence — no `readSince()`, no payload copy.
///                          Isolates the producer (kernel read + byte
///                          ring write + heartbeat) from any consumer-
///                          side memcpy cost.
///
/// - `ring-write`           writer microbench against the Swift
///                          `LabptyByteRingWriter`. Loop calling
///                          `write` with a 4 KiB chunk until the payload
///                          is consumed. No kernel, no IPC, no daemon.
///                          NOTE: this is the Swift reimplementation of
///                          the ring writer, not labpty's C. Useful as a
///                          floor measurement and to check that the
///                          mirrored layout has not regressed — it is not
///                          a substitute for `daemon-drain`.
///
/// Usage:
///   bench-labpty-hot-path                      # runs all modes
///   bench-labpty-hot-path daemon-drain         # one mode
///   bench-labpty-hot-path ring-write daemon-drain
///
/// The daemon modes expect `.build/{debug,release}/labpty` to exist.
/// Build it first with `swift build --product labpty` (release for a
/// meaningful number). The bench picks the release binary when present,
/// debug otherwise, and warns when running against the debug build.

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

private struct Sample {
  var producerBytes: UInt64
  var producerWallNs: UInt64
  /// Consumer per-read latencies (ns). Empty for noread / ring-write modes.
  var consumerReadNs: [UInt64]
  /// Total bytes the consumer actually copied. May differ from
  /// `producerBytes` when the ring overflows (we count the writer's
  /// advancing offset as the producer measurement).
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
  // payload reproducible across runs and across machines.
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

private struct Harness {
  let socketPath: String
  let shmDir: String
  let tempRoot: URL
  let process: Process
}

private func locateLabptyBinary() -> (url: URL, isDebug: Bool)? {
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
  // Silence the daemon's stderr; otherwise SIGTERM-on-shutdown leaks noise
  // into the bench output. Errors that matter would show up via socket
  // disconnect before we get to print summary lines.
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()

  // Wait for the listening socket to appear so the first connect doesn't race.
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

/// Spawn labpty, open a session that emits the payload, drain the byte ring
/// to completion. When `readPayload` is true the consumer copies bytes out
/// of the ring (the realistic case); when false the consumer only samples
/// the writer offset (producer-only measurement).
private func runDaemonDrain(payload: URL, readPayload: Bool) throws -> Sample {
  let harness = try launchLabpty()
  defer { shutdown(harness) }
  let client = try LabptyTerminalSessionClient(socketPath: harness.socketPath, rpcTimeoutMilliseconds: 5_000)
  defer { client.close() }
  _ = try client.hello()

  let descriptor = try client.openSession(
    LabptyOpenSessionRequest(
      rows: 50,
      cols: 200,
      outputRingCapacity: outputRingCapacity,
      argv: ["/bin/sh", "-c", "exec cat \(payload.path)"],
      logicalSessionId: "bench-\(UUID().uuidString)"))

  let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

  let startNs = clockMonotonicNs()
  var lastProgressNs = startNs
  var offset: UInt64 = 0
  var consumerBytes: UInt64 = 0
  var overflowed = false
  var consumerReadNs: [UInt64] = []
  if readPayload {
    consumerReadNs.reserveCapacity(4096)
  }

  // Drain until the writer offset has reached at least the payload size and
  // we've stopped seeing new bytes for >= 50 ms (the producer is done and
  // the consumer has caught up).
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
      consumerReadNs.append(t1 &- t0)
      if result.overflowed { overflowed = true }
      consumerBytes += UInt64(result.bytes.count)
      offset = result.newOffset
    } else {
      offset = writerOffset
    }

    let producerDone = offset >= UInt64(payloadBytes)
    let quiet = nowNs &- lastProgressNs > stallThresholdNs
    if producerDone && quiet { break }
    if nowNs &- startNs > maxRunNs { break }

    if readPayload {
      // Modest sleep to amortize Mach calls but stay below typical PTY
      // chunk pacing.
      usleep(200)
    } else {
      // Coarser sample cadence — we're trying not to perturb the producer.
      usleep(2_000)
    }
  }
  let endNs = clockMonotonicNs()

  _ = try? client.terminate(handle: descriptor.ptyHandle)

  return Sample(
    producerBytes: offset,
    producerWallNs: endNs &- startNs,
    consumerReadNs: consumerReadNs,
    consumerBytes: consumerBytes,
    overflowed: overflowed)
}

/// Pure Swift writer microbench. Allocates a `LabptyByteRingWriter`,
/// writes the payload in 4 KiB chunks (the same chunk size labpty's
/// daemon uses when it forwards a PTY read), measures wall time.
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

  // One reusable chunk of the right shape. The writer copies the bytes,
  // so the chunk contents only matter for cache realism.
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
    consumerReadNs: [],
    consumerBytes: 0,
    overflowed: false)
}

private func runOnce(mode: Mode, payload: URL) throws -> Sample {
  switch mode {
  case .daemonDrain: return try runDaemonDrain(payload: payload, readPayload: true)
  case .daemonDrainNoRead: return try runDaemonDrain(payload: payload, readPayload: false)
  case .ringWrite: return try runRingWrite()
  }
}

private func percentileNs(_ xs: [UInt64], _ q: Double) -> UInt64 {
  guard !xs.isEmpty else { return 0 }
  let sorted = xs.sorted()
  let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded(.toNearestOrAwayFromZero))))
  return sorted[i]
}

private func summarize(mode: Mode, samples: [Sample]) {
  let walls = samples.map { Double($0.producerWallNs) / 1_000_000.0 }
  let meanWallMs = walls.reduce(0, +) / Double(walls.count)
  let avgBytes = samples.map { Double($0.producerBytes) }.reduce(0, +) / Double(samples.count)
  let mbps = avgBytes / (meanWallMs / 1000.0) / (1024.0 * 1024.0)
  let overflows = samples.filter { $0.overflowed }.count

  var line = String(
    format:
      "SUMMARY[%@]  iters=%d  wall_mean=%.1f ms  throughput=%.1f MiB/s  overflows=%d/%d",
    mode.rawValue, samples.count, meanWallMs, mbps, overflows, samples.count)

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
  print(line)
}

private func runMode(_ mode: Mode, payload: URL) {
  print(
    "bench-labpty-hot-path[\(mode.rawValue)]: payload=\(payloadBytes) B, "
      + "ring_capacity=\(outputRingCapacity) B, "
      + "iter=\(iterations) (after \(warmup) warmup)")
  for _ in 0..<warmup {
    do {
      _ = try runOnce(mode: mode, payload: payload)
    } catch {
      FileHandle.standardError.write(Data("bench[\(mode.rawValue)] warmup failed: \(error)\n".utf8))
      return
    }
  }
  var samples: [Sample] = []
  for i in 0..<iterations {
    do {
      let s = try runOnce(mode: mode, payload: payload)
      samples.append(s)
      let mbps = Double(s.producerBytes) / (Double(s.producerWallNs) / 1e9) / (1024.0 * 1024.0)
      let extra: String
      if !s.consumerReadNs.isEmpty {
        extra = String(format: "  reads=%d  consumer_bytes=%llu", s.consumerReadNs.count, s.consumerBytes)
      } else {
        extra = ""
      }
      print(
        String(
          format: "  iter %d: wall=%.1f ms  bytes=%llu  throughput=%.1f MiB/s%@%@",
          i,
          Double(s.producerWallNs) / 1_000_000.0,
          s.producerBytes,
          mbps,
          s.overflowed ? "  overflowed" : "",
          extra))
    } catch {
      FileHandle.standardError.write(
        Data("bench[\(mode.rawValue)] iter \(i) failed: \(error)\n".utf8))
      return
    }
  }
  summarize(mode: mode, samples: samples)
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

let args = CommandLine.arguments.dropFirst()
let modes: [Mode]
if args.isEmpty {
  modes = Mode.allCases
} else {
  modes = args.compactMap { Mode(rawValue: $0) }
  if modes.count != args.count {
    let valid = Mode.allCases.map(\.rawValue).joined(separator: ", ")
    FileHandle.standardError.write(
      Data("bench-labpty-hot-path: unknown mode. valid: \(valid)\n".utf8))
    exit(2)
  }
}

for mode in modes {
  runMode(mode, payload: payload)
}
