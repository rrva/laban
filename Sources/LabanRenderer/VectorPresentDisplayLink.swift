import Foundation
import Metal
import QuartzCore

/// macOS 26 fast path for vector-renderer presentation. A `CAMetalDisplayLink`
/// delivers an already-acquired drawable in its callback, on a dedicated
/// high-QoS thread, so the renderer never calls `CAMetalLayer.nextDrawable()` on
/// the main thread. That removes the per-frame ~6–7 ms drawable-acquire stall
/// (the "half-rate basin"; see ADR 0026) that the `MetalDrawableScheduler` path
/// can only mitigate, not eliminate.
///
/// The owner supplies `onPresent`, invoked once per vsync with the ready
/// drawable; it blits the renderer's latest offscreen target into the drawable
/// and presents. Idle is handled by the owner returning `false` from `onPresent`
/// when it has nothing new to show for a while, which pauses the link until
/// `notifyContentUpdated()` wakes it — so a quiescent terminal stops presenting
/// (preserving the event-driven, park-when-idle contract of ADR 0018).
@available(macOS 14.0, *)
final class VectorPresentDisplayLink: NSObject, CAMetalDisplayLinkDelegate {
  /// Called on the dedicated present thread with a ready drawable. Return true if
  /// a frame was presented (content was fresh), false if nothing new was shown.
  /// After `idlePauseThreshold` consecutive false returns the link pauses itself.
  var onPresent: ((any CAMetalDrawable) -> Bool)?

  /// Present-side cadence stats: intervals (ms) between successive callbacks that
  /// actually presented a frame, sampled while the link is active. This is the
  /// "did we hit every vsync" truth, unlike the main-thread display-link TICK
  /// interval (which keeps ticking even when content is late). Read via
  /// `presentIntervalStats(reset:)`.
  private var lastPresentTimestamp: CFTimeInterval?
  private var presentIntervalsMs: [Double] = []
  private let statsLock = NSLock()
  private static let presentIntervalRingCap = 4096

  /// Diagnostic counters: total callbacks fired and how many actually presented.
  /// `callbacks == 0` means the link never fired (run-loop/pause bug);
  /// `callbacks > 0, presented == 0` means `onPresent` always returned false (no
  /// published target). Surfaced through `presentIntervalStats`.
  private var callbackCount = 0
  private var presentedCount = 0

  /// Snapshot of present-interval percentiles, optionally clearing the ring.
  func presentIntervalStats(reset: Bool) -> [String: Double] {
    statsLock.lock()
    let s = presentIntervalsMs.sorted()
    let callbacks = callbackCount
    let presented = presentedCount
    if reset {
      presentIntervalsMs.removeAll(keepingCapacity: true)
      lastPresentTimestamp = nil
      callbackCount = 0
      presentedCount = 0
    }
    statsLock.unlock()
    _ = (callbacks, presented)
    guard !s.isEmpty else {
      return ["count": 0, "callbacks": Double(callbacks), "presented": Double(presented)]
    }
    let n = s.count
    let mean = s.reduce(0, +) / Double(n)
    func pct(_ p: Double) -> Double { s[min(n - 1, max(0, Int((Double(n) * p).rounded()) - 1))] }
    let median = pct(0.50)
    let jank = s.filter { $0 > median * 1.5 }.count
    return [
      "count": Double(n), "fps": mean > 0 ? 1000.0 / mean : 0, "meanMs": mean,
      "p50Ms": median, "p95Ms": pct(0.95), "p99Ms": pct(0.99), "maxMs": s[n - 1],
      "jankFrames": Double(jank), "jankPercent": Double(jank) / Double(n) * 100.0,
      "callbacks": Double(callbacks), "presented": Double(presented),
    ]
  }

  private func recordPresentInterval(_ update: CAMetalDisplayLink.Update) {
    let now = update.targetPresentationTimestamp
    statsLock.lock()
    if let last = lastPresentTimestamp {
      let ms = (now - last) * 1000.0
      if ms > 0, ms < 100 {
        presentIntervalsMs.append(ms)
        if presentIntervalsMs.count > Self.presentIntervalRingCap {
          presentIntervalsMs.removeFirst(presentIntervalsMs.count - Self.presentIntervalRingCap)
        }
      }
    }
    lastPresentTimestamp = now
    statsLock.unlock()
  }

  private let link: CAMetalDisplayLink
  private let lock = NSLock()
  private var thread: Thread?
  private var runLoop: CFRunLoop?
  private var started = false
  private var stopRequested = false
  private var idleCallbacks = 0
  /// Consecutive no-new-content callbacks before the link parks. ~8 vsyncs at
  /// 120 Hz ≈ 67 ms: long enough to ride out a brief gap between scroll bursts,
  /// short enough that a truly idle terminal stops blitting promptly.
  private static let idlePauseThreshold = 8

  init(layer: CAMetalLayer) {
    link = CAMetalDisplayLink(metalLayer: layer)
    super.init()
    link.delegate = self
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    // A terminal finishes a frame in ~1–2 ms, so request minimal render lead time
    // for lowest latency; raise toward 2 only if starvation reappears.
    link.preferredFrameLatency = 1
    // Start paused; `notifyContentUpdated()` unpauses on the first rendered frame.
    link.isPaused = true
  }

  /// Spin up the dedicated run-loop thread the link is attached to. Idempotent.
  func start() {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()

    let t = Thread { [weak self] in
      guard let self else { return }
      // Attach the link, then block in CFRunLoopRun(). A plain
      // `RunLoop.run(mode:before:)` loop does NOT reliably service the link's
      // source (it returns on each timeout without delivering callbacks) — in
      // testing it produced zero callbacks, while CFRunLoopRun() delivers the full
      // 120 Hz. Capture the CFRunLoop so `stop()` can end it from another thread.
      self.lock.lock()
      // If stop() already ran in the window before this thread started, bail
      // before entering CFRunLoopRun() — `cancel()` cannot break CFRunLoopRun(),
      // so without this the thread would leak.
      if self.stopRequested {
        self.lock.unlock()
        return
      }
      self.runLoop = CFRunLoopGetCurrent()
      self.lock.unlock()
      self.link.add(to: RunLoop.current, forMode: .common)
      CFRunLoopRun()
    }
    t.qualityOfService = .userInteractive
    t.name = "laban.vector.present-link"
    lock.lock()
    thread = t
    lock.unlock()
    t.start()
  }

  /// The renderer produced new content; ensure the link is running so it presents.
  func notifyContentUpdated() {
    lock.lock()
    idleCallbacks = 0
    lock.unlock()
    // Setting isPaused is safe from any thread; a paused link won't fire to check
    // a flag, so it must be unpaused directly here.
    if link.isPaused {
      link.isPaused = false
    }
  }

  func stop() {
    link.isPaused = true
    lock.lock()
    stopRequested = true
    let t = thread
    let rl = runLoop
    thread = nil
    runLoop = nil
    started = false
    lock.unlock()
    // If the thread already entered CFRunLoopRun(), stop it; if it has not yet
    // captured its run loop, `stopRequested` makes it bail before CFRunLoopRun().
    if let rl { CFRunLoopStop(rl) }
    t?.cancel()
  }

  func metalDisplayLink(
    _ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update
  ) {
    let presented = onPresent?(update.drawable) ?? false
    statsLock.lock()
    callbackCount += 1
    if presented { presentedCount += 1 }
    statsLock.unlock()
    if presented {
      recordPresentInterval(update)
      lock.lock()
      idleCallbacks = 0
      lock.unlock()
      return
    }
    lock.lock()
    idleCallbacks += 1
    let shouldPause = idleCallbacks >= Self.idlePauseThreshold
    lock.unlock()
    if shouldPause {
      link.isPaused = true
    }
  }
}
