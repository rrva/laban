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
///     qos: .utility)` that ticks on a 200 ms debounce and drains the
///     ring to the append-only `<tab-id>.bin` file.
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
  private let debounceLock = NSLock()
  private var pendingTimer: DispatchSourceTimer?

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
  public init(
    tabId: String,
    fileURL: URL,
    ringCapacity: Int = 256 * 1024,
    fileCapacity: Int = 10 * 1024 * 1024,
    debounceInterval: DispatchTimeInterval = .milliseconds(200),
    drainQueue: DispatchQueue? = nil
  ) {
    self.tabId = tabId
    self.fileURL = fileURL
    self.ringCapacity = ringCapacity
    self.fileCapacity = fileCapacity
    self.debounceInterval = debounceInterval
    self.drainQueue =
      drainQueue ?? DispatchQueue(label: "laban.persistence.transcript", qos: .utility)
    self.ring = UnsafeMutablePointer<UInt8>.allocate(capacity: ringCapacity)
  }

  deinit {
    pendingTimer?.cancel()
    ring.deallocate()
  }

  /// The single entry point invoked by the C persistence callback. MUST
  /// remain memcpy-only — see ExecPlan Decision Log. Schedules a drain
  /// via the dedicated queue; never blocks the caller.
  public func writeChunk(bytes: UnsafePointer<UInt8>, count: Int) {
    guard count > 0 else { return }
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
    scheduleDrain()
  }

  /// Drain whatever is currently in the ring synchronously. Used by
  /// tests, by `flushSync()`, and by the periodic drain timer.
  public func drainNow() {
    let bytes = takeRingSnapshot()
    guard !bytes.isEmpty else { return }
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

  /// Synchronously drain the ring and write to disk. Called by the
  /// persistence coordinator from `applicationWillTerminate`.
  public func flushSync() {
    cancelPendingTimer()
    drainQueue.sync { [weak self] in
      self?.drainNow()
    }
  }

  private func scheduleDrain() {
    debounceLock.lock()
    pendingTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: drainQueue)
    timer.schedule(deadline: .now() + debounceInterval)
    timer.setEventHandler { [weak self] in
      self?.drainNow()
    }
    pendingTimer = timer
    debounceLock.unlock()
    timer.resume()
  }

  private func cancelPendingTimer() {
    debounceLock.lock()
    pendingTimer?.cancel()
    pendingTimer = nil
    debounceLock.unlock()
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
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd < 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
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
  }

  /// When the file exceeds `fileCapacity`, drop the oldest ~10% via a
  /// temp-file rewrite and atomic rename so the on-disk transcript is
  /// always a coherent prefix of a real PTY stream. Cheaper than
  /// rewriting on every append (the cap is far above typical sizes).
  private func maybeTruncateHead() throws {
    let fm = FileManager.default
    let attrs: [FileAttributeKey: Any]
    do {
      attrs = try fm.attributesOfItem(atPath: fileURL.path)
    } catch {
      return  // File missing — nothing to truncate.
    }
    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
    guard size > fileCapacity else { return }
    let dropBytes = max(size - fileCapacity, fileCapacity / 10)
    let data = try Data(contentsOf: fileURL)
    guard dropBytes < data.count else {
      try? fm.removeItem(at: fileURL)
      return
    }
    let kept = data.subdata(in: dropBytes..<data.count)
    let tmp = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(fileURL.lastPathComponent).truncate-\(UUID().uuidString)")
    try kept.write(to: tmp, options: .atomic)
    _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
  }
}
