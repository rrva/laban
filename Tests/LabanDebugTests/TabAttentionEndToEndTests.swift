import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

/// End-to-end coverage for the early "needs you" path: a real /bin/sh PTY
/// session flips its terminal title to Claude Code's awaiting-input marker
/// ("✳ …"), and the tests assert the full reaction — sidebar attention via
/// the classifier, the once-per-episode banner broadcast, the agent's own
/// debounced OSC notification being deduplicated, and everything landing in
/// the queryable tab-state journal (`/debug/tab-journal`).
///
/// Background: capture appkit-2026-06-12T06-21-05Z showed Claude Code
/// renders its prompt and flips the title ~6s before it emits OSC 777, so
/// the title flip is the earliest blocked-on-the-user signal available.
final class TabAttentionEndToEndTests: XCTestCase {

  func testAwaitingTitleMarkerRaisesNeedsActionOnBackgroundTab() throws {
    let harness = try TitleHarness(runId: "attention-e2e-await-marker")
    defer { harness.tearDown() }

    try harness.runClient("osc0 '✳ Pick an option' 30")
    _ = try harness.waitForTabState { $0.terminalTitle == "✳ Pick an option" }

    try harness.newTab()
    let tab = try harness.waitForTabState { $0.attention == "needsAction" }
    XCTAssertEqual(
      tab.attention, "needsAction",
      "the awaiting-input title marker must demand action on a background tab")
  }

  func testTitleFlipBannersOnceAndAgentOscIsDeduplicated() throws {
    let harness = try TitleHarness(runId: "attention-e2e-await-banner")
    defer { harness.tearDown() }
    let tabId = harness.runtime.model.tabs[0].id

    // Working spinner first: no banner.
    try harness.type("printf '\\033]0;⠂ Claude Code\\007'\n")
    _ = try harness.waitForTabState { $0.terminalTitle == "⠂ Claude Code" }
    XCTAssertTrue(bannerNotes(harness, tabId: tabId).isEmpty)

    // The flip to the awaiting marker banners immediately (the journal note is
    // written by the runtime's onAgentNotification wiring — banner parity;
    // the broadcast hops the main queue, so poll until it lands).
    try harness.type("printf '\\033]0;✳ Pick an option\\007'\n")
    _ = try harness.waitForTabState { _ in
      !self.bannerNotes(harness, tabId: tabId).isEmpty
    }
    var notes = bannerNotes(harness, tabId: tabId)
    XCTAssertEqual(notes.count, 1, "the title flip must banner exactly once")
    XCTAssertEqual(notes.first?.text, AppModel.awaitingInputNotificationText)

    // The agent's own debounced notification for the same wait: badge applies,
    // banner is swallowed.
    // The OSC 777 path folds the notify title into the text ("Title: body").
    try harness.type("printf '\\033]777;notify;Claude Code;Claude needs your permission\\007'\n")
    let oscBadgeText = "Claude Code: Claude needs your permission"
    _ = try harness.waitForTabState { _ in
      harness.runtime.model.tabs.first { $0.id == tabId }?
        .titleMetadata.notification?.text == oscBadgeText
    }
    notes = bannerNotes(harness, tabId: tabId)
    XCTAssertEqual(notes.count, 1, "the duplicate OSC banner must be swallowed")
    let badge = harness.runtime.model.tabs.first { $0.id == tabId }?.titleMetadata.notification
    XCTAssertEqual(badge?.count, 1)
    XCTAssertEqual(badge?.urgent, true)

    // The journal tells the whole story in order: the title-flip state entry
    // precedes the banner note, which precedes the badge state entry.
    let entries = harness.runtime.model.tabJournal.snapshot(tabId: tabId).entries
    let flipSeq = entries.first { $0.metadata?.terminalTitle == "✳ Pick an option" }?.seq
    let noteSeq = entries.first { $0.note == TabStateJournal.bannerPostedNote }?.seq
    let badgeSeq = entries.first { $0.metadata?.notification?.text == oscBadgeText }?.seq
    XCTAssertNotNil(flipSeq, "the title flip must be journaled")
    XCTAssertNotNil(badgeSeq, "the badge application must be journaled")
    if let flipSeq, let noteSeq, let badgeSeq {
      XCTAssertLessThan(flipSeq, noteSeq)
      XCTAssertLessThan(noteSeq, badgeSeq)
    }
  }

  func testTabJournalEndpointServesEntriesWithCursor() throws {
    let harness = try TitleHarness(runId: "attention-e2e-journal-endpoint")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]0;✳ Pick an option\\007'\n")
    _ = try harness.waitForTabState { $0.terminalTitle == "✳ Pick an option" }

    let response = harness.runtime.tabJournalResponse(since: 0, tabId: nil)
    XCTAssertEqual(response.status, 200)
    let obj = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    let entries = obj["entries"] as! [[String: Any]]
    let next = obj["next"] as! Int
    XCTAssertFalse(entries.isEmpty)
    XCTAssertGreaterThan(next, 0)
    XCTAssertTrue(
      entries.contains { ($0["kind"] as? String) == "state" && $0["timeNs"] != nil },
      "state entries with timestamps must be served")

    // The cursor pages: nothing new since `next`.
    let tail = harness.runtime.tabJournalResponse(since: next, tabId: nil)
    let tailObj = try JSONSerialization.jsonObject(with: tail.body) as! [String: Any]
    XCTAssertEqual((tailObj["entries"] as! [[String: Any]]).count, 0)
  }

  private func bannerNotes(
    _ harness: TitleHarness, tabId: String
  ) -> [TabStateJournalEntry] {
    harness.runtime.model.tabJournal.snapshot(tabId: tabId).entries.filter {
      $0.note == TabStateJournal.bannerPostedNote
    }
  }
}
