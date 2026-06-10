import Darwin
import Foundation
import LabanTerminalCore

/// Per-tab PTY-byte recorder. Owns:
///   - An in-memory ring buffer (default 256 KB) written by the C
///     persistence callback under the session lock. The callback path
///     must do nothing more than `memcpy` into this ring; any synchronous
///     IO there would stall the PTY drain (see the ExecPlan's
///     callback-contract decision).
///   - A dedicated `DispatchQueue(label: "laban.persistence",
///     qos: .utility)` that drains the ring to the append-only
///     `<tab-id>.bin` file 200 ms after output arrives (event-driven
///     debounce; a quiet session schedules no work at all).
///   - A 10 MB head-truncation pass that rewrites the file via temp +
///     atomic rename whenever the file exceeds the cap, dropping the
///     oldest ~1 MB so the on-disk transcript stays bounded.
///
/// Overflow policy is **drop oldest**: when sustained PTY output fills
/// the ring faster than the drain queue can absorb it, new bytes
/// overwrite the oldest in-ring bytes. The user-visible effect is that
/// older content does not make it into the persistent transcript file;
/// on-screen rendering is unaffected because libghostty parses bytes
/// live. A drop counter is incremented so telemetry can detect
/// sustained-overflow conditions.
public final class TranscriptWriter {
  public let tabId: String
  public let fileURL: URL
  public let ringCapacity: Int
  public let fileCapacity: Int

  /// Drop counter incremented every time the C callback overwrote
  /// older bytes because the ring was full. Read for telemetry only;
  /// drop-oldest is intentional behavior, not an error.
  public private(set) var droppedBytes: UInt64 = 0

  /// Total number of bytes that have been observed by the writer
  /// (whether retained, drained, or dropped). Useful for tests.
  public private(set) var ingestedBytes: UInt64 = 0

  private let ring: UnsafeMutablePointer<UInt8>
  private let ringLock = NSLock()
  private var ringHead: Int = 0
  private var ringTail: Int = 0
  private var ringSize: Int = 0

  private let drainQueue: DispatchQueue
  private let debounceInterval: DispatchTimeInterval
  private let timerLock = NSLock()
  private var drainTimer: DispatchSourceTimer?
  private var drainScheduled = false
  private let isEnabled: () -> Bool

  // Drain-queue-confined filesystem caches. The transcript directory is
  // created once, and the file size is tracked in memory (seeded by one
  // fstat on first append) so steady-state drains issue no stat calls.
  private var directoryEnsured = false
  private var approxFileSize = -1

  /// Suppress capture until this deadline. Used by restored tabs so
  /// the new shell's startup output (prompt sequences,
  /// bracketed-paste enable, etc.) is dropped instead of being
  /// appended to the prior session's `.bin`. Without this, every
  /// quit-then-restore cycle accumulates ~90 bytes of shell-startup
  /// noise that show up as a stacked prompt in the next restore's
  /// scrollback. The deadline is consulted at capture time so
  /// suppressed bytes never enter the ring at all.
  private let suppressLock = NSLock()
  private var suppressUntil: DispatchTime?

  /// Designated init.
  ///
  /// - Parameters:
  ///   - tabId: stable identifier; the on-disk transcript lives at
  ///     `<store.transcripts>/<tabId>.bin` and survives across launches.
  ///   - fileURL: absolute path to the `.bin` file; the writer opens it
  ///     for append and creates intermediate directories on demand.
  ///   - ringCapacity: in-memory backpressure buffer size in bytes.
  ///   - fileCapacity: hard ceiling on the on-disk file size. When the
  ///     append would push the file past this size, the oldest ~10% of
  ///     bytes are dropped via a temp-file rewrite.
  ///   - debounceInterval: how long the drain queue coalesces writes.
  ///   - drainQueue: optional override so tests can inject a serial
  ///     queue they own.
  ///   - isEnabled: gate consulted on every disk drain. When false,
  ///     bytes still accumulate in the in-memory ring (so the PTY
  ///     callback's contract — memcpy-only — is preserved) but never
  ///     reach disk. The kill-switch toggle wires this to
  ///     `RestoreOnLaunchSettings.isEnabled` so flipping it off mid-
  ///     session stops `.bin` writes immediately without disturbing
  ///     the PTY hot path.
  public init(
    tabId: String,
    fileURL: URL,
    ringCapacity: Int = 256 * 1024,
    fileCapacity: Int = 10 * 1024 * 1024,
    debounceInterval: DispatchTimeInterval = .milliseconds(200),
    drainQueue: DispatchQueue? = nil,
    isEnabled: @escaping () -> Bool = { true }
  ) {
    self.tabId = tabId
    self.fileURL = fileURL
    self.ringCapacity = ringCapacity
    self.fileCapacity = fileCapacity
    self.debounceInterval = debounceInterval
    self.drainQueue =
      drainQueue ?? DispatchQueue(label: "laban.persistence.transcript", qos: .utility)
    self.ring = UnsafeMutablePointer<UInt8>.allocate(capacity: ringCapacity)
    self.isEnabled = isEnabled
  }

  deinit {
    drainTimer?.cancel()
    ring.deallocate()
  }

  /// The single entry point invoked by the C persistence callback. By
  /// contract this never performs IO or anything else that could stall
  /// the PTY drain: the hot path is memcpy into the ring plus a
  /// lock-check of the debounce flag. The first chunk of a burst
  /// additionally arms the one-shot drain timer (amortized O(1) — while
  /// output flows the flag short-circuits all subsequent chunks).
  ///
  /// When the kill-switch toggle is off the bytes are dropped
  /// immediately. Storing them in the ring and discarding at drain
  /// time is not enough — the "write off, re-enable, drain" sequence
  /// would resurrect them. The cost of the gate check is one closure
  /// call (UserDefaults read in production) per PTY chunk, which is
  /// negligible compared to the syscall stack the chunk just came
  /// from.
  public func writeChunk(bytes: UnsafePointer<UInt8>, count: Int) {
    guard count > 0 else { return }
    guard isEnabled() else {
      // Discard at capture so disabled-window bytes can never reach
      // disk regardless of toggle order or drain timing.
      droppedBytes &+= UInt64(count)
      return
    }
    if isWithinSuppressionWindow() {
      // Restored-tab suppression: drop the new shell's startup
      // output so it doesn't accumulate across restore cycles.
      droppedBytes &+= UInt64(count)
      return
    }
    ringLock.lock()
    ingestedBytes &+= UInt64(count)
    let cap = ringCapacity
    var i = 0
    while i < count {
      let chunk = min(count - i, cap - ringHead)
      memcpy(ring.advanced(by: ringHead), bytes.advanced(by: i), chunk)
      ringHead = (ringHead + chunk) % cap
      let newSize = ringSize + chunk
      if newSize > cap {
        let overflow = newSize - cap
        droppedBytes &+= UInt64(overflow)
        ringTail = (ringTail + overflow) % cap
        ringSize = cap
      } else {
        ringSize = newSize
      }
      i += chunk
    }
    ringLock.unlock()
    scheduleDrainAfterDebounce()
  }

  /// Drain whatever is currently in the ring. The drain ALWAYS empties
  /// the ring; what it does with the bytes depends on the gate:
  ///   - enabled: append to the `.bin` file (and head-truncate when
  ///     over the cap).
  ///   - disabled: discard the bytes entirely. The kill switch is
  ///     "discard while off, not defer" — a later re-enable must
  ///     never resurrect bytes captured during the off window.
  /// Called by the debounced drain timer, by `flushSync()`, and by tests.
  public func drainNow() {
    // Clear the debounce arm before snapshotting: a chunk that lands after
    // this point schedules its own follow-up drain, so nothing can strand in
    // the ring between bursts.
    timerLock.lock()
    drainScheduled = false
    drainTimer?.cancel()
    drainTimer = nil
    timerLock.unlock()
    let bytes = takeRingSnapshot()
    guard !bytes.isEmpty else { return }
    guard isEnabled() else {
      // Bytes accumulated during the disabled window are dropped.
      // `takeRingSnapshot` has already reset the ring head/tail/size.
      return
    }
    do {
      try append(bytes)
    } catch {
      // Append failed (disk full, permissions). The ring has already
      // been drained — losing the chunk is preferable to blocking the
      // PTY callback if we retried. Subsequent writes will start fresh.
    }
    do {
      try maybeTruncateHead()
    } catch {
      // Truncation failure is non-fatal — the file will exceed the cap
      // until the next successful write. This is acceptable for a
      // persistence-only path; the user does not see this state.
    }
  }

  /// Suppress `writeChunk` for the next `interval`. Used by restored
  /// tabs to drop the spawn-time prompt bytes so they don't pile up
  /// in the on-disk transcript across restore cycles. Pass `.zero`
  /// (or never call this) for fresh tabs whose entire output
  /// belongs on disk. Idempotent: a second call replaces the
  /// previous deadline.
  public func suppressCapture(forNext interval: DispatchTimeInterval) {
    suppressLock.lock()
    suppressUntil = DispatchTime.now() + interval
    suppressLock.unlock()
  }

  private func isWithinSuppressionWindow() -> Bool {
    suppressLock.lock()
    defer { suppressLock.unlock() }
    guard let deadline = suppressUntil else { return false }
    if DispatchTime.now() < deadline { return true }
    suppressUntil = nil
    return false
  }

  /// Synchronously drain the ring and write to disk. Called by the
  /// persistence coordinator from `applicationWillTerminate`. Skips
  /// the timer hop; runs the drain on the calling thread under the
  /// drain queue's serial guarantee.
  public func flushSync() {
    drainQueue.sync { [weak self] in
      self?.drainNow()
    }
  }

  /// Arm a one-shot drain `debounceInterval` after the first chunk of a
  /// burst. Event-driven by design: an idle session schedules nothing, so a
  /// quiet Laban takes zero transcript timer wakeups (the previous repeating
  /// 5 Hz timer was the single largest idle-CPU source). The generous leeway
  /// lets the kernel coalesce the wake with other timers — transcript
  /// persistence has no latency requirement.
  private func scheduleDrainAfterDebounce() {
    timerLock.lock()
    defer { timerLock.unlock() }
    if drainScheduled { return }
    drainScheduled = true
    let timer = DispatchSource.makeTimerSource(queue: drainQueue)
    timer.schedule(deadline: .now() + debounceInterval, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.drainNow()
    }
    drainTimer = timer
    timer.resume()
  }

  /// Drain the ring into a contiguous Data buffer and reset the ring.
  /// Holds the ring lock for as short a window as possible.
  private func takeRingSnapshot() -> Data {
    ringLock.lock()
    defer {
      ringHead = 0
      ringTail = 0
      ringSize = 0
      ringLock.unlock()
    }
    let count = ringSize
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    let cap = ringCapacity
    data.withUnsafeMutableBytes { dst in
      guard let dstBase = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return
      }
      let first = min(count, cap - ringTail)
      memcpy(dstBase, ring.advanced(by: ringTail), first)
      if count > first {
        memcpy(dstBase.advanced(by: first), ring, count - first)
      }
    }
    return data
  }

  private func append(_ data: Data) throws {
    if !directoryEnsured {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      directoryEnsured = true
    }
    let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd < 0 {
      // Re-probe the directory next time; its absence is the likely cause.
      directoryEnsured = false
      approxFileSize = -1
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
    if approxFileSize < 0 {
      var st = stat()
      approxFileSize = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
    }
    do {
      try data.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        var remaining = data.count
        var p = base.assumingMemoryBound(to: UInt8.self)
        while remaining > 0 {
          let n = Darwin.write(fd, p, remaining)
          if n > 0 {
            remaining -= n
            p = p.advanced(by: n)
            continue
          }
          if n < 0 && errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    } catch {
      // Unknown partial-write state on disk: re-seed from fstat next time.
      approxFileSize = -1
      throw error
    }
    approxFileSize += data.count
  }

  /// When the file exceeds `fileCapacity`, drop the oldest ~10% via a
  /// temp-file rewrite and atomic rename so the on-disk transcript is
  /// always a coherent prefix of a real PTY stream. Cheaper than
  /// rewriting on every append (the cap is far above typical sizes).
  private func maybeTruncateHead() throws {
    // Gate on the in-memory size so steady-state drains cost no stat. The
    // read below re-syncs with on-disk reality before anything is dropped.
    guard approxFileSize > fileCapacity else { return }
    let fm = FileManager.default
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      approxFileSize = -1
      return  // File missing — nothing to truncate.
    }
    approxFileSize = data.count
    guard data.count > fileCapacity else { return }
    let dropBytes = max(data.count - fileCapacity, fileCapacity / 10)
    guard dropBytes < data.count else {
      try? fm.removeItem(at: fileURL)
      approxFileSize = 0
      return
    }
    let kept = data.subdata(in: dropBytes..<data.count)
    let tmp = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(fileURL.lastPathComponent).truncate-\(UUID().uuidString)")
    try kept.write(to: tmp, options: .atomic)
    _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
    approxFileSize = kept.count
  }
}
