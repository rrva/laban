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
/// ## Distinguishing real stalls from a paused process
///
/// The heartbeat is driven by the render loop's display link, which stops
/// ticking whenever the *whole process* is paused — system sleep, App Nap, or
/// occlusion — none of which is a main-thread stall. Two guards keep those out
/// of the capture set (they were the large majority of historical captures,
/// including bogus multi-hour "stalls" recorded across overnight sleep):
///
///  1. The clock is `CLOCK_UPTIME_RAW`, which does *not* advance while the
///     system is asleep, so a sleeping Mac shows no heartbeat gap at all.
///  2. The watchdog timer measures its *own* scheduling gap. A genuine
///     main-thread stall does not delay this background timer (it runs on a
///     separate dispatch queue), so the self-gap stays near one interval. App
///     Nap and throttling defer the timer itself, producing a large self-gap —
///     when that happens the heartbeat gap is an artifact and the baseline is
///     reset instead of captured.
///
/// A configurable ceiling drops any residual oversized capture as a backstop.
///
/// Control via env vars:
///   LABAN_WATCHDOG=0                  disable entirely
///   LABAN_WATCHDOG_MS=<int>          stall threshold (default 200 ms)
///   LABAN_WATCHDOG_COOLDOWN_MS=<int> min gap between captures (default 5000)
///   LABAN_WATCHDOG_MAX_MS=<int>      artifact ceiling; ignore "stalls" longer
///                                    than this, 0 disables (default 60000)
///   LABAN_WATCHDOG_PAUSE_GAP_MS=<int> watchdog self-gap above which the
///                                    process is treated as paused (default 1000)
final class MainThreadWatchdog {

  static let shared = MainThreadWatchdog()

  /// Outcome of evaluating one watchdog tick. Pure data so the policy can be
  /// unit-tested without a real main-thread stall or `/usr/bin/sample`.
  enum Decision: Equatable {
    case belowThreshold
    /// The whole process was suspended; the gap is an artifact. Reset baseline.
    case paused
    case cooldown
    /// Above the artifact ceiling — almost certainly not a real UI hang.
    case aboveCeiling
    case capture(stalledForMs: Int)
  }

  private let stallThresholdMs: Int
  private let captureCooldownMs: Int
  private let maxStallMs: Int
  private let pauseGapMs: Int
  private let enabled: Bool
  private let outputDir: URL

  /// Heartbeat timestamp written by the main thread, read by the watchdog
  /// thread. Int64 reads/writes are naturally atomic on aarch64; the
  /// unfair-lock guard exists to make the read/write ordering explicit
  /// for future readers (and to satisfy strict concurrency).
  private var lastTickNs: Int64 = 0
  private var lastCaptureNs: Int64 = 0
  private var heartbeatLock = os_unfair_lock()

  /// Uptime at the previous watchdog tick, used to measure the timer's own
  /// scheduling gap. Touched only on `queue`, so it needs no lock.
  private var lastObservedNs: Int64 = 0

  private let intervalMs = 50

  private let queue = DispatchQueue(label: "laban.watchdog", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var sampleTasks: [Process] = []

  private init() {
    let env = ProcessInfo.processInfo.environment
    self.enabled = env["LABAN_WATCHDOG"] != "0"
    self.stallThresholdMs = env["LABAN_WATCHDOG_MS"].flatMap(Int.init) ?? 200
    self.captureCooldownMs =
      env["LABAN_WATCHDOG_COOLDOWN_MS"].flatMap(Int.init) ?? 5000
    self.maxStallMs = env["LABAN_WATCHDOG_MAX_MS"].flatMap(Int.init) ?? 60000
    self.pauseGapMs =
      env["LABAN_WATCHDOG_PAUSE_GAP_MS"].flatMap(Int.init) ?? 1000
    self.outputDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("laban-watchdog")
    try? FileManager.default.createDirectory(
      at: outputDir, withIntermediateDirectories: true)
  }

  /// Start the background poller. Idempotent.
  func start() {
    guard enabled, timer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(
      deadline: .now() + .milliseconds(intervalMs),
      repeating: .milliseconds(intervalMs))
    t.setEventHandler { [weak self] in self?.tick() }
    self.timer = t
    heartbeat()  // prime so the first comparison is meaningful
    t.resume()
    AppLog.watchdog.info(
      "active threshold=\(stallThresholdMs)ms cooldown=\(captureCooldownMs)ms maxStall=\(maxStallMs)ms dir=\(outputDir.path)"
    )
  }

  /// Call from the main thread once per displayLink tick.
  func heartbeat() {
    let now = uptimeNs()
    os_unfair_lock_lock(&heartbeatLock)
    lastTickNs = now
    os_unfair_lock_unlock(&heartbeatLock)
  }

  // MARK: - Watchdog tick

  /// Pure stall-vs-artifact policy. Order matters: a paused process is detected
  /// first because its heartbeat gap is meaningless; the ceiling is a backstop
  /// for anything that slips past the pause guard (e.g. occlusion that stops
  /// the display link while the watchdog timer keeps its own schedule).
  static func decide(
    heartbeatAgeMs: Int,
    selfGapMs: Int,
    sinceLastCaptureMs: Int,
    thresholdMs: Int,
    pauseGapMs: Int,
    cooldownMs: Int,
    maxStallMs: Int
  ) -> Decision {
    if selfGapMs > pauseGapMs { return .paused }
    if heartbeatAgeMs < thresholdMs { return .belowThreshold }
    if sinceLastCaptureMs < cooldownMs { return .cooldown }
    if maxStallMs > 0, heartbeatAgeMs > maxStallMs { return .aboveCeiling }
    return .capture(stalledForMs: heartbeatAgeMs)
  }

  private func tick() {
    let now = uptimeNs()
    let prevObserved = lastObservedNs
    lastObservedNs = now
    // 0 on the very first tick — treat as no gap rather than a huge one.
    let selfGapMs = prevObserved == 0 ? 0 : Int((now - prevObserved) / 1_000_000)

    os_unfair_lock_lock(&heartbeatLock)
    let last = lastTickNs
    os_unfair_lock_unlock(&heartbeatLock)
    let heartbeatAgeMs = Int((now - last) / 1_000_000)
    let sinceLastCaptureMs =
      lastCaptureNs == 0 ? Int.max : Int((now - lastCaptureNs) / 1_000_000)

    switch Self.decide(
      heartbeatAgeMs: heartbeatAgeMs,
      selfGapMs: selfGapMs,
      sinceLastCaptureMs: sinceLastCaptureMs,
      thresholdMs: stallThresholdMs,
      pauseGapMs: pauseGapMs,
      cooldownMs: captureCooldownMs,
      maxStallMs: maxStallMs
    ) {
    case .paused:
      // Whole process was suspended (system sleep, App Nap, throttling): the
      // heartbeat gap is an artifact. Reset the baseline so the next tick
      // measures from now instead of immediately re-firing.
      heartbeat()
    case .belowThreshold, .cooldown, .aboveCeiling:
      break
    case .capture(let ms):
      lastCaptureNs = now
      captureSample(stalledForMs: ms)
    }
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
    task.terminationHandler = { [weak self] process in
      self?.queue.async { [weak self] in
        self?.sampleTasks.removeAll { $0 === process }
      }
    }
    do {
      try task.run()
      sampleTasks.append(task)
      AppLog.watchdog.notice("captured stall \(stalledForMs)ms → \(outURL.path)")
      EventLog.shared.log(
        "watchdog.stall",
        ["ms": stalledForMs, "path": outURL.path])
    } catch {
      // sample missing or sandboxed — silent. This is a debug aid.
    }
  }

  // MARK: - Helpers

  /// Uptime in nanoseconds. `CLOCK_UPTIME_RAW` does not advance while the
  /// system is asleep, so an overnight sleep produces no phantom heartbeat gap.
  private func uptimeNs() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_UPTIME_RAW, &ts)
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
