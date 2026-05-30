import Darwin
import Foundation

/// Per-tab in-memory rolling buffer of the most recent PTY output
/// bytes. Sized to hold ~60 seconds of normal terminal output;
/// overflow drops the oldest entries. Fed by the same C persistence
/// callback that feeds `TranscriptWriter`, so the contract on
/// `record(bytes:count:)` is identical: memcpy-only, no IO, no
/// allocation, no dispatch. The export-cast action snapshots the
/// ring on the main thread.
///
/// Two parallel rings:
///   - A byte ring (`UnsafeMutablePointer<UInt8>` of `byteCapacity`)
///     holds raw PTY output bytes.
///   - A header ring (`Array<Header>` of `headerCapacity`) holds
///     `(timestampNanos, byteOffset, byteLength)` per recorded chunk
///     so a snapshot can rebuild ordered `(time, bytes)` entries.
///
/// Both rings drop oldest when full. The byte ring overwrites bytes
/// in place; when a chunk's start byte is overwritten, the
/// corresponding header is invalidated by advancing the header tail
/// past it.
public final class RecentByteRing {
  /// Per-chunk metadata. `byteOffset` is the absolute offset of the
  /// chunk's first byte since this ring was created (monotonically
  /// increasing); compare against `firstRetainedByteOffset` to know
  /// whether the chunk's bytes are still in the byte ring.
  public struct Entry: Equatable {
    public let timestampNanos: UInt64
    public let bytes: [UInt8]
    public init(timestampNanos: UInt64, bytes: [UInt8]) {
      self.timestampNanos = timestampNanos
      self.bytes = bytes
    }
  }

  /// Split view of the retained ring for bounded cast export. The
  /// `initialEntries` are retained bytes before the requested window;
  /// callers can replay them into a scratch terminal to synthesize
  /// the window's starting screen. The `entries` are the actual PTY
  /// chunks to emit as timed cast events.
  public struct CastWindowSnapshot: Equatable {
    public let cutoffNanos: UInt64
    public let initialEntries: [Entry]
    public let entries: [Entry]

    public init(cutoffNanos: UInt64, initialEntries: [Entry], entries: [Entry]) {
      self.cutoffNanos = cutoffNanos
      self.initialEntries = initialEntries
      self.entries = entries
    }
  }

  public let byteCapacity: Int
  public let headerCapacity: Int

  private let lock = NSLock()
  private let byteBuffer: UnsafeMutablePointer<UInt8>

  /// Total bytes ever recorded. Used to give each chunk an absolute
  /// offset that does not wrap.
  private var totalBytesRecorded: UInt64 = 0

  /// Absolute offset of the oldest byte still living in the byte
  /// ring. `totalBytesRecorded - firstRetainedByteOffset == bytes
  /// currently held` (clamped by capacity).
  private var firstRetainedByteOffset: UInt64 = 0

  /// Each entry: (timestamp nanos, absolute byte offset, byte length).
  /// Stored as parallel arrays in a fixed-size circular layout.
  private var headerTimestamps: [UInt64]
  private var headerOffsets: [UInt64]
  private var headerLengths: [Int]
  private var headerHead: Int = 0
  private var headerTail: Int = 0
  private var headerSize: Int = 0

  /// - Parameters:
  ///   - byteCapacity: byte ring size. Default 5 MiB — at ~50 KB/s of
  ///     normal terminal output that is well over 60 s of history.
  ///   - headerCapacity: max retained chunk headers. Default 16384 —
  ///     enough for tens of thousands of small PTY writes per second
  ///     across the 60 s window.
  public init(byteCapacity: Int = 5 * 1024 * 1024, headerCapacity: Int = 16384) {
    precondition(byteCapacity > 0, "byteCapacity must be positive")
    precondition(headerCapacity > 0, "headerCapacity must be positive")
    self.byteCapacity = byteCapacity
    self.headerCapacity = headerCapacity
    self.byteBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCapacity)
    self.headerTimestamps = Array(repeating: 0, count: headerCapacity)
    self.headerOffsets = Array(repeating: 0, count: headerCapacity)
    self.headerLengths = Array(repeating: 0, count: headerCapacity)
  }

  deinit {
    byteBuffer.deallocate()
  }

  /// Memcpy-only entry point called by the C persistence callback.
  /// No IO, no dispatch, no allocation. Locks an `NSLock` and copies
  /// bytes into the ring; oldest bytes are overwritten when the ring
  /// is full, and oldest headers are dropped when their bytes are
  /// no longer fully present in the byte ring (partially-overwritten
  /// chunks are dropped wholesale so the surviving entries never
  /// start mid-escape-sequence).
  public func record(bytes: UnsafePointer<UInt8>, count: Int) {
    guard count > 0 else { return }
    let nowNanos = RecentByteRing.monotonicNanos()
    lock.lock()
    defer { lock.unlock() }

    let cap = byteCapacity
    let chunkOffset = totalBytesRecorded

    // Loop-copy with wraparound. `writePos` is the byte-ring index
    // matching `chunkOffset + i` so the reader's modulo computation
    // lines up with where we actually wrote. Chunks bigger than
    // `cap` simply overwrite themselves; only the trailing `cap`
    // bytes survive.
    var i = 0
    var writePos = Int(chunkOffset % UInt64(cap))
    while i < count {
      let segment = min(count - i, cap - writePos)
      memcpy(byteBuffer.advanced(by: writePos), bytes.advanced(by: i), segment)
      writePos = (writePos + segment) % cap
      i += segment
    }

    totalBytesRecorded &+= UInt64(count)
    if totalBytesRecorded - firstRetainedByteOffset > UInt64(cap) {
      firstRetainedByteOffset = totalBytesRecorded - UInt64(cap)
    }

    // Record a header for the SURVIVING portion of this chunk only.
    // If the chunk was larger than the ring, the earliest bytes are
    // already gone — the header points at the offset of the first
    // byte we still have.
    let survivingOffset = max(chunkOffset, firstRetainedByteOffset)
    let survivingLength = Int(
      (chunkOffset &+ UInt64(count)) &- survivingOffset)
    if survivingLength > 0 {
      appendHeader(
        timestampNanos: nowNanos,
        offset: survivingOffset,
        length: survivingLength)
    }
    evictHeadersBelow(retainedOffset: firstRetainedByteOffset)
  }

  /// Return ordered entries whose timestamps fall within the given
  /// window before "now". `window` is a wall-clock duration measured
  /// from this call; entries older than that are skipped. Bytes
  /// dropped by ring overflow do not appear.
  public func snapshot(window: TimeInterval) -> [Entry] {
    let cutoffNanos = Self.cutoffNanos(window: window)

    lock.lock()
    defer { lock.unlock() }

    var result: [Entry] = []
    result.reserveCapacity(headerSize)

    for i in 0..<headerSize {
      let idx = (headerTail + i) % headerCapacity
      let ts = headerTimestamps[idx]
      let off = headerOffsets[idx]
      let len = headerLengths[idx]
      guard ts >= cutoffNanos else { continue }
      guard off >= firstRetainedByteOffset else { continue }
      var chunk = [UInt8](repeating: 0, count: len)
      copyChunkUnlocked(offset: off, length: len, into: &chunk)
      result.append(Entry(timestampNanos: ts, bytes: chunk))
    }
    return result
  }

  /// Return the retained bytes split around the requested recent
  /// window. This is more expensive than `snapshot(window:)` because
  /// it copies older retained chunks too, and is intended for explicit
  /// user/debug export only.
  public func castWindowSnapshot(window: TimeInterval) -> CastWindowSnapshot {
    let cutoffNanos = Self.cutoffNanos(window: window)

    lock.lock()
    defer { lock.unlock() }

    var initialEntries: [Entry] = []
    var entries: [Entry] = []
    initialEntries.reserveCapacity(headerSize)
    entries.reserveCapacity(headerSize)

    for i in 0..<headerSize {
      let idx = (headerTail + i) % headerCapacity
      let ts = headerTimestamps[idx]
      let off = headerOffsets[idx]
      let len = headerLengths[idx]
      guard off >= firstRetainedByteOffset else { continue }
      var chunk = [UInt8](repeating: 0, count: len)
      copyChunkUnlocked(offset: off, length: len, into: &chunk)
      let entry = Entry(timestampNanos: ts, bytes: chunk)
      if ts < cutoffNanos {
        initialEntries.append(entry)
      } else {
        entries.append(entry)
      }
    }

    return CastWindowSnapshot(
      cutoffNanos: cutoffNanos,
      initialEntries: initialEntries,
      entries: entries)
  }

  /// Drop all retained entries. Used by tests.
  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    totalBytesRecorded = 0
    firstRetainedByteOffset = 0
    headerHead = 0
    headerTail = 0
    headerSize = 0
  }

  /// Diagnostic: how many headers are currently retained.
  public var retainedEntryCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return headerSize
  }

  // MARK: - Private

  private func appendHeader(timestampNanos: UInt64, offset: UInt64, length: Int) {
    if headerSize == headerCapacity {
      headerTail = (headerTail + 1) % headerCapacity
      headerSize -= 1
    }
    headerTimestamps[headerHead] = timestampNanos
    headerOffsets[headerHead] = offset
    headerLengths[headerHead] = length
    headerHead = (headerHead + 1) % headerCapacity
    headerSize += 1
  }

  private func evictHeadersBelow(retainedOffset: UInt64) {
    while headerSize > 0 {
      let idx = headerTail
      if headerOffsets[idx] >= retainedOffset { break }
      headerTail = (headerTail + 1) % headerCapacity
      headerSize -= 1
    }
  }

  private func copyChunkUnlocked(offset: UInt64, length: Int, into dest: inout [UInt8]) {
    let cap = byteCapacity
    let startIdx = Int(offset % UInt64(cap))
    let first = min(length, cap - startIdx)
    dest.withUnsafeMutableBufferPointer { buf in
      guard let base = buf.baseAddress else { return }
      memcpy(base, byteBuffer.advanced(by: startIdx), first)
      if first < length {
        memcpy(base.advanced(by: first), byteBuffer, length - first)
      }
    }
  }

  private static func monotonicNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
  }

  private static func cutoffNanos(window: TimeInterval) -> UInt64 {
    // Reachable from network input (/debug/cast/recent), so this must
    // never trap. A non-finite, negative, or absurdly large window all
    // mean "include everything", i.e. a cutoff of 0.
    guard window.isFinite, window >= 0 else { return 0 }
    let nowNanos = RecentByteRing.monotonicNanos()
    let scaled = (window * 1_000_000_000).rounded()
    guard scaled.isFinite, scaled < Double(UInt64.max) else { return 0 }
    let windowNanos = UInt64(scaled)
    if windowNanos >= nowNanos { return 0 }
    return nowNanos - windowNanos
  }
}
