import Foundation

/// One observed change to what a tab visibly showed (a `state` entry), or a
/// side-channel observation tied to a tab (a `note` entry, e.g. a posted
/// notification banner). Timestamps share `CaptureClock`'s epoch-nanosecond
/// timebase so journal entries line up with capture `timeline.ndjson` events.
public struct TabStateJournalEntry: Codable, Equatable {
  public var seq: Int
  public var timeNs: UInt64
  public var tabId: String
  public var kind: String

  public var isSelected: Bool?
  public var status: String?
  public var metadata: TabTitleMetadata?

  public var note: String?
  public var text: String?

  public init(seq: Int, timeNs: UInt64, tabId: String, kind: String) {
    self.seq = seq
    self.timeNs = timeNs
    self.tabId = tabId
    self.kind = kind
  }
}

/// Always-on, bounded, in-memory journal of per-tab visible state over time.
///
/// `AppModel` records a diff on every UI-invalidation notify, so the journal
/// is exactly the history of "what the tabs showed at what timestamp" — the
/// signal captures lacked when diagnosing late attention notifications.
/// Queryable via `GET /debug/tab-journal`, dumpable from the Debug menu, and
/// mirrored into capture timelines as `tab.metadata` events.
public final class TabStateJournal {
  public static let defaultCapacity = 8192

  public static let bannerPostedNote = "banner.posted"
  public static let bannerSuppressedFrontmostNote = "banner.suppressed.frontmost"
  public static let bannerSuppressedCategoryDisabledNote = "banner.suppressed.categoryDisabled"
  public static let bannerSuppressedEmptyBodyNote = "banner.suppressed.emptyBody"
  public static let bannerSuppressedBundleUnavailableNote = "banner.suppressed.bundleUnavailable"
  public static let bannerSuppressedAuthorizationDeniedNote =
    "banner.suppressed.authorizationDenied"
  public static let bannerSuppressedDeliveryFailedNote = "banner.suppressed.deliveryFailed"
  public static let bannerSuppressedRestoreNote = "banner.suppressed.restoreSuppression"
  public static let daemonRecoveryNote = "daemon.recovery"
  public static let automationAutoQuitArmedNote = "automation.autoquit.armed"

  public static func bannerSuppressedNote(
    reason: AttentionNotificationSuppressionReason
  ) -> String {
    switch reason {
    case .frontmostTab:
      return bannerSuppressedFrontmostNote
    case .categoryDisabled:
      return bannerSuppressedCategoryDisabledNote
    case .emptyBody:
      return bannerSuppressedEmptyBodyNote
    case .bundleUnavailable:
      return bannerSuppressedBundleUnavailableNote
    case .authorizationDenied:
      return bannerSuppressedAuthorizationDeniedNote
    case .deliveryFailed:
      return bannerSuppressedDeliveryFailedNote
    case .restoreSuppression:
      return bannerSuppressedRestoreNote
    }
  }

  private struct Projection: Equatable {
    var isSelected: Bool
    var status: String
    var metadata: TabTitleMetadata
  }

  private let lock = NSLock()
  private let capacity: Int
  private var entries: [TabStateJournalEntry] = []
  private var nextSeq = 0
  private var lastProjectionByTab: [String: Projection] = [:]

  public init(capacity: Int = TabStateJournal.defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  /// Records one `state` entry per tab whose visible projection changed since
  /// the previous call, evicts state for tabs that no longer exist, and
  /// returns the appended entries so callers can mirror them (e.g. into a
  /// running capture).
  @discardableResult
  public func recordDiff(tabs: [Tab], activeTabId: Tab.ID?) -> [TabStateJournalEntry] {
    let timeNs = CaptureClock.nowNs()
    lock.lock()
    defer { lock.unlock() }
    var appended: [TabStateJournalEntry] = []
    var liveIds = Set<String>(minimumCapacity: tabs.count)
    for tab in tabs {
      liveIds.insert(tab.id)
      let projection = Projection(
        isSelected: tab.id == activeTabId,
        status: tab.status.debugString,
        metadata: tab.titleMetadata
      )
      if lastProjectionByTab[tab.id] == projection { continue }
      lastProjectionByTab[tab.id] = projection
      var entry = TabStateJournalEntry(seq: nextSeq, timeNs: timeNs, tabId: tab.id, kind: "state")
      entry.isSelected = projection.isSelected
      entry.status = projection.status
      entry.metadata = projection.metadata
      nextSeq += 1
      appendLocked(entry)
      appended.append(entry)
    }
    let closed = lastProjectionByTab.keys.filter { !liveIds.contains($0) }
    for id in closed { lastProjectionByTab.removeValue(forKey: id) }
    return appended
  }

  @discardableResult
  public func note(tabId: Tab.ID, note: String, text: String? = nil) -> TabStateJournalEntry {
    lock.lock()
    defer { lock.unlock() }
    var entry = TabStateJournalEntry(
      seq: nextSeq, timeNs: CaptureClock.nowNs(), tabId: tabId, kind: "note")
    entry.note = note
    entry.text = text
    nextSeq += 1
    appendLocked(entry)
    return entry
  }

  /// Entries with `seq >= since` (oldest entries may have been trimmed; `seq`
  /// stays monotonic across trims so cursors remain valid), optionally
  /// filtered to one tab. `next` is the cursor for the following query.
  public func snapshot(
    since: Int = 0, tabId: Tab.ID? = nil
  ) -> (entries: [TabStateJournalEntry], next: Int) {
    lock.lock()
    defer { lock.unlock() }
    let matching = entries.filter { entry in
      entry.seq >= since && (tabId == nil || entry.tabId == tabId)
    }
    return (matching, nextSeq)
  }

  /// Writes the journal as ndjson (`tab-journal-<stamp>.ndjson`) under `root`
  /// and returns the file URL.
  public func dump(to root: URL, now: Date = Date()) throws -> URL {
    let snapshot = self.snapshot().entries
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("tab-journal-\(Self.stamp(now)).ndjson")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var lines = Data()
    for entry in snapshot {
      lines.append(try encoder.encode(entry))
      lines.append(0x0A)
    }
    try lines.write(to: url, options: .atomic)
    return url
  }

  private func appendLocked(_ entry: TabStateJournalEntry) {
    entries.append(entry)
    if entries.count > capacity {
      entries.removeFirst(entries.count - capacity)
    }
  }

  private static func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: ".", with: "")
  }
}

extension TabStateJournalEntry {
  /// Capture-timeline mirror of this entry, so `timeline.ndjson` shows tab
  /// state transitions alongside pty bytes, frames, and input.
  public func captureEvent(sessionId: String?) -> CaptureTimelineEvent {
    var event = CaptureTimelineEvent(
      seq: -1, timeNs: timeNs, kind: .tabMetadata, tabId: tabId, sessionId: sessionId)
    event.selected = isSelected
    event.status = status
    event.title = metadata?.displayTitle
    event.note = note
    if let notification = metadata?.notification {
      event.text = notification.text
      event.urgent = notification.urgent
      event.count = notification.count
    } else if let text {
      event.text = text
    }
    return event
  }
}
