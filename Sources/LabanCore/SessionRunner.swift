import Darwin
import Foundation
import LabanTerminalCore
import os

/// Owns a dedicated thread that drains a session's PTY off the main
/// thread so terminal output is not gated on the display refresh.
///
/// Lifetime contract: create one runner per Session, call `start()`
/// after the session is ready, call `stop()` *before* the session is
/// closed/destroyed. The runner thread parks in
/// `laban_session_poll_blocking` between drains; `stop()` flips an
/// atomic flag that the loop observes after at most `pollTimeoutMs`
/// milliseconds.
public final class SessionRunner {
  /// Wraps the C session pointer in a Sendable type so the runner
  /// thread can capture it across the Swift 6 isolation boundary.
  /// The underlying C session is thread-safe (recursive mutex inside
  /// `LabanSession`); this class adds nothing on top of that.
  private final class CSessionRef: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ p: OpaquePointer) { self.pointer = p }
  }

  /// How long to block in `select(2)` per iteration. Short enough that
  /// `stop()` is observed within a human-imperceptible delay; long
  /// enough that an idle terminal does not spin.
  private static let pollTimeoutMs: Int32 = 100

  private let ref: CSessionRef
  private let onDirty: @Sendable () -> Void
  private let shouldStop = OSAllocatedUnfairLock(initialState: false)
  private let started = OSAllocatedUnfairLock(initialState: false)
  /// Latches once the first `stop()` call has waited for the thread.
  /// A second `stop()` (e.g. from `deinit` after an explicit
  /// `stop()` was already called by AppModel.deinit) must be a
  /// no-op; otherwise it tries to consume the one-shot
  /// DispatchSemaphore signal a second time and blocks forever.
  private let joined = OSAllocatedUnfairLock(initialState: false)
  /// Signals the join in `stop()`. Counts up exactly once, when the
  /// reader thread exits its loop. `stop()` blocks on this so the
  /// caller is guaranteed the reader is no longer touching the C
  /// session before `Session.close()` runs `laban_session_destroy`.
  private let exited = DispatchSemaphore(value: 0)
  private var thread: Thread?

  /// `handle` is the opaque C session pointer (`Session.handle`).
  /// `onDirty` is invoked from the reader thread whenever a poll
  /// returned >0 bytes. It MUST be cheap and non-blocking — typically
  /// a coalesced `DispatchQueue.main.async` post.
  public init(handle: OpaquePointer, onDirty: @escaping @Sendable () -> Void) {
    self.ref = CSessionRef(handle)
    self.onDirty = onDirty
  }

  public func start() {
    let alreadyStarted = started.withLock { value -> Bool in
      let was = value
      value = true
      return was
    }
    if alreadyStarted { return }

    let ref = self.ref
    let onDirty = self.onDirty
    let shouldStop = self.shouldStop
    let exited = self.exited
    let timeout = Self.pollTimeoutMs
    let t = Thread {
      Thread.current.name = "laban.session.reader"
      pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
      defer { exited.signal() }
      while !shouldStop.withLock({ $0 }) {
        let drained = laban_session_poll_blocking(ref.pointer, timeout)
        if drained > 0 { onDirty() }
        if drained < 0 { break } // permanent error from select; bail
      }
    }
    thread = t
    t.start()
  }

  /// Signal the reader thread to exit and wait until it does. The
  /// caller MUST call this before `laban_session_destroy` runs against
  /// the same handle, otherwise the reader can re-acquire the C lock
  /// after the destructor has called `pthread_mutex_destroy`. Worst-
  /// case wait is `pollTimeoutMs` (100 ms) per session. Idempotent —
  /// repeated calls return immediately, which matters because the
  /// runner is typically stopped both explicitly (e.g. from
  /// `AppModel.closeTab`) and again from `deinit`.
  public func stop() {
    let alreadyJoined = joined.withLock { value -> Bool in
      let was = value
      value = true
      return was
    }
    if alreadyJoined { return }
    let wasStarted = started.withLock { $0 }
    shouldStop.withLock { $0 = true }
    if wasStarted { exited.wait() }
  }

  deinit { stop() }
}
