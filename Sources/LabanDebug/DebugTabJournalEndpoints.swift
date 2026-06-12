import Foundation
import LabanCore

struct TabJournalResponse: Encodable {
  var entries: [TabStateJournalEntry]
  var next: Int
}

extension HeadlessDebugRuntime {
  /// `GET /debug/tab-journal` — the model's always-on journal of per-tab
  /// visible state (title metadata, status, selection, notification badge)
  /// plus banner notes, with capture-timeline-compatible timestamps. The
  /// journal has its own lock, so no runtime lock is needed.
  public func tabJournalResponse(since: Int, tabId: String?) -> DebugResponse {
    let snapshot = model.tabJournal.snapshot(since: since, tabId: tabId)
    return jsonEncode(TabJournalResponse(entries: snapshot.entries, next: snapshot.next))
  }
}
