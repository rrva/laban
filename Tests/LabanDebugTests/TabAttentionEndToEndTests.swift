import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

/// End-to-end coverage for Claude Code's title-flip attention path: a real
/// /bin/sh PTY session flips its terminal title to the awaiting-input marker
/// ("✳ …"), and the tests assert the full reaction — informational sidebar
/// attention, urgent banners only on blocking OSC, merge/dedupe, and
/// everything landing in the queryable tab-state journal (`/debug/tab-journal`).
///
/// Background: capture appkit-2026-06-12T06-21-05Z showed Claude Code
/// renders its prompt and flips the title ~6s before it emits OSC 777.
final class TabAttentionEndToEndTests: XCTestCase {

  func testAwaitingTitleMarkerMarksBackgroundTabReady() throws {
    let harness = try TitleHarness(runId: "attention-e2e-await-marker")
    defer { harness.tearDown() }

    try harness.runClient("osc0 '✳ Pick an option' 30")
    _ = try harness.waitForTabState { $0.terminalTitle == "✳ Pick an option" }

    try harness.newTab()
    let tab = try harness.waitForTabState { $0.attention == "done" }
    XCTAssertEqual(
      tab.attention, "done",
      "the awaiting-input title flip alone is informational until OSC confirms urgency")
  }

  func testTitleFlipThenPermissionOscBannersOnce() throws {
    let harness = try TitleHarness(runId: "attention-e2e-await-banner")
    defer { harness.tearDown() }
    let tabId = harness.runtime.model.tabs[0].id

    // Working spinner first: no banner.
    try harness.type("printf '\\033]0;⠂ Claude Code\\007'\n")
    _ = try harness.waitForTabState { $0.terminalTitle == "⠂ Claude Code" }
    XCTAssertTrue(bannerNotes(harness, tabId: tabId).isEmpty)

    // The flip to the awaiting marker raises an informational sidebar badge only.
    try harness.type("printf '\\033]0;✳ Pick an option\\007'\n")
    _ = try harness.waitForTabState { _ in
      harness.runtime.model.tabs.first { $0.id == tabId }?
        .titleMetadata.notification?.text == AppModel.awaitingInputNotificationText
    }
    var notes = bannerNotes(harness, tabId: tabId)
    XCTAssertTrue(notes.isEmpty, "the title flip must not banner by itself")

    // The agent's debounced permission notification upgrades urgency and
    // banners once.
    // The OSC 777 path folds the notify title into the text ("Title: body").
    try harness.type("printf '\\033]777;notify;Claude Code;Claude needs your permission\\007'\n")
    let oscBadgeText = "Claude Code: Claude needs your permission"
    _ = try harness.waitForTabState { _ in
      harness.runtime.model.tabs.first { $0.id == tabId }?
        .titleMetadata.notification?.text == oscBadgeText
    }
    notes = bannerNotes(harness, tabId: tabId)
    XCTAssertEqual(notes.count, 1, "the permission OSC must banner exactly once")
    XCTAssertEqual(notes.first?.text, oscBadgeText)
    let badge = harness.runtime.model.tabs.first { $0.id == tabId }?.titleMetadata.notification
    XCTAssertEqual(badge?.count, 1)
    XCTAssertEqual(badge?.urgent, true)

    // The journal tells the whole story in order: the title-flip state entry
    // precedes the permission badge state entry, which precedes the banner note.
    let entries = harness.runtime.model.tabJournal.snapshot(tabId: tabId).entries
    let flipSeq = entries.first { $0.metadata?.terminalTitle == "✳ Pick an option" }?.seq
    let noteSeq = entries.first { $0.note == TabStateJournal.bannerPostedNote }?.seq
    let badgeSeq = entries.first { $0.metadata?.notification?.text == oscBadgeText }?.seq
    XCTAssertNotNil(flipSeq, "the title flip must be journaled")
    XCTAssertNotNil(badgeSeq, "the badge application must be journaled")
    if let flipSeq, let noteSeq, let badgeSeq {
      XCTAssertLessThan(flipSeq, badgeSeq)
      XCTAssertLessThan(badgeSeq, noteSeq)
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
