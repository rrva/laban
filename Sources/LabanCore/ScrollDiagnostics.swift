import Dispatch
import Foundation

/// Append-only diagnostic recorder for the overlay scroll-indicator bug on the
/// labpty path: the pill stays visible even when the user is pinned to the live
/// bottom, and only clears when the window is unfocused (the streaming app then
/// pauses output). A single viewport snapshot can't expose this — the cause is a
/// race between the background byte-ring feed (which grows `totalRows` on a 4 ms
/// timer) and the main-thread viewport sample the indicator reads. Only a
/// time-series *across feeds and samples* shows whether `viewportOffset` is
/// tracking the live bottom (follow-output engaged) or drifting behind it.
///
/// This records that series to an in-memory ring (served over the debug surface
/// for capture/replay parity) and, optionally, to a JSONL file under
/// `~/Library/Logs/Laban/scroll-trace/`. It is disabled by default and a single
/// relaxed `Bool` read in that state, so the hot feed/sample paths pay nothing
/// until an explicit `--scroll-debug` launch flag enables it before any session
/// starts streaming.
public final class ScrollDiagnostics: @unchecked Sendable {
  public static let shared = ScrollDiagnostics()

  /// One recorded moment. Viewport numbers are always present (they are the
  /// indicator's literal inputs); the rest are filled per `kind` so a reader can
  /// correlate a `feed` that moved `total` with the next `sample`'s `linesBack`.
  public struct Event: Codable {
    public var seq: Int
    /// Milliseconds since the recorder armed (monotonic uptime clock).
    public var tMs: Double
    /// sample | feed | scroll | snap | reengage | focus | mark
    public var kind: String
    public var thread: String

    public var off: Int
    public var total: Int
    public var vp: Int
    public var sb: Int
    /// `max(0, (total - vp) - off)` — the value that holds the pill visible.
    public var linesBack: Int
    public var alt: Bool
    public var mouse: Bool

    public var focused: Bool?
    public var bytesLen: Int?
    public var offBefore: Int?
    public var totalBefore: Int?
    public var deltaRows: Int?
    /// `TerminalBitmapView` internal scroll state, when the sample comes from the
    /// view: the PD controller's reconciled / displayed / target rows and
    /// whether it is mid-animation. Lets a reader see the view believing it is at
    /// the bottom while libghostty reports `linesBack > 0`. `displayed`/`target`
    /// keep sub-row precision (the PD controller animates fractional rows).
    public var applied: Int?
    public var displayed: Double?
    public var target: Double?
    public var animating: Bool?
    public var note: String?
  }

  private let lock = NSLock()
  private let ioQueue = DispatchQueue(label: "com.laban.scrolldiag.io")
  private var ring: [Event] = []
  private var seqCounter: Int = 0
  private var fileHandle: FileHandle?
  private let capacity: Int
  private let startUptimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds

  /// Read without the lock on the hot paths. Written once by `enable()` before
  /// the streaming feed timer starts, so a torn read cannot occur in practice.
  public private(set) var isEnabled: Bool = false
  public private(set) var filePath: String?

  public init(capacity: Int = 16384) {
    self.capacity = capacity
  }

  /// Arm recording. `filePath` is optional: a nil path keeps only the in-memory
  /// ring (served over the debug endpoint). Returns the resolved file path.
  @discardableResult
  public func enable(filePath: String?) -> String? {
    lock.lock()
    defer { lock.unlock() }
    if let filePath {
      let url = URL(fileURLWithPath: filePath)
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: filePath, contents: nil)
      fileHandle = try? FileHandle(forWritingTo: url)
      self.filePath = (fileHandle != nil) ? filePath : nil
    }
    isEnabled = true
    return self.filePath
  }

  public func snapshot() -> [Event] {
    lock.lock()
    defer { lock.unlock() }
    return ring
  }

  public func clear() {
    lock.lock()
    defer { lock.unlock() }
    ring.removeAll(keepingCapacity: true)
  }

  private func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds &- startUptimeNs) / 1_000_000.0
  }

  /// Low-level append. The closure fills `kind` and the per-kind fields; `seq`,
  /// `tMs`, and `thread` are stamped here. File I/O is handed to a serial queue
  /// in `seq` order so a small write never stalls the feed timer under the lock.
  public func record(_ fill: (inout Event) -> Void) {
    guard isEnabled else { return }
    lock.lock()
    seqCounter += 1
    var ev = Event(
      seq: seqCounter,
      tMs: nowMs(),
      kind: "",
      thread: Self.threadLabel(),
      off: 0, total: 0, vp: 0, sb: 0, linesBack: 0, alt: false, mouse: false)
    fill(&ev)
    ring.append(ev)
    if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
    let fh = fileHandle
    lock.unlock()
    guard let fh, let line = Self.encodeLine(ev) else { return }
    ioQueue.async { try? fh.write(contentsOf: line) }
  }

  // MARK: - Convenience recorders

  public static func linesBack(off: Int, total: Int, vp: Int) -> Int {
    max(0, max(0, total - vp) - off)
  }

  /// A viewport sample, typically at the indicator-feed point. `focused` and the
  /// view-internal scroll fields are the labpty-bug discriminators.
  public func sample(
    kind: String,
    off: Int, total: Int, vp: Int, sb: Int,
    alt: Bool, mouse: Bool,
    focused: Bool? = nil,
    applied: Int? = nil, displayed: Double? = nil, target: Double? = nil, animating: Bool? = nil,
    note: String? = nil
  ) {
    guard isEnabled else { return }
    record { ev in
      ev.kind = kind
      ev.off = off
      ev.total = total
      ev.vp = vp
      ev.sb = sb
      ev.linesBack = Self.linesBack(off: off, total: total, vp: vp)
      ev.alt = alt
      ev.mouse = mouse
      ev.focused = focused
      ev.applied = applied
      ev.displayed = displayed
      ev.target = target
      ev.animating = animating
      ev.note = note
    }
  }

  /// A byte-ring feed: `before`/`after` totals reveal whether appending output
  /// moved `viewportOffset` with `totalRows` (follow engaged) or left it behind.
  public func feed(
    bytesLen: Int,
    offBefore: Int, totalBefore: Int,
    off: Int, total: Int, vp: Int, sb: Int, alt: Bool, mouse: Bool,
    note: String? = nil
  ) {
    guard isEnabled else { return }
    record { ev in
      ev.kind = "feed"
      ev.off = off
      ev.total = total
      ev.vp = vp
      ev.sb = sb
      ev.linesBack = Self.linesBack(off: off, total: total, vp: vp)
      ev.alt = alt
      ev.mouse = mouse
      ev.bytesLen = bytesLen
      ev.offBefore = offBefore
      ev.totalBefore = totalBefore
      ev.note = note
    }
  }

  /// A scroll command, snap, or follow-reengage decision.
  public func event(
    kind: String,
    off: Int, total: Int, vp: Int, sb: Int, alt: Bool, mouse: Bool,
    deltaRows: Int? = nil,
    applied: Int? = nil,
    note: String? = nil
  ) {
    guard isEnabled else { return }
    record { ev in
      ev.kind = kind
      ev.off = off
      ev.total = total
      ev.vp = vp
      ev.sb = sb
      ev.linesBack = Self.linesBack(off: off, total: total, vp: vp)
      ev.alt = alt
      ev.mouse = mouse
      ev.deltaRows = deltaRows
      ev.applied = applied
      ev.note = note
    }
  }

  /// A standalone marker (focus change, label) with no viewport snapshot.
  public func mark(kind: String, focused: Bool? = nil, note: String? = nil) {
    guard isEnabled else { return }
    record { ev in
      ev.kind = kind
      ev.focused = focused
      ev.note = note
    }
  }

  // MARK: - Encoding

  static func threadLabel() -> String {
    if Thread.isMainThread { return "main" }
    if let name = Thread.current.name, !name.isEmpty { return name }
    return "bg"
  }

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }()

  static func encodeLine(_ ev: Event) -> Data? {
    guard var data = try? encoder.encode(ev) else { return nil }
    data.append(0x0A)
    return data
  }
}
