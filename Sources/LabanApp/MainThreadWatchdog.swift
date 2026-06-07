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
/// ## Distinguishing real stalls from a parked or paused process
///
/// The display-link heartbeat is a cheap fast path, but the link also stops
/// ticking for reasons that are *not* main-thread stalls: the window is hidden
/// or occluded (the link parks to save power), the terminal is idle, or the
/// whole process is suspended (system sleep / App Nap). Historically those
/// produced the large majority of captures — including bogus multi-second
/// "freezes" recorded against a perfectly healthy but idle main thread. Three
/// layers keep them out of the capture set:
///
///  1. A stale heartbeat is never captured on its own. When the heartbeat ages
///     past the threshold the watchdog dispatches a *confirmation probe* onto
///     the main queue. A merely idle/parked main thread services the probe
///     within a tick and the gap evaporates; only a probe that itself cannot
///     run — a genuinely wedged main thread — is recorded. As a bonus the
///     `sample` then runs while the thread is still stuck, so the captured
///     stack shows the real blocker instead of the recovered idle state.
///  2. `CLOCK_UPTIME_RAW` does not advance while the system is asleep, and the
///     watchdog timer measures its own scheduling gap: a large self-gap means
///     the whole process was deferred (sleep / App Nap), so the baseline is
///     reset instead of captured.
///  3. One confirmed wedge is captured exactly once (`confirmGen` episode id),
///     so a single multi-second freeze no longer fans out into a burst of
///     near-duplicate files reporting the same cumulative gap.
///
/// A configurable ceiling remains as a final backstop.
///
/// Control via env vars:
///   LABAN_WATCHDOG=0                  disable entirely
///   LABAN_WATCHDOG_MS=<int>          stall threshold (default 200 ms)
///   LABAN_WATCHDOG_COOLDOWN_MS=<int> min gap between captures (default 5000)
///   LABAN_WATCHDOG_MAX_MS=<int>      artifact ceiling; ignore "stalls" longer
///                                    than this, 0 disables (default 60000)
///   LABAN_WATCHDOG_PAUSE_GAP_MS=<int> watchdog self-gap above which the
///                                    process is treated as paused (default 1000)
///   LABAN_WATCHDOG_KEEP=<int>        max inproc-stall files retained (default 200)
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

  /// One step of the confirmation state machine, kept pure for unit testing.
  /// A stale heartbeat alone is never a stall: it must first be confirmed by a
  /// probe that cannot run on the main queue.
  enum ProbeStep: Equatable {
    /// Heartbeat is fresh — the main thread is demonstrably alive.
    case healthy
    /// Heartbeat is stale and no probe is outstanding — dispatch one.
    case sendProbe
    /// A probe is outstanding but has not yet exceeded the confirm window.
    case awaitingProbe
    /// A dispatched probe has been unable to run for the confirm window — the
    /// main thread is genuinely wedged.
    case confirmed
  }

  private let stallThresholdMs: Int
  private let captureCooldownMs: Int
  private let maxStallMs: Int
  private let pauseGapMs: Int
  private let keepFiles: Int
  private let enabled: Bool
  private let outputDir: URL

  /// Heartbeat timestamp written by the main thread (display-link tick and
  /// serviced confirmation probes), read by the watchdog thread. Int64
  /// reads/writes are naturally atomic on aarch64; the unfair-lock guard exists
  /// to make the read/write ordering explicit for future readers (and to
  /// satisfy strict concurrency).
  private var lastTickNs: Int64 = 0
  private var lastCaptureNs: Int64 = 0
  /// Confirmation-probe state. When the display-link heartbeat goes stale we do
  /// not trust it blindly (the link also parks when the window is hidden or
  /// idle); we dispatch a probe to the main queue and only treat the gap as a
  /// real stall if that probe is itself unable to run. `confirmGen` rises on
  /// every probe state change so a single wedge is captured exactly once and a
  /// stale probe that drains after a reset is ignored.
  private var confirmInFlight = false
  private var confirmSentNs: Int64 = 0
  private var confirmGen: UInt64 = 0
  private var capturedGen: UInt64 = 0
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
    self.keepFiles = env["LABAN_WATCHDOG_KEEP"].flatMap(Int.init) ?? 200
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
      "active threshold=\(stallThresholdMs)ms cooldown=\(captureCooldownMs)ms maxStall=\(maxStallMs)ms keep=\(keepFiles) dir=\(outputDir.path)"
    )
  }

  /// Call from the main thread once per displayLink tick. A cheap fast path:
  /// while it keeps arriving the watchdog never needs to probe.
  func heartbeat() {
    let now = uptimeNs()
    os_unfair_lock_lock(&heartbeatLock)
    lastTickNs = now
    os_unfair_lock_unlock(&heartbeatLock)
  }

  // MARK: - Watchdog tick

  /// Pure stall-vs-artifact policy. Order matters: a paused process is detected
  /// first because its heartbeat gap is meaningless; the ceiling is a backstop
  /// for anything that slips past the pause guard.
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

  /// Pure confirmation state machine. A stale heartbeat (`heartbeatAgeMs >=
  /// thresholdMs`) only escalates to `.confirmed` once a dispatched probe has
  /// been unable to run for `confirmTimeoutMs`; until then it asks for a probe
  /// or waits. This is what turns "the render loop stopped ticking" into the
  /// stronger claim "the main thread cannot make progress".
  static func probeStep(
    heartbeatAgeMs: Int,
    thresholdMs: Int,
    probeInFlight: Bool,
    probeOutstandingMs: Int,
    confirmTimeoutMs: Int
  ) -> ProbeStep {
    if heartbeatAgeMs < thresholdMs { return .healthy }
    if !probeInFlight { return .sendProbe }
    if probeOutstandingMs < confirmTimeoutMs { return .awaitingProbe }
    return .confirmed
  }

  private func tick() {
    let now = uptimeNs()
    let prevObserved = lastObservedNs
    lastObservedNs = now
    // 0 on the very first tick — treat as no gap rather than a huge one.
    let selfGapMs = prevObserved == 0 ? 0 : Int((now - prevObserved) / 1_000_000)

    os_unfair_lock_lock(&heartbeatLock)
    let last = lastTickNs
    let inFlight = confirmInFlight
    let sentNs = confirmSentNs
    let gen = confirmGen
    let capGen = capturedGen
    os_unfair_lock_unlock(&heartbeatLock)

    // Whole-process suspension (system sleep, App Nap, throttling): the
    // watchdog timer's own schedule slipped, so the heartbeat gap is an
    // artifact. Reset the baseline and drop any in-flight probe so the next
    // tick measures from now instead of immediately re-firing.
    if selfGapMs > pauseGapMs {
      os_unfair_lock_lock(&heartbeatLock)
      lastTickNs = now
      confirmInFlight = false
      confirmGen &+= 1
      os_unfair_lock_unlock(&heartbeatLock)
      return
    }

    let heartbeatAgeMs = Int((now - last) / 1_000_000)
    let probeOutstandingMs = inFlight ? Int((now - sentNs) / 1_000_000) : 0

    switch Self.probeStep(
      heartbeatAgeMs: heartbeatAgeMs,
      thresholdMs: stallThresholdMs,
      probeInFlight: inFlight,
      probeOutstandingMs: probeOutstandingMs,
      confirmTimeoutMs: stallThresholdMs
    ) {
    case .healthy:
      // Heartbeat is fresh again; retire any probe we no longer need.
      if inFlight { cancelConfirmProbe() }
    case .sendProbe:
      startConfirmProbe(now: now)
    case .awaitingProbe:
      break
    case .confirmed:
      // A probe dispatched to the main queue still has not run: the main thread
      // is genuinely wedged, not merely idle/parked. Capture at most once per
      // episode (one `confirmGen`), then let cooldown/ceiling apply via the
      // shared policy.
      if gen == capGen { break }
      let sinceLastCaptureMs =
        lastCaptureNs == 0 ? Int.max : Int((now - lastCaptureNs) / 1_000_000)
      if case .capture(let ms) = Self.decide(
        heartbeatAgeMs: heartbeatAgeMs,
        selfGapMs: selfGapMs,
        sinceLastCaptureMs: sinceLastCaptureMs,
        thresholdMs: stallThresholdMs,
        pauseGapMs: pauseGapMs,
        cooldownMs: captureCooldownMs,
        maxStallMs: maxStallMs)
      {
        os_unfair_lock_lock(&heartbeatLock)
        lastCaptureNs = now
        capturedGen = gen
        os_unfair_lock_unlock(&heartbeatLock)
        captureSample(stalledForMs: ms)
      }
    }
  }

  /// Dispatch a liveness probe onto the main queue. A responsive main thread
  /// services it within a tick and refreshes the heartbeat (`confirmAlive`); a
  /// wedged main thread cannot, which is what confirms a real stall.
  private func startConfirmProbe(now: Int64) {
    os_unfair_lock_lock(&heartbeatLock)
    confirmInFlight = true
    confirmSentNs = now
    confirmGen &+= 1
    let gen = confirmGen
    os_unfair_lock_unlock(&heartbeatLock)
    DispatchQueue.main.async { [weak self] in
      self?.confirmAlive(generation: gen)
    }
  }

  /// Retire the in-flight probe without treating it as a response. Bumping the
  /// generation makes any late-draining probe a no-op.
  private func cancelConfirmProbe() {
    os_unfair_lock_lock(&heartbeatLock)
    confirmInFlight = false
    confirmGen &+= 1
    os_unfair_lock_unlock(&heartbeatLock)
  }

  /// Runs on the main thread when a probe is serviced — proof the main thread
  /// is alive, so it doubles as a heartbeat. Guarded by `generation` so a probe
  /// that drains after a reset or after its episode ended is ignored.
  private func confirmAlive(generation: UInt64) {
    let now = uptimeNs()
    os_unfair_lock_lock(&heartbeatLock)
    if generation == confirmGen {
      lastTickNs = now
      confirmInFlight = false
    }
    os_unfair_lock_unlock(&heartbeatLock)
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
      pruneOldCaptures()
    } catch {
      // sample missing or sandboxed — silent. This is a debug aid.
    }
  }

  // MARK: - Retention

  /// Pure retention policy: from captures paired with their modification
  /// dates, return the ones to delete so only the `keep` newest survive.
  /// Extracted from `pruneOldCaptures` so the cap is unit-testable without
  /// touching disk. `keep <= 0` disables pruning (returns nothing to delete).
  static func capturesToPrune<T>(_ captures: [(T, Date)], keep: Int) -> [T] {
    guard keep > 0, captures.count > keep else { return [] }
    return
      captures
      .sorted { $0.1 > $1.1 }  // newest first
      .dropFirst(keep)
      .map { $0.0 }
  }

  /// Keep only the most recent `keepFiles` in-process captures. The in-process
  /// path historically never trimmed, letting the directory grow to tens of
  /// thousands of files; only our own `inproc-stall-*` files are touched, never
  /// the external sampler's `<pid>-<name>-*` files. Runs on `queue`, gated
  /// behind the capture cooldown, so the directory scan stays off the main
  /// thread and runs at most once per cooldown window.
  private func pruneOldCaptures() {
    guard keepFiles > 0 else { return }
    let fm = FileManager.default
    guard
      let urls = try? fm.contentsOfDirectory(
        at: outputDir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return }
    func mtime(_ url: URL) -> Date {
      (try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate) ?? .distantPast
    }
    let captures =
      urls
      .filter { $0.lastPathComponent.hasPrefix("inproc-stall-") }
      .map { ($0, mtime($0)) }
    for url in Self.capturesToPrune(captures, keep: keepFiles) {
      try? fm.removeItem(at: url)
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
