import Foundation
import Metal
import QuartzCore

final class MetalDrawableScheduler {
  private static let drawableAcquireTimeout: DispatchTimeInterval = .milliseconds(8)

  private let layer: CAMetalLayer
  private let drawableQueue = DispatchQueue(label: "laban.metal-drawable", qos: .userInteractive)
  private let drawableRequestLock = NSLock()
  private var drawableRequestActive = false

  /// Limits frames in flight to 1. CAMetalLayer hands out up to 3 drawables
  /// in parallel, but MetalRenderer's persistent target + scratch textures are
  /// shared resources. Without serialization, frame N could read the target
  /// while frame N+1 writes it.
  private let frameInFlight = DispatchSemaphore(value: 1)

  init(layer: CAMetalLayer) {
    self.layer = layer
  }

  func beginFrame(needsFullFrame: Bool) -> Frame? {
    let timeout: DispatchTime = needsFullFrame ? .now() + .milliseconds(16) : .now()
    guard frameInFlight.wait(timeout: timeout) == .success else {
      return nil
    }
    return Frame(scheduler: self)
  }

  private func finishFrame() {
    frameInFlight.signal()
  }

  private func acquireDrawableWithinBudget() -> (any CAMetalDrawable)? {
    drawableRequestLock.lock()
    if drawableRequestActive {
      drawableRequestLock.unlock()
      return nil
    }
    drawableRequestActive = true
    drawableRequestLock.unlock()

    let completed = DispatchSemaphore(value: 0)
    let state = DrawableAcquisitionState()

    drawableQueue.async { [self] in
      let drawable = layer.nextDrawable()
      if state.fulfill(drawable) {
        completed.signal()
      }

      drawableRequestLock.lock()
      drawableRequestActive = false
      drawableRequestLock.unlock()
    }

    if completed.wait(timeout: .now() + Self.drawableAcquireTimeout) == .success {
      return state.take()
    }

    state.cancel()
    return nil
  }

  final class Frame: @unchecked Sendable {
    private let scheduler: MetalDrawableScheduler
    private let lock = NSLock()
    private var finished = false

    fileprivate init(scheduler: MetalDrawableScheduler) {
      self.scheduler = scheduler
    }

    func acquireDrawable() -> (any CAMetalDrawable)? {
      scheduler.acquireDrawableWithinBudget()
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
