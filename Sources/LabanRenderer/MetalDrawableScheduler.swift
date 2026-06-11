import Foundation
import Metal
import QuartzCore

final class MetalDrawableScheduler {
  private static let drawableAcquireTimeout: DispatchTimeInterval = .milliseconds(8)
  private static let drawableAcquireBudgetMs = 8.0

  private let layer: CAMetalLayer
  private let drawableQueue = DispatchQueue(label: "laban.metal-drawable", qos: .userInteractive)
  private let drawableRequestLock = NSLock()
  private var drawableRequestActive = false
  /// A drawable that `nextDrawable()` returned *after* its caller's budget
  /// expired. Instead of dropping it (wasting a pool slot until ARC) and leaving
  /// `drawableRequestActive` to fast-fail every subsequent acquire — the poison
  /// gate that turned one ~16ms drawable-drain wait into a burst of failed
  /// frames — it is parked here and handed to the next acquire. Always touched
  /// under `drawableRequestLock`.
  private var pendingDrawable: (any CAMetalDrawable)?
  /// Post→return latency of the most recent background `nextDrawable()`.
  /// Touched under `drawableRequestLock`; surfaced through the acquire
  /// diagnostic so the render journal can tell display-locked recycling
  /// (~16.7 ms sharp) from GPU-bound frames (~9-12 ms).
  private var lastRequestLatencyMs: Double?
  /// True when a non-blocking acquire came up empty since the last
  /// successful hand-off. Touched under `drawableRequestLock`.
  private var consumerMissedSinceLastAcquire = false
  /// Fired (on the drawable queue) when a prefetched drawable parks while a
  /// consumer is known to have missed — the escape hatch from the half-rate
  /// equilibrium. In the 60 Hz basin, drawables recycle only per display
  /// swap (~16.7 ms), so a request posted after each carry always misses the
  /// next 8.3 ms tick; rendering immediately when the drawable lands
  /// presents a second frame into the same swap interval, doubling the swap
  /// rate and flipping the pipeline back into the self-sustaining 120 Hz
  /// basin. The receiver must hop to its own queue/thread.
  var onDrawableReadyAfterMiss: (() -> Void)?

  /// Limits frames in flight to 1. CAMetalLayer hands out up to 3 drawables
  /// in parallel, but MetalRenderer's persistent target + scratch textures are
  /// shared resources. Without serialization, frame N could read the target
  /// while frame N+1 writes it.
  private let frameInFlight = DispatchSemaphore(value: 1)

  init(layer: CAMetalLayer) {
    self.layer = layer
  }

  func beginFrame(needsFullFrame: Bool, dropIfBusy: Bool = false) -> Frame? {
    // dropIfBusy: resampled smooth-scroll frames must never block the main
    // thread waiting for pipeline capacity — a skipped tick is repainted one
    // tick later from newer state, while a blocked tick delays the *next*
    // tick and locks the cadence at half rate (the demand-over-capacity
    // queueing cliff: ~120 frames/s demanded vs ~117 sustainable).
    let timeout: DispatchTime =
      (needsFullFrame && !dropIfBusy) ? .now() + .milliseconds(16) : .now()
    guard frameInFlight.wait(timeout: timeout) == .success else {
      return nil
    }
    return Frame(scheduler: self)
  }

  private func finishFrame() {
    frameInFlight.signal()
  }

  private func acquireDrawableWithinBudget(nonBlocking: Bool = false) -> DrawableAcquireResult {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let layerMaximumDrawableCount = layer.maximumDrawableCount
    let layerAllowsNextDrawableTimeout = layer.allowsNextDrawableTimeout

    drawableRequestLock.lock()
    let activeBefore = drawableRequestActive
    let pendingBefore = pendingDrawable != nil
    // Carry-forward: a prior acquire that timed out left its drawable here once
    // `nextDrawable()` finally returned. Reuse it rather than fast-failing or
    // acquiring a second drawable from the pool. Caller validates size against
    // the current surface and drops on mismatch (MetalRenderer's
    // `drawableSizeMismatch` guard), so a stale-sized carry-forward is safe.
    if let carried = pendingDrawable {
      pendingDrawable = nil
      consumerMissedSinceLastAcquire = false
      // Prefetch-on-carry: a non-blocking caller consuming the parked
      // drawable immediately posts the next async request, so the next tick
      // finds a drawable waiting instead of posting-and-missing. Without
      // this, saturation settles into a stable render/miss alternation —
      // carried ticks never request, requesting ticks never have one — and
      // a 120 Hz panel locks at exactly half rate.
      var prefetch = false
      if nonBlocking && !drawableRequestActive {
        drawableRequestActive = true
        prefetch = true
      }
      let activeAfter = drawableRequestActive
      let pendingAfter = pendingDrawable != nil
      drawableRequestLock.unlock()
      if prefetch {
        prefetchNextDrawable()
      }
      return DrawableAcquireResult(
        drawable: carried,
        diagnostic: diagnostic(
          outcome: .carried,
          startedAt: startedAt,
          activeBefore: activeBefore,
          activeAfter: activeAfter,
          pendingBefore: pendingBefore,
          pendingAfter: pendingAfter,
          layerMaximumDrawableCount: layerMaximumDrawableCount,
          layerAllowsNextDrawableTimeout: layerAllowsNextDrawableTimeout))
    }
    if drawableRequestActive {
      // A request is still parked in `nextDrawable()`. Don't start a second one
      // and don't poison subsequent frames — just miss this tick; the next one
      // picks up `pendingDrawable`.
      if nonBlocking {
        consumerMissedSinceLastAcquire = true
      }
      let activeAfter = drawableRequestActive
      let pendingAfter = pendingDrawable != nil
      drawableRequestLock.unlock()
      return DrawableAcquireResult(
        drawable: nil,
        diagnostic: diagnostic(
          outcome: .activeRequest,
          startedAt: startedAt,
          activeBefore: activeBefore,
          activeAfter: activeAfter,
          pendingBefore: pendingBefore,
          pendingAfter: pendingAfter,
          layerMaximumDrawableCount: layerMaximumDrawableCount,
          layerAllowsNextDrawableTimeout: layerAllowsNextDrawableTimeout))
    }
    drawableRequestActive = true
    drawableRequestLock.unlock()

    let completed = DispatchSemaphore(value: 0)
    let state = DrawableAcquisitionState()

    let requestPostedAt = DispatchTime.now().uptimeNanoseconds
    drawableQueue.async { [self] in
      let drawable = layer.nextDrawable()
      let latencyMs =
        Double(DispatchTime.now().uptimeNanoseconds &- requestPostedAt) / 1_000_000.0
      let claimedByWaiter = state.fulfill(drawable)
      if claimedByWaiter {
        completed.signal()
      }

      drawableRequestLock.lock()
      lastRequestLatencyMs = latencyMs
      // The caller already gave up: stash the late drawable for the next acquire
      // instead of dropping it. Clearing `drawableRequestActive` in the same
      // critical section keeps the stash visible before a new request can start.
      var catchUp: (() -> Void)?
      if !claimedByWaiter, let drawable {
        pendingDrawable = drawable
        if consumerMissedSinceLastAcquire {
          consumerMissedSinceLastAcquire = false
          catchUp = onDrawableReadyAfterMiss
        }
      }
      drawableRequestActive = false
      drawableRequestLock.unlock()
      catchUp?()
    }

    // Non-blocking callers take an instantly-available drawable but never
    // wait: a late drawable parks in `pendingDrawable` (the existing
    // carry-forward) and the next tick picks it up.
    let waitDeadline: DispatchTime = nonBlocking ? .now() : .now() + Self.drawableAcquireTimeout
    if completed.wait(timeout: waitDeadline) == .success {
      let drawable = state.take()
      let (activeAfter, pendingAfter) = requestSnapshot()
      return DrawableAcquireResult(
        drawable: drawable,
        diagnostic: diagnostic(
          outcome: drawable == nil ? .returnedNil : .returnedDrawable,
          startedAt: startedAt,
          activeBefore: activeBefore,
          activeAfter: activeAfter,
          pendingBefore: pendingBefore,
          pendingAfter: pendingAfter,
          layerMaximumDrawableCount: layerMaximumDrawableCount,
          layerAllowsNextDrawableTimeout: layerAllowsNextDrawableTimeout))
    }

    state.cancel()
    if nonBlocking {
      drawableRequestLock.lock()
      consumerMissedSinceLastAcquire = true
      drawableRequestLock.unlock()
    }
    let (activeAfter, pendingAfter) = requestSnapshot()
    return DrawableAcquireResult(
      drawable: nil,
      diagnostic: diagnostic(
        outcome: .timedOut,
        startedAt: startedAt,
        activeBefore: activeBefore,
        activeAfter: activeAfter,
        pendingBefore: pendingBefore,
        pendingAfter: pendingAfter,
        layerMaximumDrawableCount: layerMaximumDrawableCount,
        layerAllowsNextDrawableTimeout: layerAllowsNextDrawableTimeout))
  }

  /// Background `nextDrawable()` whose result parks directly in
  /// `pendingDrawable` for the next acquire. Caller must have set
  /// `drawableRequestActive` under the lock before invoking.
  private func prefetchNextDrawable() {
    let requestPostedAt = DispatchTime.now().uptimeNanoseconds
    drawableQueue.async { [self] in
      let drawable = layer.nextDrawable()
      let latencyMs =
        Double(DispatchTime.now().uptimeNanoseconds &- requestPostedAt) / 1_000_000.0
      drawableRequestLock.lock()
      lastRequestLatencyMs = latencyMs
      var catchUp: (() -> Void)?
      if let drawable {
        pendingDrawable = drawable
        if consumerMissedSinceLastAcquire {
          consumerMissedSinceLastAcquire = false
          catchUp = onDrawableReadyAfterMiss
        }
      }
      drawableRequestActive = false
      drawableRequestLock.unlock()
      catchUp?()
    }
  }

  private func requestSnapshot() -> (active: Bool, pending: Bool) {
    drawableRequestLock.lock()
    defer { drawableRequestLock.unlock() }
    return (drawableRequestActive, pendingDrawable != nil)
  }

  private func diagnostic(
    outcome: MetalDrawableAcquireDiagnostic.Outcome,
    startedAt: UInt64,
    activeBefore: Bool,
    activeAfter: Bool,
    pendingBefore: Bool,
    pendingAfter: Bool,
    layerMaximumDrawableCount: Int,
    layerAllowsNextDrawableTimeout: Bool
  ) -> MetalDrawableAcquireDiagnostic {
    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startedAt
    drawableRequestLock.lock()
    let requestLatencyMs = lastRequestLatencyMs
    drawableRequestLock.unlock()
    return MetalDrawableAcquireDiagnostic(
      outcome: outcome,
      budgetMs: Self.drawableAcquireBudgetMs,
      elapsedMs: Double(elapsedNs) / 1_000_000.0,
      drawableRequestActiveBefore: activeBefore,
      drawableRequestActiveAfter: activeAfter,
      pendingDrawablePresentBefore: pendingBefore,
      pendingDrawablePresentAfter: pendingAfter,
      layerMaximumDrawableCount: layerMaximumDrawableCount,
      layerAllowsNextDrawableTimeout: layerAllowsNextDrawableTimeout,
      lastRequestLatencyMs: requestLatencyMs)
  }

  final class Frame: @unchecked Sendable {
    private let scheduler: MetalDrawableScheduler
    private let lock = NSLock()
    private var finished = false
    private(set) var lastDrawableAcquireDiagnostic: MetalDrawableAcquireDiagnostic?

    fileprivate init(scheduler: MetalDrawableScheduler) {
      self.scheduler = scheduler
    }

    func acquireDrawable(nonBlocking: Bool = false) -> (any CAMetalDrawable)? {
      let result = scheduler.acquireDrawableWithinBudget(nonBlocking: nonBlocking)
      lastDrawableAcquireDiagnostic = result.diagnostic
      return result.drawable
    }

    func finish() {
      lock.lock()
      guard !finished else {
        lock.unlock()
        return
      }
      finished = true
      lock.unlock()
      scheduler.finishFrame()
    }
  }

  private struct DrawableAcquireResult {
    var drawable: (any CAMetalDrawable)?
    var diagnostic: MetalDrawableAcquireDiagnostic
  }

  private final class DrawableAcquisitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var callerWaiting = true
    private var drawable: (any CAMetalDrawable)?

    func fulfill(_ acquired: (any CAMetalDrawable)?) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard callerWaiting else { return false }
      drawable = acquired
      return true
    }

    func take() -> (any CAMetalDrawable)? {
      lock.lock()
      defer { lock.unlock() }
      callerWaiting = false
      let result = drawable
      drawable = nil
      return result
    }

    func cancel() {
      lock.lock()
      callerWaiting = false
      lock.unlock()
    }
  }
}
