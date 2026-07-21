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
/// and presents. Run state is driven EXTERNALLY via `setRunning(_:)`: the host
/// view already computes a unified animate-or-park policy (`displayLinkShouldRun`
/// — false when the window is unfocused, occluded, or focused-but-idle, with
/// hysteresis that keeps the link running long enough to present the last visible
/// frame) and drives its main `CADisplayLink` from it. This present link rides the
/// same signal, so when the terminal parks the present thread stops firing and
/// costs ~zero CPU (the previous self-detected idle never actually parked).
/// Preserves the event-driven park-when-idle contract of ADR 0018.
/// Pure, GPU-free model of the present link's deferred-park decision, so the
/// "don't park while a freshly published frame is unpresented" logic is unit
/// testable without a Metal device. The link itself just applies `wantsPaused`.
struct PresentParkDecision: Equatable {
  /// The host idle policy's last intent (`setRunning(_:)`): true = run.
  private(set) var hostWantsRunning = false
  /// Vsync callbacks remaining to flush a published-but-unpresented frame even
  /// though the host asked to park.
  private(set) var pendingBudget = 0
  let budgetCallbacks: Int

  init(budgetCallbacks: Int) { self.budgetCallbacks = budgetCallbacks }

  /// Should the underlying link be paused right now?
  var wantsPaused: Bool { !hostWantsRunning && pendingBudget <= 0 }

  /// Host idle policy update. Running clears any deferral; parking is deferred
  /// while a frame is pending.
  mutating func setHostRunning(_ running: Bool) { hostWantsRunning = running }

  /// A new frame was published — keep presenting for up to `budgetCallbacks`
  /// vsyncs so it reaches the screen even if the host wants to park.
  mutating func contentPublished() { pendingBudget = budgetCallbacks }

  /// A vsync callback fired. A successful present clears the deferral; otherwise
  /// the budget decrements so a stuck pending cannot pin the link forever.
  mutating func didCallback(presented: Bool) {
    guard pendingBudget > 0 else { return }
    pendingBudget = presented ? 0 : pendingBudget - 1
  }
}

@available(macOS 14.0, *)
private func configurePresentLink(
  _ link: CAMetalDisplayLink, delegate: any CAMetalDisplayLinkDelegate
) {
  link.delegate = delegate
  link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
  // A terminal finishes a frame in ~1–2 ms, but live scroll traces can still
  // miss whole present callbacks with latency 1. Give Core Animation one more
  // frame of scheduling slack so the display-link presenter holds 120 Hz.
  link.preferredFrameLatency = 2
  // Start paused; `notifyContentUpdated()` unpauses on the first rendered frame.
  link.isPaused = true
}

@available(macOS 14.0, *)
final class VectorPresentDisplayLink: NSObject, CAMetalDisplayLinkDelegate {
  /// Called on the dedicated present thread with a ready drawable; blits the
  /// latest target and presents. Return value is advisory (stats only): the link's
  /// run state is controlled externally via `setRunning(_:)`, not by this result.
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

  /// Deferred-park decision state (host intent + pending-present budget). Guarded
  /// by `statsLock`. See `PresentParkDecision`.
  private var park: PresentParkDecision
  /// Max vsyncs to keep the parked link alive waiting for a publish to present.
  /// A frame normally presents on the very next callback; this is generous slack.
  private static let pendingPresentBudgetCallbacks = 4

  /// Snapshot of present-interval percentiles, optionally clearing the ring.
  func presentIntervalStats(reset: Bool) -> [String: Double] {
    statsLock.lock()
    let s = presentIntervalsMs.sorted()
    let callbacks = callbackCount
    let presented = presentedCount
    let rebuilds = rebuildCount
    if reset {
      presentIntervalsMs.removeAll(keepingCapacity: true)
      lastPresentTimestamp = nil
      callbackCount = 0
      presentedCount = 0
    }
    statsLock.unlock()
    _ = (callbacks, presented)
    guard !s.isEmpty else {
      return [
        "count": 0, "callbacks": Double(callbacks), "presented": Double(presented),
        "rebuilds": Double(rebuilds),
      ]
    }
    let n = s.count
    let mean = s.reduce(0, +) / Double(n)
    func pct(_ p: Double) -> Double { s[min(n - 1, max(0, Int((Double(n) * p).rounded()) - 1))] }
    let median = pct(0.50)
    let jankIntervals = s.filter { $0 > median * 1.5 }
    let jank = jankIntervals.count
    let twoVsyncGaps = jankIntervals.filter { $0 <= median * 2.5 }.count
    let longerGaps = jank - twoVsyncGaps
    let estimatedMissedVsyncs =
      median > 0
      ? jankIntervals.reduce(0) { total, interval in
        total + max(0, Int((interval / median).rounded()) - 1)
      }
      : 0
    return [
      "count": Double(n), "fps": mean > 0 ? 1000.0 / mean : 0, "meanMs": mean,
      "p50Ms": median, "p95Ms": pct(0.95), "p99Ms": pct(0.99), "maxMs": s[n - 1],
      "jankFrames": Double(jank), "jankPercent": Double(jank) / Double(n) * 100.0,
      "callbacks": Double(callbacks), "presented": Double(presented),
      "twoVsyncGaps": Double(twoVsyncGaps), "longerGaps": Double(longerGaps),
      "estimatedMissedVsyncs": Double(estimatedMissedVsyncs),
      "rebuilds": Double(rebuilds),
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

  private let layer: CAMetalLayer
  /// The live link. Mutated only on the present thread during `rebuild()`;
  /// read from any thread under `lock` so a swap never tears a caller.
  private var link: CAMetalDisplayLink
  private let lock = NSLock()
  private var thread: Thread?
  private var runLoop: CFRunLoop?
  private var started = false
  private var stopRequested = false
  /// A rebuild requested before the present thread captured its run loop;
  /// consumed inside `start()` once the link is attached. Guarded by `lock`.
  private var rebuildPending = false
  /// How many times the link was rebuilt after a display reconfiguration.
  /// Surfaced through `presentIntervalStats` as `rebuilds`.
  private var rebuildCount = 0

  init(layer: CAMetalLayer) {
    self.layer = layer
    link = CAMetalDisplayLink(metalLayer: layer)
    park = PresentParkDecision(budgetCallbacks: Self.pendingPresentBudgetCallbacks)
    super.init()
    configurePresentLink(link, delegate: self)
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
      let link = self.link
      let pendingRebuild = self.rebuildPending
      self.rebuildPending = false
      self.lock.unlock()
      link.add(to: RunLoop.current, forMode: .common)
      // A rebuild requested before this thread captured its run loop is
      // honored now, directly on the present thread.
      if pendingRebuild {
        self.performRebuildSwap()
      }
      CFRunLoopRun()
    }
    t.qualityOfService = .userInteractive
    t.name = "laban.vector.present-link"
    lock.lock()
    thread = t
    lock.unlock()
    t.start()
  }

  /// Drive the link's run state from the host's animate-or-park policy. `true`
  /// (active: focused + visible + output/scroll/blink/idle-floor) runs the link at
  /// the panel rate; `false` (parked: unfocused, occluded, or focused-and-idle)
  /// pauses it so the present thread fires zero callbacks and costs ~zero CPU.
  /// Idempotent and safe to call every frame from the main thread.
  ///
  /// A park request is DEFERRED while a freshly published frame has not yet
  /// reached the screen (`pendingPresentBudget > 0`). The idle policy's inputs
  /// (visibility/output/scroll/blink) do not include "rendered but not yet
  /// presented", so a one-shot content change with no follow-on activity — the
  /// initial frame, or a tab switch — would otherwise publish a target and then
  /// park the link before it ever presented it, leaving the screen blank until
  /// the next keystroke/scroll. Honoring the park only after the pending frame
  /// presents fixes that without changing the idle policy.
  func setRunning(_ running: Bool) {
    statsLock.lock()
    park.setHostRunning(running)
    let pause = park.wantsPaused
    statsLock.unlock()
    // Pause only when the decision says so (host parked AND no pending frame).
    // Otherwise keep running: the callback parks once the pending frame presents.
    lock.lock()
    let link = self.link
    lock.unlock()
    if link.isPaused != pause { link.isPaused = pause }
  }

  /// Tell the link a new frame was published into the shared target. Ensures the
  /// link runs long enough to actually present it even if the host idle policy
  /// has asked to park (tab switch / initial frame produce no scroll/output, so
  /// the policy would otherwise park immediately). Safe to call from the render
  /// completion handler on any thread.
  func notifyContentPublished() {
    statsLock.lock()
    park.contentPublished()
    statsLock.unlock()
    // Unpause now so the next vsync presents the new frame; the callback parks
    // again afterward if the host still wants idle.
    lock.lock()
    let link = self.link
    lock.unlock()
    if link.isPaused { link.isPaused = false }
  }

  /// Test/debug seam: the live link's paused state, read under the swap lock.
  var debugLinkIsPaused: Bool {
    lock.lock()
    defer { lock.unlock() }
    return link.isPaused
  }

  /// Rebuild the `CAMetalDisplayLink` on the present thread after a display
  /// reconfiguration (display unplugged, clamshell close, mode change, window
  /// moved across screens). A link whose display disappears keeps a dead vsync
  /// port in the run loop's wait set: it never fires again (the published
  /// frames pile up unpresented — a frozen terminal), and when the run loop
  /// eventually services the dead port CoreFoundation aborts in
  /// `__CFRunLoopServiceMachPort.cold.1` (EXC_BREAKPOINT, observed 2026-07-21
  /// after a clamshell close + external-display detach). Swapping in a fresh
  /// link rebinds to the current display and drops the dead port from the wait
  /// set. Deferred (not dropped) while the present thread has not yet captured
  /// its run loop; no-op after `stop()`.
  func rebuild() {
    lock.lock()
    guard started, !stopRequested else {
      lock.unlock()
      return
    }
    guard let rl = runLoop else {
      rebuildPending = true
      lock.unlock()
      return
    }
    lock.unlock()
    CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
      self?.performRebuildSwap()
    }
    CFRunLoopWakeUp(rl)
  }

  /// The link swap. Must run on the present thread (it adds the new link to
  /// that thread's run loop); guards against a stop() that raced the queue.
  private func performRebuildSwap() {
    lock.lock()
    guard started, !stopRequested else {
      lock.unlock()
      return
    }
    let oldLink = link
    let newLink = CAMetalDisplayLink(metalLayer: layer)
    configurePresentLink(newLink, delegate: self)
    link = newLink
    lock.unlock()
    // Preserve the host's current run/park intent so the swap neither
    // restarts a parked terminal nor freezes an active one.
    statsLock.lock()
    let paused = park.wantsPaused
    statsLock.unlock()
    oldLink.invalidate()
    newLink.isPaused = paused
    newLink.add(to: RunLoop.current, forMode: .common)
    statsLock.lock()
    rebuildCount += 1
    statsLock.unlock()
  }

  func stop() {
    lock.lock()
    link.isPaused = true
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
    // Always re-present the latest target so the display holds the panel rate even
    // on vsyncs where content did not re-render (a presented frame stays on screen
    // until replaced; re-presenting is a ~0.05 ms blit). The link only fires while
    // the host policy says active — `setRunning(false)` parks it when idle.
    let presented = onPresent?(update.drawable) ?? false
    statsLock.lock()
    callbackCount += 1
    if presented { presentedCount += 1 }
    // Resolve the deferred-park budget: a successful present clears it (the
    // freshly published frame is now on screen); otherwise it decrements so a
    // stuck pending (e.g. drawable-size mismatch after resize, onPresent always
    // false) cannot keep the link spinning forever.
    park.didCallback(presented: presented)
    let parkNow = park.wantsPaused
    statsLock.unlock()
    if presented { recordPresentInterval(update) }
    // Honor a host park request that was deferred while a frame was pending,
    // now that the frame has presented (or the budget expired).
    if parkNow, !link.isPaused {
      link.isPaused = true
    }
  }
}
