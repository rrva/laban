import Foundation

/// Tracks which tabs have recently had labpty byte-ring output dropped, so the
/// "output skipped" badge can behave as a live signal — visible while output is
/// being dropped and for a short cooldown after the last drop — and then retire
/// itself, even on an inactive tab the user never selects.
///
/// The byte-ring overflow that feeds this is edge-triggered: each unrecoverable
/// drop is reported exactly once and then the reader catches up
/// (`LabptyByteRingReader` recomputes `overflowed` per read and self-clears).
/// Recording the time of the most recent drop lets `isDegraded` answer "is this
/// tab still losing output, or was it within the cooldown?" without the caller
/// holding any timers. Once `cooldown` elapses with no fresh drop the tab is no
/// longer degraded; a new drop re-arms it. An explicit `clear` (the tab is
/// viewed, stopped, or closed) retires it immediately, regardless of the cooldown.
public struct LabptyOutputDegradation: Sendable {
  /// How long the badge lingers after the most recent dropped-output event. The
  /// badge is a live "can't keep up right now" indicator, not a permanent
  /// data-loss record, so it fades once drops stop rather than waiting to be seen.
  public let cooldown: TimeInterval
  private var lastSkipByTab: [Tab.ID: Date]

  public init(cooldown: TimeInterval) {
    self.cooldown = cooldown
    self.lastSkipByTab = [:]
  }

  /// Record that `tabId` just had output dropped at `time`. The most recent skip
  /// wins, which is what re-arms the badge while a burst keeps overrunning.
  public mutating func recordSkip(_ tabId: Tab.ID, at time: Date) {
    lastSkipByTab[tabId] = time
  }

  /// Retire `tabId`'s degraded state immediately — used when the user views the
  /// tab or the session goes away, so the badge does not have to wait out the
  /// cooldown in those cases.
  public mutating func clear(_ tabId: Tab.ID) {
    lastSkipByTab.removeValue(forKey: tabId)
  }

  /// True while `tabId`'s most recent dropped-output event is within `cooldown`
  /// of `now`. Self-clears once the cooldown elapses, so an inactive tab retires
  /// the badge without ever being selected.
  public func isDegraded(_ tabId: Tab.ID, now: Date) -> Bool {
    guard let last = lastSkipByTab[tabId] else { return false }
    return now.timeIntervalSince(last) < cooldown
  }

  /// Forget tabs whose cooldown has fully elapsed so a long-lived session cannot
  /// accumulate stale entries for tabs that overflowed once and were never
  /// closed. Cheap and safe to call on every metadata poll.
  public mutating func pruneExpired(now: Date) {
    lastSkipByTab = lastSkipByTab.filter { now.timeIntervalSince($0.value) < cooldown }
  }
}
