import Foundation
import os

/// Low-cardinality idle-loop counters for Instruments traces.
///
/// Enabled only by `LABAN_IDLE_COUNTERS=1` or the matching user default. The
/// emitted signpost carries aggregate counts, never tab ids, paths, process
/// arguments, environment values, or terminal text.
final class IdleCounters: @unchecked Sendable {
  static let enabledDefaultKey = "LabanIdleCountersEnabled"
  static let enabledEnvironmentKey = "LABAN_IDLE_COUNTERS"
  static let shared = IdleCounters()

  private let enabled: Bool
  private let log = OSLog(subsystem: AppLog.subsystem, category: "PointsOfInterest")
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "laban.idle-counters", qos: .utility)
  private var timer: DispatchSourceTimer?

  private var displayLinkTicks: UInt64 = 0
  private var advanceFrames: UInt64 = 0
  private var labptyPolls: UInt64 = 0
  private var emptyLabptyPolls: UInt64 = 0
  private var dirtyLabptyPolls: UInt64 = 0
  private var activeFeeds: UInt64 = 0

  private init(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.enabled = Self.isEnabled(defaults: defaults, environment: environment)
    guard enabled else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
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
    snapshot = Snapshot(
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

    os_signpost(
      .event,
      log: log,
      name: "IdleCounters",
      "displayLink=%{public}llu advance=%{public}llu labptyPoll=%{public}llu emptyLabptyPoll=%{public}llu dirtyLabptyPoll=%{public}llu activeFeeds=%{public}llu",
      snapshot.displayLinkTicks,
      snapshot.advanceFrames,
      snapshot.labptyPolls,
      snapshot.emptyLabptyPolls,
      snapshot.dirtyLabptyPolls,
      snapshot.activeFeeds)
  }

  private static func isTruthy(_ value: String) -> Bool {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on", "enabled":
      return true
    default:
      return false
    }
  }

  private struct Snapshot {
    var displayLinkTicks: UInt64
    var advanceFrames: UInt64
    var labptyPolls: UInt64
    var emptyLabptyPolls: UInt64
    var dirtyLabptyPolls: UInt64
    var activeFeeds: UInt64
  }
}
