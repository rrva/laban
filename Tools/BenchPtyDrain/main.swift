import Darwin
import Foundation
import LabanCore
import LabanTerminalCore

/// Microbench for the PTY drain loop, three modes:
///
/// - `drain-full`   end-to-end: spawn `cat <payload>`, drain via
///                  laban_session_poll_blocking; read + VT parse.
/// - `drain-no-vt`  same as drain-full but with
///                  laban_session_suppress_pty_output_until_input set so
///                  the drain reads but skips the VT parser. Isolates
///                  kernel read() + select() cost.
/// - `vt-only`      fixture session; feed the same payload directly via
///                  laban_session_feed_output in fixed-size chunks. No
///                  PTY, no syscalls per chunk. Isolates VT parser cost.
///
/// drain-full ≈ drain-no-vt + vt-only (modulo lock acquisitions and
/// scheduler noise). The decomposition tells us which subsystem to
/// optimize.
///
/// Usage:
///   bench-pty-drain                  # runs all three modes
///   bench-pty-drain drain-full       # one mode
///   bench-pty-drain drain-no-vt vt-only

private let payloadBytes = 32 * 1024 * 1024  // 32 MiB
private let iterations = 5
private let warmup = 1

enum Mode: String, CaseIterable {
  case drainFull = "drain-full"
  case drainNoVT = "drain-no-vt"
  case vtOnly = "vt-only"
  case snapshotLatency = "snapshot-latency"
  case processMetadata = "process-metadata"
  case agentMetadata = "agent-metadata"
}

private func makePayloadFile() throws -> URL {
  let url = URL(
    fileURLWithPath: NSTemporaryDirectory()
      .appending("bench-pty-drain-payload-\(payloadBytes).txt"))
  let fm = FileManager.default
  if let attrs = try? fm.attributesOfItem(atPath: url.path),
    let size = attrs[.size] as? Int, size == payloadBytes
  {
    return url
  }
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

private func makePtySession(payload: URL) -> OpaquePointer? {
  let exe = strdup("/bin/sh")!
  let argStrings = ["/bin/sh", "-c", "cat \(payload.path)"]
  var ptrs: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) }
  ptrs.append(nil)
  defer {
    free(exe)
    for p in ptrs { if let p { free(p) } }
  }
  let count = ptrs.count
  var session: OpaquePointer?
  let rc = ptrs.withUnsafeMutableBufferPointer { buf -> Int32 in
    buf.baseAddress!.withMemoryRebound(
      to: UnsafePointer<CChar>?.self, capacity: count
    ) { rebound -> Int32 in
      var config = LabanLaunchConfig()
      config.executable = UnsafePointer(exe)
      config.argv = UnsafePointer(rebound)
      config.fixture_mode = 0
      var size = LabanTerminalSize()
      size.rows = 50
      size.cols = 200
      return laban_session_create(&config, size, &session)
    }
  }
  guard rc == 0 else { return nil }
  return session
}

/// Spawn a session whose child re-emits the payload in a loop until
/// killed via session destroy. Used by the snapshot-latency bench to
/// keep the drain hot for the whole measurement window.
private func makeHeavyPtySession(payload: URL) -> OpaquePointer? {
  let exe = strdup("/bin/sh")!
  let argStrings = [
    "/bin/sh", "-c", "while :; do cat \(payload.path); done",
  ]
  var ptrs: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) }
  ptrs.append(nil)
  defer {
    free(exe)
    for p in ptrs { if let p { free(p) } }
  }
  let count = ptrs.count
  var session: OpaquePointer?
  let rc = ptrs.withUnsafeMutableBufferPointer { buf -> Int32 in
    buf.baseAddress!.withMemoryRebound(
      to: UnsafePointer<CChar>?.self, capacity: count
    ) { rebound -> Int32 in
      var config = LabanLaunchConfig()
      config.executable = UnsafePointer(exe)
      config.argv = UnsafePointer(rebound)
      config.fixture_mode = 0
      var size = LabanTerminalSize()
      size.rows = 50
      size.cols = 200
      return laban_session_create(&config, size, &session)
    }
  }
  guard rc == 0 else { return nil }
  return session
}

private func makeFixtureSession() -> OpaquePointer? {
  var config = LabanLaunchConfig()
  config.fixture_mode = 1
  var size = LabanTerminalSize()
  size.rows = 50
  size.cols = 200
  var session: OpaquePointer?
  guard laban_session_create(&config, size, &session) == 0 else { return nil }
  return session
}

struct Sample {
  var wallMs: Double
  var bytes: UInt64
  var reads: UInt64  // 0 for vt-only (no read() syscalls)
}

private func runDrain(payload: URL, parseVT: Bool) -> Sample? {
  guard let s = makePtySession(payload: payload) else { return nil }
  defer { laban_session_destroy(s) }

  if !parseVT {
    _ = laban_session_suppress_pty_output_until_input(s, 1)
  }

  var readsStart: UInt64 = 0
  var bytesStart: UInt64 = 0
  laban_session_drain_stats(s, &readsStart, &bytesStart)

  let started = DispatchTime.now()
  var totalDrained: Int = 0
  let deadline = Date().addingTimeInterval(30.0)
  var done = false
  while Date() < deadline {
    let n = laban_session_poll_blocking(s, 100)
    if n > 0 {
      totalDrained += Int(n)
      continue
    }
    if n < 0 { break }
    if totalDrained >= payloadBytes {
      done = true
      break
    }
  }
  let wall = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds

  var readsEnd: UInt64 = 0
  var bytesEnd: UInt64 = 0
  laban_session_drain_stats(s, &readsEnd, &bytesEnd)

  guard done else {
    FileHandle.standardError.write(
      Data("bench: drained \(totalDrained)/\(payloadBytes) — stuck?\n".utf8))
    return nil
  }
  return Sample(
    wallMs: Double(wall) / 1_000_000.0,
    bytes: bytesEnd - bytesStart,
    reads: readsEnd - readsStart)
}

private final class AtomicFlag {
  private var raw: Int32 = 0
  func set() { OSAtomicCompareAndSwap32(0, 1, &raw) }
  func isSet() -> Bool { OSAtomicAdd32(0, &raw) != 0 }
}

/// Run a concurrent reader thread (mimicking SessionRunner) while the
/// main thread takes snapshots in a tight loop. Records per-snapshot
/// latency. Loaded vs unloaded run lets us isolate lock-contention
/// cost from baseline snapshot cost.
private func runSnapshotLatency(payload: URL) {
  let measureSeconds: Double = 2.0
  let warmupSeconds: Double = 0.3

  func runOnce(loaded: Bool) -> (loaded: Bool, samples: [UInt64], drainBytes: UInt64, drainReads: UInt64)? {
    guard let s = (loaded
      ? makeHeavyPtySession(payload: payload)
      : makeFixtureSession()) else { return nil }

    let stop = AtomicFlag()
    let readerExited = DispatchSemaphore(value: 0)

    let readerThread: Thread?
    if loaded {
      let t = Thread {
        while !stop.isSet() {
          let n = laban_session_poll_blocking(s, 50)
          if n < 0 { break }
        }
        readerExited.signal()
      }
      t.name = "bench.reader"
      t.qualityOfService = .userInitiated
      t.start()
      readerThread = t
      // Let the reader prime: drains start, kernel buffer cycles establish.
      Thread.sleep(forTimeInterval: warmupSeconds)
    } else {
      readerThread = nil
    }

    let startWall = DispatchTime.now()
    let deadline = startWall.uptimeNanoseconds &+ UInt64(measureSeconds * 1e9)
    var samples: [UInt64] = []
    samples.reserveCapacity(50_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
      let t0 = DispatchTime.now().uptimeNanoseconds
      var snap: UnsafeMutablePointer<LabanSnapshot>?
      let rc = laban_session_snapshot(s, &snap)
      let t1 = DispatchTime.now().uptimeNanoseconds
      if rc == 0, let snap { laban_snapshot_destroy(snap) }
      samples.append(t1 &- t0)
    }

    var drainReads: UInt64 = 0
    var drainBytes: UInt64 = 0
    laban_session_drain_stats(s, &drainReads, &drainBytes)

    stop.set()
    if readerThread != nil {
      _ = readerExited.wait(timeout: .now() + .seconds(2))
    }
    laban_session_destroy(s)
    return (loaded, samples, drainBytes, drainReads)
  }

  print(
    "bench-pty-drain[snapshot-latency]: drain_buf=\(laban_session_drain_buf_bytes()), "
      + "drain_max_per_poll=\(laban_session_drain_max_bytes_per_poll()), "
      + "measure=\(measureSeconds)s")

  for loaded in [false, true] {
    guard let r = runOnce(loaded: loaded) else {
      FileHandle.standardError.write(Data("snapshot-latency setup failed\n".utf8))
      return
    }
    let nsSamples = r.samples
    let sorted = nsSamples.sorted()
    let count = sorted.count
    let totalNs = sorted.reduce(UInt64(0), +)
    let meanUs = Double(totalNs) / Double(count) / 1000.0
    let p50 = Double(sorted[count / 2]) / 1000.0
    let p95 = Double(sorted[Int(Double(count - 1) * 0.95)]) / 1000.0
    let p99 = Double(sorted[Int(Double(count - 1) * 0.99)]) / 1000.0
    let p999 = Double(sorted[Int(Double(count - 1) * 0.999)]) / 1000.0
    let maxUs = Double(sorted.last ?? 0) / 1000.0
    let drainMB = Double(r.drainBytes) / (1024 * 1024)
    let load = r.loaded ? "loaded  " : "unloaded"
    print(
      String(
        format:
          "  %@  n=%d  mean=%.1fµs p50=%.1fµs p95=%.1fµs p99=%.1fµs p99.9=%.1fµs max=%.1fµs  drained=%.1f MiB",
        load, count, meanUs, p50, p95, p99, p999, maxUs, drainMB))
  }
  print("---")
}

private func runVTOnly(payload payloadURL: URL) -> Sample? {
  // Feed the payload through the VT parser in the same chunk size the
  // drain uses (4 KiB by default). Apples-to-apples per-chunk overhead.
  let chunk = Int(laban_session_drain_buf_bytes())
  guard let s = makeFixtureSession() else { return nil }
  defer { laban_session_destroy(s) }

  let data: Data
  do {
    data = try Data(contentsOf: payloadURL)
  } catch {
    return nil
  }

  let started = DispatchTime.now()
  let total = data.count
  data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
    var offset = 0
    while offset < total {
      let n = min(chunk, total - offset)
      _ = laban_session_feed_output(s, base + offset, n)
      offset += n
    }
  }
  let wall = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
  return Sample(
    wallMs: Double(wall) / 1_000_000.0,
    bytes: UInt64(total),
    reads: 0)
}

private func runOnce(mode: Mode, payload: URL) -> Sample? {
  switch mode {
  case .drainFull: return runDrain(payload: payload, parseVT: true)
  case .drainNoVT: return runDrain(payload: payload, parseVT: false)
  case .vtOnly: return runVTOnly(payload: payload)
  case .snapshotLatency, .processMetadata, .agentMetadata: return nil  // own reporters
  }
}

/// Microbench for ClaudeSessionLogLocator.metadata(fromLogAt:).
/// Picks the largest jsonl file in ~/.claude/projects/ as a worst-case
/// input (this is what the agent detector polls every 500ms per tab).
private func runAgentMetadata(payload _: URL) {
  let fm = FileManager.default
  let projectsRoot = fm.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude", isDirectory: true)
    .appendingPathComponent("projects", isDirectory: true)
  guard let projects = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
    FileHandle.standardError.write(Data("agent-metadata: no ~/.claude/projects dir\n".utf8))
    return
  }
  var candidates: [(url: URL, size: Int)] = []
  for proj in projects {
    guard let logs = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
    for log in logs where log.pathExtension == "jsonl" {
      let size = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      candidates.append((log, size))
    }
  }
  candidates.sort { $0.size > $1.size }
  guard let target = candidates.first else {
    FileHandle.standardError.write(Data("agent-metadata: no jsonl files\n".utf8))
    return
  }

  print(
    "bench-pty-drain[agent-metadata]: file=\(target.url.lastPathComponent) "
      + "size=\(target.size) bytes")

  let iterations = 200
  let warmup = 5
  for _ in 0..<warmup {
    _ = ClaudeSessionLogLocator.metadata(fromLogAt: target.url.path)
  }
  var samples: [UInt64] = []
  samples.reserveCapacity(iterations)
  var lastMeta = ClaudeSessionLogMetadata()
  for _ in 0..<iterations {
    let t0 = DispatchTime.now().uptimeNanoseconds
    lastMeta = ClaudeSessionLogLocator.metadata(fromLogAt: target.url.path)
    let t1 = DispatchTime.now().uptimeNanoseconds
    samples.append(t1 &- t0)
  }
  let sorted = samples.sorted()
  let totalNs = sorted.reduce(UInt64(0), +)
  let meanUs = Double(totalNs) / Double(sorted.count) / 1000.0
  let p50 = Double(sorted[sorted.count / 2]) / 1000.0
  let p95 = Double(sorted[Int(Double(sorted.count - 1) * 0.95)]) / 1000.0
  let p99 = Double(sorted[Int(Double(sorted.count - 1) * 0.99)]) / 1000.0
  let maxUs = Double(sorted.last ?? 0) / 1000.0
  print(
    String(
      format:
        "BENCH agent-metadata n=%d  mean=%.0fµs  p50=%.0fµs  p95=%.0fµs  p99=%.0fµs  max=%.0fµs  fields=(mode=%@,model=%@,cwd=%@)",
      iterations, meanUs, p50, p95, p99, maxUs,
      lastMeta.permissionMode ?? "nil",
      lastMeta.model ?? "nil",
      lastMeta.cwd ?? "nil"))
}

/// Microbench for laban_session_process_metadata. Spawns a shell that
/// holds the terminal so the foreground process group is the shell
/// itself (typical idle case — what we hit when displaying a prompt).
/// Then calls process_metadata in a tight loop and reports per-call
/// latency.
private func runProcessMetadata(payload: URL) {
  let iterations = 10_000
  let warmup = 1_000
  // Holds the PTY open for the duration of the bench.
  let exe = strdup("/bin/sh")!
  let argStrings = ["/bin/sh", "-c", "sleep 60"]
  var ptrs: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) }
  ptrs.append(nil)
  defer {
    free(exe)
    for p in ptrs { if let p { free(p) } }
  }
  let count = ptrs.count
  var session: OpaquePointer?
  let rc = ptrs.withUnsafeMutableBufferPointer { buf -> Int32 in
    buf.baseAddress!.withMemoryRebound(
      to: UnsafePointer<CChar>?.self, capacity: count
    ) { rebound -> Int32 in
      var cfg = LabanLaunchConfig()
      cfg.executable = UnsafePointer(exe)
      cfg.argv = UnsafePointer(rebound)
      cfg.fixture_mode = 0
      var size = LabanTerminalSize()
      size.rows = 24
      size.cols = 80
      return laban_session_create(&cfg, size, &session)
    }
  }
  guard rc == 0, let s = session else {
    FileHandle.standardError.write(Data("process-metadata: session create failed\n".utf8))
    return
  }
  defer { laban_session_destroy(s) }

  // Give the child a moment to set up its pgrp / become the foreground.
  Thread.sleep(forTimeInterval: 0.1)

  var childPid: Int32 = 0
  var fgPid: Int32 = 0
  var procBuf = [CChar](repeating: 0, count: 256)
  var cmdBuf = [CChar](repeating: 0, count: 1024)
  var cwdBuf = [CChar](repeating: 0, count: 1024)

  func callOnce() {
    _ = procBuf.withUnsafeMutableBufferPointer { p in
      cmdBuf.withUnsafeMutableBufferPointer { c in
        cwdBuf.withUnsafeMutableBufferPointer { w in
          laban_session_process_metadata(
            s, &childPid, &fgPid,
            p.baseAddress, p.count,
            c.baseAddress, c.count,
            w.baseAddress, w.count)
        }
      }
    }
  }

  for _ in 0..<warmup { callOnce() }

  var samples: [UInt64] = []
  samples.reserveCapacity(iterations)
  for _ in 0..<iterations {
    let t0 = DispatchTime.now().uptimeNanoseconds
    callOnce()
    let t1 = DispatchTime.now().uptimeNanoseconds
    samples.append(t1 &- t0)
  }
  let sorted = samples.sorted()
  let totalNs = sorted.reduce(UInt64(0), +)
  let meanUs = Double(totalNs) / Double(sorted.count) / 1000.0
  let p50 = Double(sorted[sorted.count / 2]) / 1000.0
  let p95 = Double(sorted[Int(Double(sorted.count - 1) * 0.95)]) / 1000.0
  let p99 = Double(sorted[Int(Double(sorted.count - 1) * 0.99)]) / 1000.0
  let maxUs = Double(sorted.last ?? 0) / 1000.0
  let fgName = String(cString: procBuf)
  print(
    String(
      format:
        "BENCH process-metadata  n=%d  mean=%.2fµs  p50=%.2fµs  p95=%.2fµs  p99=%.2fµs  max=%.2fµs  fg=%@(pid=%d)",
      iterations, meanUs, p50, p95, p99, maxUs, fgName, fgPid))
}

private func percentile(_ xs: [Double], _ q: Double) -> Double {
  guard !xs.isEmpty else { return 0 }
  let sorted = xs.sorted()
  let i = min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded(.up)))
  return sorted[i]
}

private func runMode(_ mode: Mode, payload: URL) {
  print(
    "bench-pty-drain[\(mode.rawValue)]: payload=\(payloadBytes), "
      + "chunk=\(laban_session_drain_buf_bytes()), "
      + "iter=\(iterations) (after \(warmup) warmup)")
  for _ in 0..<warmup {
    _ = runOnce(mode: mode, payload: payload)
  }
  var samples: [Sample] = []
  for i in 0..<iterations {
    guard let s = runOnce(mode: mode, payload: payload) else {
      FileHandle.standardError.write(
        Data("bench[\(mode.rawValue)] iter \(i) failed\n".utf8))
      return
    }
    samples.append(s)
    let mbps = Double(s.bytes) / (s.wallMs / 1000.0) / (1024.0 * 1024.0)
    let perRead = s.reads == 0 ? "n/a" : String(format: "%.0f", Double(s.bytes) / Double(s.reads))
    print(
      String(
        format: "  iter %d: wall=%.1f ms  bytes=%llu  reads=%llu  bytes/read=%@  throughput=%.1f MiB/s",
        i, s.wallMs, s.bytes, s.reads, perRead, mbps))
  }
  let walls = samples.map(\.wallMs)
  let mean = walls.reduce(0, +) / Double(walls.count)
  let avgReads = samples.map { Double($0.reads) }.reduce(0, +) / Double(samples.count)
  let avgBytes = samples.map { Double($0.bytes) }.reduce(0, +) / Double(samples.count)
  let mbps = avgBytes / (mean / 1000.0) / (1024.0 * 1024.0)
  print(
    String(
      format:
        "SUMMARY[%@]  wall_mean=%.1f ms  wall_p50=%.1f ms  wall_p95=%.1f ms  reads_mean=%.0f  throughput=%.1f MiB/s",
      mode.rawValue, mean,
      percentile(walls, 0.50),
      percentile(walls, 0.95),
      avgReads, mbps))
  print("---")
}

let payload: URL
do {
  payload = try makePayloadFile()
} catch {
  FileHandle.standardError.write(Data("bench: payload error: \(error)\n".utf8))
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
      Data("bench: unknown mode. valid: \(valid)\n".utf8))
    exit(2)
  }
}

for mode in modes {
  switch mode {
  case .snapshotLatency: runSnapshotLatency(payload: payload)
  case .processMetadata: runProcessMetadata(payload: payload)
  case .agentMetadata: runAgentMetadata(payload: payload)
  default: runMode(mode, payload: payload)
  }
}
