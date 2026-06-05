import Darwin
import Foundation

/// Low-cardinality idle-loop counters for idle trace correlation.
///
/// Enabled only by `LABAN_IDLE_COUNTERS=1` or the matching user default. The
/// JSONL sidecar carries aggregate counts, never tab ids, paths, process
/// arguments, environment values, or terminal text.
final class IdleCounters: @unchecked Sendable {
  static let enabledDefaultKey = "LabanIdleCountersEnabled"
  static let enabledEnvironmentKey = "LABAN_IDLE_COUNTERS"
  static let sidecarFileName = "idle-counters.jsonl"
  static let shared = IdleCounters()

  private let enabled: Bool
  private let sidecarURL: URL?
  private let startUptimeNs = DispatchTime.now().uptimeNanoseconds
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "laban.idle-counters", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var sequence: UInt64 = 0

  private var displayLinkTicks: UInt64 = 0
  private var advanceFrames: UInt64 = 0
  private var labptyPolls: UInt64 = 0
  private var emptyLabptyPolls: UInt64 = 0
  private var dirtyLabptyPolls: UInt64 = 0
  private var activeFeeds: UInt64 = 0

  init(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    sidecarURL: URL? = nil,
    startsTimer: Bool = true
  ) {
    self.enabled = Self.isEnabled(defaults: defaults, environment: environment)
    if enabled {
      let resolvedSidecarURL = sidecarURL ?? Self.defaultSidecarURL()
      self.sidecarURL =
        resolvedSidecarURL.flatMap { Self.prepareSidecar(at: $0) ? $0 : nil }
    } else {
      self.sidecarURL = nil
    }
    guard enabled else { return }
    guard startsTimer else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.emitAndReset()
    }
    self.timer = timer
    timer.resume()
  }

  deinit {
    timer?.cancel()
  }

  static func isEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if let value = environment[enabledEnvironmentKey] {
      return isTruthy(value)
    }
    return defaults.bool(forKey: enabledDefaultKey)
  }

  static func defaultSidecarURL() -> URL? {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs/Laban", isDirectory: true)
      .appendingPathComponent(sidecarFileName)
  }

  func noteDisplayLinkTick() {
    guard enabled else { return }
    lock.lock()
    displayLinkTicks &+= 1
    lock.unlock()
  }

  func noteAdvanceFrame() {
    guard enabled else { return }
    lock.lock()
    advanceFrames &+= 1
    lock.unlock()
  }

  func noteLabptyFeedStarted() {
    guard enabled else { return }
    lock.lock()
    activeFeeds &+= 1
    lock.unlock()
  }

  func noteLabptyFeedStopped() {
    guard enabled else { return }
    lock.lock()
    if activeFeeds > 0 {
      activeFeeds -= 1
    }
    lock.unlock()
  }

  func noteLabptyPoll(byteCount: Int) {
    guard enabled else { return }
    lock.lock()
    labptyPolls &+= 1
    if byteCount > 0 {
      dirtyLabptyPolls &+= 1
    } else {
      emptyLabptyPolls &+= 1
    }
    lock.unlock()
  }

  private func emitAndReset() {
    let snapshot: Snapshot
    lock.lock()
    sequence &+= 1
    snapshot = Snapshot(
      sequence: sequence,
      tMs: (DispatchTime.now().uptimeNanoseconds &- startUptimeNs) / 1_000_000,
      displayLinkTicks: displayLinkTicks,
      advanceFrames: advanceFrames,
      labptyPolls: labptyPolls,
      emptyLabptyPolls: emptyLabptyPolls,
      dirtyLabptyPolls: dirtyLabptyPolls,
      activeFeeds: activeFeeds)
    displayLinkTicks = 0
    advanceFrames = 0
    labptyPolls = 0
    emptyLabptyPolls = 0
    dirtyLabptyPolls = 0
    lock.unlock()

    writeSidecar(snapshot)
  }

  func flushForTesting() {
    emitAndReset()
  }

  private static func isTruthy(_ value: String) -> Bool {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on", "enabled":
      return true
    default:
      return false
    }
  }

  private func writeSidecar(_ snapshot: Snapshot) {
    guard let sidecarURL else { return }
    let entry: [String: Any] = [
      "ts": Self.isoMs(Date()),
      "kind": "idle.counters",
      "seq": snapshot.sequence,
      "pid": Int(getpid()),
      "tMs": snapshot.tMs,
      "displayLinkTicks": snapshot.displayLinkTicks,
      "advanceFrames": snapshot.advanceFrames,
      "labptyPolls": snapshot.labptyPolls,
      "emptyLabptyPolls": snapshot.emptyLabptyPolls,
      "dirtyLabptyPolls": snapshot.dirtyLabptyPolls,
      "activeFeeds": snapshot.activeFeeds,
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    else {
      return
    }
    var line = data
    line.append(0x0A)
    Self.appendAtomically(line, to: sidecarURL)
  }

  private static func prepareSidecar(at url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func appendAtomically(_ data: Data, to url: URL) {
    url.path.withCString { path in
      let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
      guard fd >= 0 else { return }
      defer { close(fd) }
      data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
          let result = write(fd, base.advanced(by: written), rawBuffer.count - written)
          guard result > 0 else { return }
          written += result
        }
      }
    }
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static func isoMs(_ date: Date) -> String {
    isoFormatter.string(from: date)
  }

  private struct Snapshot {
    var sequence: UInt64
    var tMs: UInt64
    var displayLinkTicks: UInt64
    var advanceFrames: UInt64
    var labptyPolls: UInt64
    var emptyLabptyPolls: UInt64
    var dirtyLabptyPolls: UInt64
    var activeFeeds: UInt64
  }
}
