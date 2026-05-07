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
    let timeout = Self.pollTimeoutMs
    let t = Thread {
      Thread.current.name = "laban.session.reader"
      pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
      while !shouldStop.withLock({ $0 }) {
        let drained = laban_session_poll_blocking(ref.pointer, timeout)
        if drained > 0 { onDirty() }
        if drained < 0 { break } // permanent error from select; bail
      }
    }
    thread = t
    t.start()
  }

  public func stop() {
    shouldStop.withLock { $0 = true }
    /* The reader thread observes the flag after at most pollTimeoutMs.
     * We do not join here because joining would block the caller for
     * up to pollTimeoutMs and stop() is typically called from teardown
     * paths that expect to return immediately. The thread will exit
     * shortly and self-collect. */
  }

  deinit { stop() }
}
