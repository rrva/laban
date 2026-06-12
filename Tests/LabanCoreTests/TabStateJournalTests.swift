import XCTest

@testable import LabanCore

final class TabStateJournalTests: XCTestCase {
  private func tab(_ id: String, title: String, active: Bool = false) -> Tab {
    Tab(id: id, position: 1, title: title, isActive: active, sessionId: "s-\(id)")
  }

  func testRecordDiffAppendsOnlyChangedTabs() {
    let journal = TabStateJournal()
    var a = tab("a", title: "one")
    let b = tab("b", title: "two")

    XCTAssertEqual(journal.recordDiff(tabs: [a, b], activeTabId: "a").count, 2)
    XCTAssertEqual(
      journal.recordDiff(tabs: [a, b], activeTabId: "a").count, 0,
      "an unchanged projection must not append entries")

    a.titleMetadata.notification = TabNotification(text: "needs you", urgent: true)
    let changed = journal.recordDiff(tabs: [a, b], activeTabId: "a")
    XCTAssertEqual(changed.count, 1)
    XCTAssertEqual(changed.first?.tabId, "a")
    XCTAssertEqual(changed.first?.kind, "state")
    XCTAssertEqual(changed.first?.metadata?.notification?.text, "needs you")
    XCTAssertEqual(changed.first?.metadata?.notification?.urgent, true)
  }

  func testSelectionChangeIsAVisibleChange() {
    let journal = TabStateJournal()
    let a = tab("a", title: "one")
    let b = tab("b", title: "two")
    _ = journal.recordDiff(tabs: [a, b], activeTabId: "a")

    let entries = journal.recordDiff(tabs: [a, b], activeTabId: "b")
    XCTAssertEqual(entries.count, 2, "both the deselected and the selected tab changed")
    XCTAssertEqual(entries.first { $0.tabId == "a" }?.isSelected, false)
    XCTAssertEqual(entries.first { $0.tabId == "b" }?.isSelected, true)
  }

  func testRingBoundTrimsOldestWhileSeqStaysMonotonic() {
    let journal = TabStateJournal(capacity: 4)
    var t = tab("a", title: "t0")
    _ = journal.recordDiff(tabs: [t], activeTabId: nil)
    for i in 1...9 {
      t.titleMetadata.terminalTitle = "t\(i)"
      _ = journal.recordDiff(tabs: [t], activeTabId: nil)
    }

    let snapshot = journal.snapshot()
    XCTAssertEqual(snapshot.entries.count, 4, "ring must trim to capacity")
    XCTAssertEqual(snapshot.next, 10, "seq keeps counting across trims")
    XCTAssertEqual(snapshot.entries.first?.seq, 6)
    XCTAssertEqual(snapshot.entries.last?.seq, 9)
  }

  func testSnapshotCursorAndTabFilter() {
    let journal = TabStateJournal()
    var a = tab("a", title: "one")
    let b = tab("b", title: "two")
    _ = journal.recordDiff(tabs: [a, b], activeTabId: nil)
    let cursor = journal.snapshot().next

    a.titleMetadata.terminalTitle = "later"
    _ = journal.recordDiff(tabs: [a, b], activeTabId: nil)

    let sinceCursor = journal.snapshot(since: cursor)
    XCTAssertEqual(sinceCursor.entries.count, 1)
    XCTAssertEqual(sinceCursor.entries.first?.tabId, "a")

    let filtered = journal.snapshot(tabId: "b")
    XCTAssertEqual(filtered.entries.count, 1)
    XCTAssertEqual(filtered.entries.first?.tabId, "b")
  }

  func testNoteEntriesInterleaveWithState() {
    let journal = TabStateJournal()
    let a = tab("a", title: "one")
    _ = journal.recordDiff(tabs: [a], activeTabId: nil)
    let note = journal.note(
      tabId: "a", note: TabStateJournal.bannerPostedNote, text: "Awaiting your input")
    XCTAssertEqual(note.kind, "note")
    XCTAssertEqual(note.note, TabStateJournal.bannerPostedNote)
    XCTAssertEqual(note.text, "Awaiting your input")
    XCTAssertEqual(journal.snapshot().entries.map(\.kind), ["state", "note"])
  }

  func testClosedTabStateIsEvictedSoReopenedIdReemits() {
    let journal = TabStateJournal()
    let a = tab("a", title: "one")
    XCTAssertEqual(journal.recordDiff(tabs: [a], activeTabId: nil).count, 1)
    _ = journal.recordDiff(tabs: [], activeTabId: nil)
    XCTAssertEqual(
      journal.recordDiff(tabs: [a], activeTabId: nil).count, 1,
      "a re-appearing tab id must re-emit even with an identical projection")
  }

  func testDumpWritesOneNdjsonLinePerEntry() throws {
    let journal = TabStateJournal()
    var a = tab("a", title: "one")
    _ = journal.recordDiff(tabs: [a], activeTabId: "a")
    a.titleMetadata.notification = TabNotification(text: "needs you", urgent: true)
    _ = journal.recordDiff(tabs: [a], activeTabId: "a")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tab-journal-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try journal.dump(to: root)

    let lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
    XCTAssertEqual(lines.count, 2)
    let decoded = try lines.map {
      try JSONDecoder().decode(TabStateJournalEntry.self, from: Data($0.utf8))
    }
    XCTAssertEqual(decoded.map(\.seq), [0, 1])
    XCTAssertEqual(decoded.last?.metadata?.notification?.text, "needs you")
  }

  func testCaptureEventMirrorCarriesBadgeFields() {
    let journal = TabStateJournal()
    var a = tab("a", title: "one")
    a.titleMetadata.notification = TabNotification(text: "needs you", urgent: true, count: 2)
    let entry = journal.recordDiff(tabs: [a], activeTabId: "a")[0]

    let event = entry.captureEvent(sessionId: "s-a")
    XCTAssertEqual(event.kind, "tab.metadata")
    XCTAssertEqual(event.tabId, "a")
    XCTAssertEqual(event.sessionId, "s-a")
    XCTAssertEqual(event.timeNs, entry.timeNs)
    XCTAssertEqual(event.selected, true)
    XCTAssertEqual(event.text, "needs you")
    XCTAssertEqual(event.urgent, true)
    XCTAssertEqual(event.count, 2)
  }
}
