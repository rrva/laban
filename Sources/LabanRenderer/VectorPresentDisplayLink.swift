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

  private let link: CAMetalDisplayLink
  private let lock = NSLock()
  private var thread: Thread?
  private var started = false
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
      let runLoop = RunLoop.current
      self.link.add(to: runLoop, forMode: .common)
      // Keep the run loop alive for the link's callbacks until cancelled.
      while !Thread.current.isCancelled {
        runLoop.run(mode: .common, before: Date(timeIntervalSinceNow: 1))
      }
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
    let t = thread
    thread = nil
    started = false
    lock.unlock()
    t?.cancel()
  }

  func metalDisplayLink(
    _ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update
  ) {
    let presented = onPresent?(update.drawable) ?? false
    if presented {
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
