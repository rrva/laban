import XCTest

@testable import LabanCore

final class TabAttentionTests: XCTestCase {
  private func meta(
    terminalTitle: String? = nil,
    activityState: TabActivityState = .running,
    awaitingInput: Bool = false,
    notification: TabNotification? = nil,
    unseenOutput: Bool = false,
    bellAttention: Bool = false
  ) -> TabTitleMetadata {
    TabTitleMetadata(
      terminalTitle: terminalTitle,
      displayTitle: "t",
      titleSource: .fallback,
      agent: TabAgentMetadata(awaitingInput: awaitingInput),
      activityState: activityState,
      unseenOutput: unseenOutput,
      bellAttention: bellAttention,
      notification: notification)
  }

  private func classify(_ m: TabTitleMetadata, isActive: Bool = false) -> TabAttention {
    TabAttentionClassifier.classify(m, isActive: isActive)
  }

  /// A focused tab is always quiet, even when it carries every attention signal.
  func testFocusedTabIsAlwaysNone() {
    let m = meta(
      activityState: .waiting,
      awaitingInput: true,
      notification: TabNotification(text: "approval", urgent: true),
      unseenOutput: true,
      bellAttention: true)
    XCTAssertEqual(classify(m, isActive: true), .none)
  }

  func testUrgentNotificationIsNeedsAction() {
    let m = meta(notification: TabNotification(text: "approval requested", urgent: true))
    XCTAssertEqual(classify(m), .needsAction)
  }

  func testWaitingIsNeedsAction() {
    XCTAssertEqual(classify(meta(activityState: .waiting)), .needsAction)
  }

  func testAwaitingInputIsNeedsAction() {
    XCTAssertEqual(classify(meta(awaitingInput: true)), .needsAction)
  }

  /// Codex prefixes its terminal title with "[ ! ]" while blocked on the user
  /// — its only unconditional cross-terminal signal — so the prefix counts as
  /// a blocking request.
  func testActionRequiredTitlePrefixIsNeedsAction() {
    let m = meta(terminalTitle: "[ ! ] Action Required | codex | main")
    XCTAssertEqual(classify(m), .needsAction)
  }

  /// Claude Code's "✳" is the *resting* title of every idle agent tab, so it
  /// must NOT classify needsAction statelessly — that turned every restored
  /// or viewed-then-backgrounded agent tab permanently yellow. The flip is
  /// handled as an edge in AppModel (urgent badge + banner), which clears on
  /// viewing and stays cleared.
  func testAwaitingInputTitleMarkerAloneDoesNotClassify() {
    XCTAssertEqual(classify(meta(terminalTitle: "✳ Test AskUserQuestion tool")), .none)
    XCTAssertEqual(classify(meta(terminalTitle: "⠂ Claude Code")), .none)
  }

  /// The episode predicate covers both agents' blocked-title conventions.
  func testTitleSignalsAwaitingInputCoversBothMarkers() {
    XCTAssertTrue(
      TabAttentionClassifier.titleSignalsAwaitingInput(
        meta(terminalTitle: "✳ Test AskUserQuestion tool")))
    XCTAssertTrue(
      TabAttentionClassifier.titleSignalsAwaitingInput(
        meta(terminalTitle: "[ ! ] Action Required | codex")))
    XCTAssertFalse(
      TabAttentionClassifier.titleSignalsAwaitingInput(meta(terminalTitle: "⠂ Claude Code")))
    XCTAssertFalse(TabAttentionClassifier.titleSignalsAwaitingInput(meta(terminalTitle: nil)))
  }

  func testOrdinaryTerminalTitleIsNotNeedsAction() {
    XCTAssertEqual(classify(meta(terminalTitle: "vim README.md")), .none)
  }

  func testNonUrgentNotificationIsDone() {
    let m = meta(notification: TabNotification(text: "turn complete", urgent: false))
    XCTAssertEqual(classify(m), .done)
  }

  func testUnseenOutputIsPassive() {
    XCTAssertEqual(classify(meta(unseenOutput: true)), .passive)
  }

  func testBellIsPassive() {
    XCTAssertEqual(classify(meta(bellAttention: true)), .passive)
  }

  func testPlainRunningIsNone() {
    XCTAssertEqual(classify(meta()), .none)
  }

  /// Priority: a blocking request outranks an informational completion, which
  /// outranks low-salience activity.
  func testNeedsActionOutranksDoneAndPassive() {
    let m = meta(
      awaitingInput: true,
      notification: TabNotification(text: "done", urgent: false),
      unseenOutput: true)
    XCTAssertEqual(classify(m), .needsAction)
  }

  func testDoneOutranksPassive() {
    let m = meta(
      notification: TabNotification(text: "finished", urgent: false),
      unseenOutput: true)
    XCTAssertEqual(classify(m), .done)
  }

  // MARK: - anyNeedsAction (render-loop idle gate predicate)

  private func waitingTab(_ id: String) -> Tab {
    var t = Tab(id: id, position: 1, title: id, isActive: false, sessionId: "s-\(id)")
    t.titleMetadata.activityState = .waiting
    return t
  }

  func testAnyNeedsActionTrueForUnfocusedWaitingTab() {
    let tabs = [
      waitingTab("a"), Tab(id: "b", position: 2, title: "b", isActive: true, sessionId: "sb"),
    ]
    XCTAssertTrue(TabAttentionClassifier.anyNeedsAction(tabs: tabs, activeTabId: "b"))
  }

  func testAnyNeedsActionIgnoresTheFocusedTab() {
    // The only waiting tab is the focused one -> nothing should animate.
    let tabs = [waitingTab("a")]
    XCTAssertFalse(TabAttentionClassifier.anyNeedsAction(tabs: tabs, activeTabId: "a"))
  }

  func testAnyNeedsActionFalseWhenNothingWaits() {
    let tabs = [Tab(id: "a", position: 1, title: "a", isActive: false, sessionId: "sa")]
    XCTAssertFalse(TabAttentionClassifier.anyNeedsAction(tabs: tabs, activeTabId: "x"))
  }
}
