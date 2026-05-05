import Darwin
import Foundation

/// Detects main-thread stalls and captures a real stack trace via
/// `/usr/bin/sample` to disk so we can diagnose freezes after the fact.
///
/// Why `sample` instead of an in-process backtrace: `Thread.callStackSymbols`
/// only walks the *calling* thread, and capturing the main thread's stack
/// from a background thread requires Mach-API task-port introspection plus
/// frame-pointer walking — fragile and signal-unsafe. `sample` is the
/// kernel-blessed tool for this and is rock-solid even when the target's
/// main thread is wedged.
///
/// Control via env vars:
///   LABAN_WATCHDOG=0           disable entirely
///   LABAN_WATCHDOG_MS=<int>    stall threshold (default 200 ms)
///   LABAN_WATCHDOG_COOLDOWN_MS=<int>  min gap between captures (default 5000)
final class MainThreadWatchdog {

  static let shared = MainThreadWatchdog()

  private let stallThresholdMs: Int
  private let captureCooldownMs: Int
  private let enabled: Bool
  private let outputDir: URL

  /// Heartbeat timestamp written by the main thread, read by the watchdog
  /// thread. Int64 reads/writes are naturally atomic on aarch64; the
  /// unfair-lock guard exists to make the read/write ordering explicit
  /// for future readers (and to satisfy strict concurrency).
  private var lastTickNs: Int64 = 0
  private var lastCaptureNs: Int64 = 0
  private var heartbeatLock = os_unfair_lock()

  private let queue = DispatchQueue(label: "laban.watchdog", qos: .utility)
  private var timer: DispatchSourceTimer?

  private init() {
    let env = ProcessInfo.processInfo.environment
    self.enabled = env["LABAN_WATCHDOG"] != "0"
    self.stallThresholdMs = env["LABAN_WATCHDOG_MS"].flatMap(Int.init) ?? 200
    self.captureCooldownMs =
      env["LABAN_WATCHDOG_COOLDOWN_MS"].flatMap(Int.init) ?? 5000
    self.outputDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("laban-watchdog")
    try? FileManager.default.createDirectory(
      at: outputDir, withIntermediateDirectories: true)
  }

  /// Start the background poller. Idempotent.
  func start() {
    guard enabled, timer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
    t.setEventHandler { [weak self] in self?.tick() }
    self.timer = t
    heartbeat()  // prime so the first comparison is meaningful
    t.resume()
    fputs(
      "laban: watchdog active (threshold=\(stallThresholdMs)ms cooldown=\(captureCooldownMs)ms dir=\(outputDir.path))\n",
      stderr)
  }

  /// Call from the main thread once per displayLink tick.
  func heartbeat() {
    let now = monotonicNs()
    os_unfair_lock_lock(&heartbeatLock)
    lastTickNs = now
    os_unfair_lock_unlock(&heartbeatLock)
  }

  // MARK: - Watchdog tick

  private func tick() {
    let now = monotonicNs()
    os_unfair_lock_lock(&heartbeatLock)
    let last = lastTickNs
    os_unfair_lock_unlock(&heartbeatLock)
    let elapsedNs = now - last
    let elapsedMs = Int(elapsedNs / 1_000_000)
    guard elapsedMs >= stallThresholdMs else { return }
    if (now - lastCaptureNs) / 1_000_000 < Int64(captureCooldownMs) { return }
    lastCaptureNs = now
    captureSample(stalledForMs: elapsedMs)
  }

  private func captureSample(stalledForMs: Int) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let stamp = Self.timestampString()
    let outURL = outputDir.appendingPathComponent(
      "inproc-stall-\(stalledForMs)ms-\(stamp).txt")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    task.arguments = [String(pid), "2", "-mayDie", "-file", outURL.path]
    task.standardOutput = nil
    task.standardError = nil
    do {
      try task.run()
      fputs(
        "laban: watchdog captured stall (\(stalledForMs)ms) → \(outURL.path)\n",
        stderr)
    } catch {
      // sample missing or sandboxed — silent. This is a debug aid.
    }
  }

  // MARK: - Helpers

  private func monotonicNs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
  }

  private static func timestampString() -> String {
    var tv = timeval()
    gettimeofday(&tv, nil)
    var t = time_t(tv.tv_sec)
    var tm = tm()
    localtime_r(&t, &tm)
    return String(
      format: "%04d%02d%02d-%02d%02d%02d.%03d",
      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
      tm.tm_hour, tm.tm_min, tm.tm_sec, Int(tv.tv_usec) / 1000)
  }
}
