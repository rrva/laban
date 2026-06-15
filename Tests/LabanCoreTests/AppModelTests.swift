import Darwin
import Dispatch
import LabanTerminalCore
import XCTest

@testable import LabanCore

private func fixtureFactory(_ size: LabanTerminalSize) throws -> Session {
  try Session.fixture(size: size)
}

private func makeModel(rows: Int32 = 24, cols: Int32 = 80) throws -> AppModel {
  var size = LabanTerminalSize()
  size.rows = rows
  size.cols = cols
  return try AppModel(initialSize: size, sessionFactory: fixtureFactory)
}

private func canonicalPath(_ path: String) -> String {
  path.withCString { cPath in
    guard let resolved = realpath(cPath, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

private func processMetadata(
  pid: Int,
  process: String,
  command: String,
  cwd: String? = nil
) -> Session.ProcessMetadata {
  Session.ProcessMetadata(
    childPid: pid,
    foregroundPid: pid,
    foregroundProcess: process,
    foregroundCommand: command,
    cwd: cwd
  )
}

private func pumpMainQueue(timeout: TimeInterval = 1.0) {
  let pumped = XCTestExpectation(description: "main queue pumped")
  DispatchQueue.main.async { pumped.fulfill() }
  XCTWaiter().wait(for: [pumped], timeout: timeout)
}

private final class WorkspaceMutationCounter {
  private(set) var count = 0
  init(model: AppModel) {
    let prior = model.onWorkspaceMutation
    model.onWorkspaceMutation = { [weak self] in
      self?.count += 1
      prior?()
    }
  }
}

final class AppModelTests: XCTestCase {

  func testCreateTabRunningArgvUsesCommandFactoryAndRecordsArgv() throws {
    let model = try makeModel()
    var capturedArgv: [String]?
    var capturedCwd: String?
    model.commandSessionFactory = { size, cwd, argv in
      capturedArgv = argv
      capturedCwd = cwd
      return try Session.fixture(size: size)
    }
    let tab = try model.createTab(runningArgv: ["ssh", "host"], cwd: "/tmp")
    XCTAssertEqual(capturedArgv, ["ssh", "host"])
    XCTAssertEqual(capturedCwd, "/tmp")
    XCTAssertEqual(model.launchArgv(forTab: tab.id), ["ssh", "host"])
    XCTAssertTrue(model.tabs.contains { $0.id == tab.id && $0.isActive })
  }

  func testCreateTabRunningArgvRecordsArgvWithoutCommandFactory() throws {
    let model = try makeModel()
    // No commandSessionFactory: the session falls back to the default shell
    // factory, but the argv is still recorded so a daemon backend can launch it.
    let tab = try model.createTab(runningArgv: ["ssh", "host"])
    XCTAssertEqual(model.launchArgv(forTab: tab.id), ["ssh", "host"])
  }

  func testLaunchArgvClearedOnTabClose() throws {
    let model = try makeModel()
    model.commandSessionFactory = { size, _, _ in try Session.fixture(size: size) }
    let tab = try model.createTab(runningArgv: ["ssh", "host"])
    XCTAssertEqual(model.launchArgv(forTab: tab.id), ["ssh", "host"])
    try model.closeTab(tab.id)
    XCTAssertNil(model.launchArgv(forTab: tab.id))
  }

  func testInitialModelHasOneActiveTabAndSession() throws {
    let model = try makeModel()
    XCTAssertEqual(model.tabs.count, 1)
    XCTAssertEqual(model.tabs[0].position, 1)
    XCTAssertTrue(model.tabs[0].isActive)
    let session = model.session(forTab: model.tabs[0].id)
    XCTAssertNotNil(session)
    XCTAssertFalse(session!.isClosed)
  }

  func testOSC9DesktopNotificationReachesAgentNotificationHook() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("initial tab must have a session")
      return
    }

    var received: [(tab: Tab.ID, text: String)] = []
    model.onAgentNotification = { id, text in received.append((id, text)) }

    // Informational turn-complete OSC badges the tab but does not banner.
    session.feedOutput(Array("\u{1b}]9;Agent turn complete\u{07}".utf8))
    pumpMainQueue()
    XCTAssertTrue(received.isEmpty, "informational OSC must not reach the banner hook")
    XCTAssertEqual(
      model.tabs.first { $0.id == tabId }?.titleMetadata.notification?.text,
      "Agent turn complete")

    // Blocking approval OSC banners once.
    session.feedOutput(Array("\u{1b}]9;Approval requested: rm -rf /\u{07}".utf8))
    pumpMainQueue()
    XCTAssertEqual(received.count, 1, "urgent OSC must fire onAgentNotification exactly once")
    XCTAssertEqual(received.first?.tab, tabId)
    XCTAssertEqual(received.first?.text, "Approval requested: rm -rf /")

    // A ConEmu progress report (OSC 9;4) must not be surfaced as a notification.
    session.feedOutput(Array("\u{1b}]9;4;1;75\u{07}".utf8))
    pumpMainQueue()
    XCTAssertEqual(received.count, 1, "OSC 9;4 progress must not reach the notification hook")
  }

  func testClaudeWaitingForInputNotificationIsInformational() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("initial tab must have a session")
      return
    }
    var banners: [String] = []
    model.onAgentNotification = { _, text in banners.append(text) }

    session.feedOutput(
      Array("\u{1b}]9;Claude Code: Claude is waiting for your input\u{07}".utf8))
    pumpMainQueue()

    let badge = model.tabs.first { $0.id == tabId }?.titleMetadata.notification
    XCTAssertEqual(badge?.urgent, false)
    XCTAssertTrue(banners.isEmpty)
  }


  func testIsUrgentNotificationClassification() {
    // Unambiguous blocking requests are urgent.
    XCTAssertTrue(AppModel.isUrgentNotification("Claude needs your permission"))
    XCTAssertTrue(AppModel.isUrgentNotification("Approval requested: rm -rf /"))
    XCTAssertTrue(AppModel.isUrgentNotification("Codex wants to run a command"))

    // Turn-complete / ready-at-prompt phrasings are informational.
    XCTAssertFalse(AppModel.isUrgentNotification("Agent turn complete"))
    XCTAssertFalse(
      AppModel.isUrgentNotification("Claude Code: Claude is waiting for your input"))
    // A bare "still waiting on you" carries no blocking keyword: informational.
    XCTAssertFalse(AppModel.isUrgentNotification("Still waiting on you"))

    // A blocking keyword wins even when the message also echoes a completion
    // phrase — a real block must never be silenced.
    XCTAssertTrue(
      AppModel.isUrgentNotification("Approval needed — waiting for your input"))
  }

  func testOSC9NotificationBadgesTabAndClearsOnViewing() throws {
    let model = try makeModel()
    try model.createTab()  // tab[1] is now active; tab[0] is a background tab
    let bgTabId = model.tabs[0].id
    guard let bgSession = model.session(forTab: bgTabId) else {
      XCTFail("background tab must have a session")
      return
    }

    // Turn-complete on a background tab -> an informational notification badge.
    bgSession.feedOutput(Array("\u{1b}]9;Agent turn complete\u{07}".utf8))
    pumpMainQueue()
    let first = model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification
    XCTAssertEqual(first?.text, "Agent turn complete")
    XCTAssertEqual(first?.count, 1)
    XCTAssertEqual(first?.urgent, false)

    // A second, action-needed notification accumulates the count and goes urgent.
    bgSession.feedOutput(Array("\u{1b}]9;Approval requested: rm -rf /\u{07}".utf8))
    pumpMainQueue()
    let second = model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification
    XCTAssertEqual(second?.count, 2)
    XCTAssertEqual(second?.urgent, true, "an approval request must render urgent")

    // Opening the tab clears its badge.
    model.selectTab(bgTabId)
    XCTAssertNil(
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification,
      "selecting the tab must clear its notification")

    // A notification on the now-active tab clears when the user returns to the app.
    bgSession.feedOutput(Array("\u{1b}]9;Agent turn complete\u{07}".utf8))
    pumpMainQueue()
    XCTAssertNotNil(model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification)
    model.markActiveTabNotificationSeen()
    XCTAssertNil(
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification,
      "returning to the app must clear the active tab's notification")
  }

  func testFailedCommandDotArmsInBackgroundAndClearsOnFocus() throws {
    let model = try makeModel()
    try model.createTab()  // tab[1] is active; tab[0] is a background tab
    let bgTabId = model.tabs[0].id
    guard let bgSession = model.session(forTab: bgTabId) else {
      XCTFail("background tab must have a session")
      return
    }
    func bgExit() -> Int? {
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.lastCommandExitCode
    }

    // A command that finishes non-zero on a background tab arms the steady
    // failed-command dot (the sidebar paints it red iff lastCommandExitCode != 0).
    bgSession.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))
    bgSession.feedOutput(Array("\u{1B}]133;C\u{07}".utf8))
    bgSession.feedOutput(Array("\u{1B}]133;D;1\u{07}".utf8))
    pumpMainQueue()
    // lastCommandExitCode != 0 is exactly what `SidebarProducer`'s steady red
    // dot keys on (the color mapping itself is covered by SidebarShellIndicatorTests).
    XCTAssertEqual(bgExit(), 1, "a background command exiting non-zero must arm the dot")

    // Focusing the tab acknowledges the failure and clears the dot.
    model.selectTab(bgTabId)
    XCTAssertNil(bgExit(), "selecting the tab must clear the failed-command dot")

    // A stale prompt re-emission (the reducer still carries exitCode 1) reaches
    // the now-active tab but must NOT re-arm the dismissed dot.
    bgSession.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))
    pumpMainQueue()
    XCTAssertNil(bgExit(), "a prompt re-emit on the active tab must not re-arm the dot")

    // A command that fails while the user is watching the tab earns no dot —
    // they saw it — even after they later switch away.
    bgSession.feedOutput(Array("\u{1B}]133;C\u{07}".utf8))
    bgSession.feedOutput(Array("\u{1B}]133;D;2\u{07}".utf8))
    pumpMainQueue()
    XCTAssertNil(bgExit(), "a command failing on the active tab must not arm the dot")
    model.selectTab(model.tabs[1].id)
    XCTAssertNil(bgExit(), "the dot stays clear after switching away from a watched failure")
  }

  func testFailedCommandDotStaysDismissedUntilANewCommandFails() throws {
    // Regression (capture-confirmed): after the dot is dismissed by focusing
    // the tab, a bare prompt redraw (OSC 133 A, emitted on every Enter) on the
    // now-background tab re-delivered the reducer's stale exit code and
    // re-armed the dot. Repro: run `false`, focus the tab, switch away, press
    // Enter — the dot came back. It must stay dismissed until a *new* command
    // fails.
    let model = try makeModel()
    try model.createTab()  // tab[1] active; tab[0] background
    let bgTabId = model.tabs[0].id
    let fgTabId = model.tabs[1].id
    guard let bgSession = model.session(forTab: bgTabId) else {
      XCTFail("background tab must have a session")
      return
    }
    func bgExit() -> Int? {
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.lastCommandExitCode
    }
    func runCommand(exiting code: Int) {
      bgSession.feedOutput(Array("\u{1B}]133;C\u{07}".utf8))
      bgSession.feedOutput(Array("\u{1B}]133;D;\(code)\u{07}".utf8))
      bgSession.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))  // next prompt
      pumpMainQueue()
    }

    runCommand(exiting: 1)
    XCTAssertEqual(bgExit(), 1, "a background command exiting non-zero arms the dot")

    model.selectTab(bgTabId)
    XCTAssertNil(bgExit(), "focusing the tab dismisses the dot")
    model.selectTab(fgTabId)
    XCTAssertNil(bgExit(), "the dot stays clear after switching away")

    // The crux: a prompt redraw re-emits OSC 133 A carrying the stale exit
    // code 1 to the background tab. It must NOT re-arm the dismissed dot.
    bgSession.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))
    pumpMainQueue()
    XCTAssertNil(bgExit(), "a bare prompt redraw must not re-arm a dismissed dot")

    // But a genuinely new failing command does re-arm it.
    runCommand(exiting: 1)
    XCTAssertEqual(bgExit(), 1, "a new failing command re-arms the dot")
  }

  func testSelectingTabClearsExplicitTabIndicatorColor() throws {
    let model = try makeModel()
    try model.createTab()  // tab[1] is active; tab[0] is a background tab
    let bgTabId = model.tabs[0].id
    guard let bgSession = model.session(forTab: bgTabId) else {
      XCTFail("background tab must have a session")
      return
    }

    bgSession.feedOutput(Array("\u{1B}]21337;indicator=#d33;status=failed\u{07}".utf8))
    pumpMainQueue()

    XCTAssertEqual(
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.agentStatus.indicatorColor,
      "#d33")
    XCTAssertEqual(
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.agentStatus.statusText,
      "failed")

    model.selectTab(bgTabId)

    let status = model.tabs.first { $0.id == bgTabId }?.titleMetadata.agentStatus
    XCTAssertNil(status?.indicatorColor, "selecting the tab must acknowledge its OSC indicator")
    XCTAssertEqual(
      status?.statusText, "failed",
      "selection must not erase process-owned status text")
  }

  func testNotificationsSuppressedDuringRestoreGraceWindow() throws {
    let model = try makeModel()
    try model.createTab()
    let bgTabId = model.tabs[0].id
    guard let bgSession = model.session(forTab: bgTabId) else {
      XCTFail("background tab must have a session")
      return
    }

    var banners: [String] = []
    model.onAgentNotification = { _, text in banners.append(text) }

    // `replaceTabs` opens this window so a restored agent's resume-time OSC 9
    // doesn't badge every tab on launch.
    model.notificationSuppressionDeadline = Date().addingTimeInterval(60)
    bgSession.feedOutput(Array("\u{1b}]9;Claude needs your permission\u{07}".utf8))
    pumpMainQueue()
    XCTAssertNil(
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification,
      "OSC 9 during the restore grace window must not badge the tab")
    XCTAssertTrue(
      banners.isEmpty,
      "the restore-burst must not banner either — a relaunch posted ~40 stale banners")

    // After the window closes, notifications badge normally.
    model.notificationSuppressionDeadline = nil
    bgSession.feedOutput(Array("\u{1b}]9;Agent turn complete\u{07}".utf8))
    pumpMainQueue()
    XCTAssertNotNil(
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification,
      "OSC 9 after the grace window must badge normally")
  }

  // MARK: - Awaiting-input title marker -> early banner (episodes)

  func testAwaitMarkerRaisesInformationalBadgeWithoutBanner() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    var banners: [(tab: Tab.ID, text: String)] = []
    model.onAgentNotification = { id, text in banners.append((id, text)) }

    try model.updateTerminalTitle("⠂ Claude Code", forTab: tabId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty, "a working spinner title must not banner")

    try model.updateTerminalTitle("✳ Pick an option", forTab: tabId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty, "the title flip must not banner — wait for OSC urgency")
    let badge = model.tabs.first { $0.id == tabId }?.titleMetadata.notification
    XCTAssertEqual(badge?.text, AppModel.awaitingInputNotificationText)
    XCTAssertEqual(badge?.urgent, false)
    XCTAssertEqual(badge?.count, 1)

    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty, "re-detection inside the same episode must not re-banner")

    // Flip back to working: the unseen synthetic badge is stale (the agent
    // resumed without its own notification) and must retire.
    try model.updateTerminalTitle("⠂ Claude Code", forTab: tabId)
    model.detectAwaitMarkerTransitions()
    XCTAssertNil(
      model.tabs.first { $0.id == tabId }?.titleMetadata.notification,
      "a synthetic-only unseen badge must clear when the agent resumes working")

    // Waiting again is a new episode: informational badge only, still no banner.
    try model.updateTerminalTitle("✳ Pick an option", forTab: tabId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty)
    XCTAssertNotNil(model.tabs.first { $0.id == tabId }?.titleMetadata.notification)
  }

  func testRealNotificationDuringCoveredEpisodeBannersOnlyWhenUrgent() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("initial tab must have a session")
      return
    }
    var banners: [String] = []
    model.onAgentNotification = { _, text in banners.append(text) }

    try model.updateTerminalTitle("✳ Pick an option", forTab: tabId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty, "the title flip alone must not banner")
    XCTAssertEqual(
      model.tabs.first { $0.id == tabId }?.titleMetadata.notification?.text,
      AppModel.awaitingInputNotificationText)

    // Turn-complete OSC merges quietly — no banner, stays informational.
    session.feedOutput(
      Array("\u{1b}]9;Claude Code: Claude is waiting for your input\u{07}".utf8))
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty, "informational turn-complete OSC must not banner")
    let informational = model.tabs.first { $0.id == tabId }?.titleMetadata.notification
    XCTAssertEqual(informational?.text, "Claude Code: Claude is waiting for your input")
    XCTAssertEqual(informational?.urgent, false)
    XCTAssertEqual(informational?.count, 1, "the merge must not inflate the unread count")

    // A blocking OSC during the same episode upgrades urgency and banners once.
    session.feedOutput(Array("\u{1b}]9;Claude needs your permission\u{07}".utf8))
    pumpMainQueue()
    XCTAssertEqual(banners, ["Claude needs your permission"])
    let urgent = model.tabs.first { $0.id == tabId }?.titleMetadata.notification
    XCTAssertEqual(urgent?.urgent, true)

    // A further urgent notification in the same episode banners normally.
    session.feedOutput(Array("\u{1b}]9;Still needs your approval\u{07}".utf8))
    pumpMainQueue()
    XCTAssertEqual(banners.count, 2)
  }

  func testAwaitMarkerBannerSkippedForFrontmostTab() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    model.isTabFrontmost = { _ in true }
    var banners: [String] = []
    model.onAgentNotification = { _, text in banners.append(text) }

    try model.updateTerminalTitle("✳ Pick an option", forTab: tabId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty, "no banner for the tab the user is already watching")
    XCTAssertNil(
      model.tabs.first { $0.id == tabId }?.titleMetadata.notification,
      "no badge for the tab the user is already watching")
  }

  func testViewedAwaitTabStaysClearAfterUnfocus() throws {
    let model = try makeModel()
    try model.createTab()  // tab[1] is now active; tab[0] is a background tab
    let bgTabId = model.tabs[0].id
    var banners: [String] = []
    model.onAgentNotification = { _, text in banners.append(text) }

    try model.updateTerminalTitle("✳ Pick an option", forTab: bgTabId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty)
    XCTAssertNotNil(model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification)

    // Viewing the tab clears the badge...
    model.selectTab(bgTabId)
    XCTAssertNil(model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification)

    // ...and backgrounding it again must NOT relight it: the marker is still
    // in the title, but this wait was already announced and seen.
    let otherId = model.tabs.first { $0.id != bgTabId }!.id
    model.selectTab(otherId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertNil(
      model.tabs.first { $0.id == bgTabId }?.titleMetadata.notification,
      "a seen await episode must not re-badge when the tab is backgrounded again")
    XCTAssertTrue(banners.isEmpty, "and it must not re-banner either")
  }

  func testAwaitMarkerBannerSuppressedDuringRestoreGraceWindow() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    model.notificationSuppressionDeadline = Date().addingTimeInterval(60)
    var banners: [String] = []
    model.onAgentNotification = { _, text in banners.append(text) }

    try model.updateTerminalTitle("✳ Pick an option", forTab: tabId)
    model.detectAwaitMarkerTransitions()
    pumpMainQueue()
    XCTAssertTrue(banners.isEmpty, "a restored agent's resume-time title must not banner")
    XCTAssertNil(
      model.tabs.first { $0.id == tabId }?.titleMetadata.notification,
      "a restored wall of idle agent tabs must not all light up")
  }

  // MARK: - Tab-state journal

  func testJournalRecordsNotificationBadgeTransition() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("initial tab must have a session")
      return
    }
    let cursor = model.tabJournal.snapshot().next

    session.feedOutput(Array("\u{1b}]9;Agent turn complete\u{07}".utf8))
    pumpMainQueue()

    let entries = model.tabJournal.snapshot(since: cursor).entries
    XCTAssertTrue(
      entries.contains {
        $0.tabId == tabId && $0.kind == "state"
          && $0.metadata?.notification?.text == "Agent turn complete"
      },
      "the badge transition must land in the tab journal")
  }

  func testJournalMirrorsIntoCaptureSinkAsTabMetadata() throws {
    final class CollectingSink: CaptureSink {
      var events: [CaptureTimelineEvent] = []
      private var seq = 0
      func nextSequence() -> Int {
        defer { seq += 1 }
        return seq
      }
      func record(_ event: CaptureTimelineEvent) { events.append(event) }
      func recordBytes(
        direction: CaptureByteDirection,
        sessionId: Session.ID?,
        frame: Int,
        bytes: UnsafeRawBufferPointer,
        preview: String?
      ) -> CaptureByteRef? { nil }
    }

    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("initial tab must have a session")
      return
    }
    let sink = CollectingSink()
    model.captureSink = sink

    session.feedOutput(Array("\u{1b}]9;Claude needs your permission\u{07}".utf8))
    pumpMainQueue()

    let mirrored = sink.events.filter { $0.kind == "tab.metadata" && $0.tabId == tabId }
    XCTAssertFalse(mirrored.isEmpty, "journal entries must mirror into a running capture")
    XCTAssertEqual(mirrored.last?.text, "Claude needs your permission")
    XCTAssertEqual(mirrored.last?.urgent, true)
  }

  func testCreateTabAddsTabAndSelectsIt() throws {
    let model = try makeModel()
    let originalId = model.tabs[0].id
    let newTab = try model.createTab()
    XCTAssertEqual(model.tabs.count, 2)
    XCTAssertTrue(newTab.isActive)
    XCTAssertFalse(model.tabs[0].isActive, "first tab should be deselected after createTab")
    XCTAssertEqual(model.tabs[0].id, originalId, "original tab id must not change")
  }

  func testNewTabInheritsActiveTabCwd() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    // The active tab's reported working directory — what the OSC 7 / metadata
    // sync writes into `workspace.cwd`. Use a real existing directory so the
    // inherited cwd passes createTab's existence check.
    let dir = canonicalPath(FileManager.default.temporaryDirectory.path)
    model.applyProcessMetadata(
      processMetadata(pid: 4242, process: "zsh", command: "/bin/zsh", cwd: dir),
      forTab: tabId)

    var capturedCwd: String?
    model.newTabSessionFactory = { size, cwd in
      capturedCwd = cwd
      return try Session.fixture(size: size)
    }
    _ = try model.createTab()
    XCTAssertEqual(
      capturedCwd.map(canonicalPath), dir,
      "a new tab must spawn in the active tab's reported cwd")
  }

  func testNewTabFallsBackToDefaultFactoryWhenNoCwdKnown() throws {
    let model = try makeModel()
    // No OSC 7 and a fixture has no process cwd, so nothing is inherited: the
    // cwd-aware factory must NOT be used (preserving the prior spawn behavior).
    var capturedCwd: String?
    model.newTabSessionFactory = { size, cwd in
      capturedCwd = cwd
      return try Session.fixture(size: size)
    }
    _ = try model.createTab()
    XCTAssertNil(
      capturedCwd,
      "with no known cwd, createTab must fall back to the default sessionFactory")
    XCTAssertEqual(model.tabs.count, 2, "the tab is still created via the fallback")
  }

  func testSelectTabChangesActiveTab() throws {
    let model = try makeModel()
    try model.createTab()
    let firstId = model.tabs[0].id
    model.selectTab(firstId)
    XCTAssertTrue(model.tabs[0].isActive)
    XCTAssertFalse(model.tabs[1].isActive)
  }

  func testSelectTabWithStaleIdKeepsExistingActiveTab() throws {
    let model = try makeModel()
    let firstId = model.tabs[0].id
    let second = try model.createTab()

    XCTAssertEqual(model.activeTab?.id, second.id)
    model.selectTab("missing-\(UUID().uuidString)")

    XCTAssertEqual(model.activeTab?.id, second.id)
    XCTAssertFalse(model.tabs.first { $0.id == firstId }?.isActive ?? true)
    XCTAssertEqual(model.tabs.filter { $0.isActive }.count, 1)
  }

  func testHiddenSessionIdentitySurvivesSelection() throws {
    let model = try makeModel()
    let firstTabId = model.tabs[0].id
    let firstSessionId = model.tabs[0].sessionId
    try model.createTab()
    // Switch back to first tab
    model.selectTab(firstTabId)
    XCTAssertEqual(
      model.tabs[0].sessionId, firstSessionId,
      "session id must not change across selection")
    let session = model.session(forTab: firstTabId)
    XCTAssertNotNil(session)
    XCTAssertFalse(session!.isClosed)
  }

  func testCloseTabRemovesTabAndDestroysSession() throws {
    let model = try makeModel()
    try model.createTab()
    let secondTabId = model.tabs[1].id
    let secondSessionId = model.tabs[1].sessionId
    // Grab session reference before close
    let sessionRef = model.session(forTab: secondTabId)!
    try model.closeTab(secondTabId)
    XCTAssertEqual(model.tabs.count, 1)
    XCTAssertTrue(sessionRef.isClosed, "session must be closed when tab is removed")
    XCTAssertNil(model.session(forTab: secondTabId))
    _ = secondSessionId  // used above
  }

  func testFinalTabClosedThrows() throws {
    let model = try makeModel()
    let originalTabId = model.tabs[0].id
    let originalSessionRef = model.session(forTab: originalTabId)!
    XCTAssertThrowsError(try model.closeTab(originalTabId)) { error in
      XCTAssertEqual(error as? AppError, AppError.lastTabClosed)
    }
    XCTAssertTrue(model.tabs.isEmpty, "tabs cleared after last close")
    XCTAssertTrue(originalSessionRef.isClosed, "original session must be destroyed")
  }

  func testMoveTabForwardPreservesIdentityAndRenumbers() throws {
    let model = try makeModel()
    try model.createTab()
    try model.createTab()
    let ids = model.tabs.map(\.id)
    let mutations = WorkspaceMutationCounter(model: model)

    let moved = try model.moveTab(ids[0], to: 2)

    XCTAssertTrue(moved)
    XCTAssertEqual(model.tabs.map(\.id), [ids[1], ids[2], ids[0]])
    XCTAssertEqual(model.tabs.map(\.position), [1, 2, 3])
    XCTAssertEqual(model.activeTab?.id, ids[2], "active tab survives reorder")
    XCTAssertEqual(mutations.count, 1)
  }

  func testMoveTabBackwardPreservesIdentityAndRenumbers() throws {
    let model = try makeModel()
    try model.createTab()
    try model.createTab()
    let ids = model.tabs.map(\.id)

    let moved = try model.moveTab(ids[2], to: 0)

    XCTAssertTrue(moved)
    XCTAssertEqual(model.tabs.map(\.id), [ids[2], ids[0], ids[1]])
    XCTAssertEqual(model.tabs.map(\.position), [1, 2, 3])
    XCTAssertEqual(model.activeTab?.id, ids[2])
  }

  func testMoveTabSameIndexIsNoOp() throws {
    let model = try makeModel()
    try model.createTab()
    let ids = model.tabs.map(\.id)
    let mutations = WorkspaceMutationCounter(model: model)

    let moved = try model.moveTab(ids[1], to: 1)

    XCTAssertFalse(moved)
    XCTAssertEqual(model.tabs.map(\.id), ids)
    XCTAssertEqual(mutations.count, 0, "no workspace mutation when order is unchanged")
  }

  func testMoveTabClampsOutOfRangeIndex() throws {
    let model = try makeModel()
    try model.createTab()
    try model.createTab()
    let ids = model.tabs.map(\.id)

    // Way past the end → clamped to last index.
    let movedHigh = try model.moveTab(ids[0], to: 99)
    XCTAssertTrue(movedHigh)
    XCTAssertEqual(model.tabs.map(\.id), [ids[1], ids[2], ids[0]])

    // Negative → clamped to 0.
    let movedLow = try model.moveTab(ids[0], to: -5)
    XCTAssertTrue(movedLow)
    XCTAssertEqual(model.tabs.map(\.id), [ids[0], ids[1], ids[2]])
  }

  func testMoveTabUnknownIdThrows() throws {
    let model = try makeModel()
    try model.createTab()
    XCTAssertThrowsError(try model.moveTab("missing-\(UUID().uuidString)", to: 0)) { error in
      XCTAssertEqual(error as? AppError, AppError.tabNotFound)
    }
  }

  func testMoveTabIsReflectedInPersistenceSnapshot() throws {
    let model = try makeModel()
    try model.createTab()
    try model.createTab()
    let ids = model.tabs.map(\.id)

    _ = try model.moveTab(ids[0], to: 2)

    let snapshot = model.snapshotForPersistence(windowId: "window-1")
    XCTAssertEqual(
      snapshot.windows.first?.tabs.map(\.id),
      [ids[1], ids[2], ids[0]],
      "snapshot order must match the in-memory tab order after reorder"
    )
    XCTAssertEqual(snapshot.windows.first?.selectedTabId, ids[2])
  }

  func testCloseAllSessionsClosesEverySessionAndClearsTabs() throws {
    let model = try makeModel()
    try model.createTab()
    let sessions = model.tabs.compactMap { model.session(forTab: $0.id) }

    model.closeAllSessions()

    XCTAssertTrue(model.tabs.isEmpty)
    XCTAssertEqual(sessions.count, 2)
    for session in sessions {
      XCTAssertTrue(session.isClosed)
      XCTAssertEqual(session.poll(), -1)
    }

    model.closeAllSessions()
  }

  func testCanCreateMoreThanNineTabs() throws {
    let model = try makeModel()
    for _ in 2...12 {
      try model.createTab()
    }
    XCTAssertEqual(model.tabs.count, 12)
    XCTAssertEqual(model.tabs.map(\.position), Array(1...12))
  }

  func testTitleUpdatePreservesIdentity() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let sessionId = model.tabs[0].sessionId
    try model.updateTitle("zsh", forTab: tabId)
    XCTAssertEqual(model.tabs[0].title, "zsh")
    XCTAssertEqual(model.tabs[0].titleMetadata.terminalTitle, "zsh")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .terminal)
    XCTAssertEqual(model.tabs[0].id, tabId, "tab id unchanged after title update")
    XCTAssertEqual(model.tabs[0].sessionId, sessionId, "session id unchanged after title update")
  }

  func testSyncTitleAgainstUnknownTabDoesNotConsumeThePendingTitle() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let session = try XCTUnwrap(model.session(forTab: tabId))
    XCTAssertEqual(session.feedOutput(Array("\u{1B}]0;vim README.md\u{07}".utf8)), 0)

    // A sync routed at a tab that is not in the array (mid-rebuild window)
    // must not clear the C-side dirty flag, or the title is dropped forever.
    XCTAssertFalse(model.syncTitle(forTab: "no-such-tab", from: session))

    XCTAssertTrue(model.syncTitle(forTab: tabId, from: session))
    XCTAssertEqual(model.tabs[0].titleMetadata.terminalTitle, "vim README.md")
  }

  func testResizeAppliesToBackgroundSessions() throws {
    let model = try makeModel(rows: 24, cols: 80)
    try model.createTab()
    // Select first tab so second is background
    model.selectTab(model.tabs[0].id)
    model.resize(viewportWidth: 800, viewportHeight: 600, cellWidth: 10, cellHeight: 20)
    // Both sessions must still be alive and accept a snapshot with updated dims
    for tab in model.tabs {
      guard let session = model.session(forTab: tab.id) else {
        XCTFail("session missing for tab \(tab.id)")
        continue
      }
      XCTAssertFalse(session.isClosed)
      let snap = session.snapshot()
      defer { laban_snapshot_destroy(snap) }
      XCTAssertNotNil(snap, "snapshot must be non-nil after resize")
      XCTAssertEqual(snap!.pointee.rows, 30, "rows = 600/20")
      XCTAssertEqual(snap!.pointee.cols, 80, "cols = 800/10")
    }
  }

  func testResizePropagatesPixelAndCellMetricsToTerminalSizeReports() throws {
    let sink = AppModelCaptureSink()
    let model = try makeModel(rows: 24, cols: 80)
    model.captureSink = sink

    model.resize(viewportWidth: 900, viewportHeight: 540, cellWidth: 9, cellHeight: 18)

    guard let session = model.session(forTab: model.tabs[0].id) else {
      XCTFail("session missing for active tab")
      return
    }
    sink.byteEvents.removeAll()
    XCTAssertEqual(session.write(Array("\u{1B}[14t\u{1B}[16t\u{1B}[18t".utf8)), 0)

    let responseBytes = sink.byteEvents
      .filter { $0.direction == .terminalResponse }
      .flatMap { $0.bytes }
    let response = String(bytes: responseBytes, encoding: .utf8) ?? ""

    XCTAssertTrue(
      response.contains("\u{1B}[4;540;900t"),
      "text-area pixel size reply missing from \(response.debugDescription)")
    XCTAssertTrue(
      response.contains("\u{1B}[6;18;9t"),
      "cell pixel size reply missing from \(response.debugDescription)")
    XCTAssertTrue(
      response.contains("\u{1B}[8;30;100t"),
      "character size reply missing from \(response.debugDescription)")
  }

  func testStaleSessionHandlesNotUsedAfterClose() throws {
    let model = try makeModel()
    try model.createTab()
    let firstTabId = model.tabs[0].id
    let sessionRef = model.session(forTab: firstTabId)!
    try model.closeTab(firstTabId)
    XCTAssertTrue(sessionRef.isClosed)
    // All guarded methods must return sentinel values, not crash
    XCTAssertEqual(sessionRef.poll(), -1)
    XCTAssertEqual(sessionRef.write([0x41]), -1)
    var s = LabanTerminalSize()
    s.rows = 10
    s.cols = 10
    XCTAssertEqual(sessionRef.resize(s), -1)
    XCTAssertNil(sessionRef.snapshot())
  }

  func testPositionsAfterCloseMiddleTab() throws {
    let model = try makeModel()
    try model.createTab()
    try model.createTab()
    XCTAssertEqual(model.tabs.count, 3)
    let middleId = model.tabs[1].id
    try model.closeTab(middleId)
    XCTAssertEqual(model.tabs.count, 2)
    XCTAssertEqual(model.tabs[0].position, 1)
    XCTAssertEqual(model.tabs[1].position, 2)
  }

  func testTabStatusDefaultsToRunning() throws {
    let model = try makeModel()
    XCTAssertEqual(model.tabs[0].status, .running)
  }

  func testTabStatusCallbackCanArriveFromBackgroundQueue() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("session not found")
      return
    }

    let delivered = expectation(description: "background tab status delivered")
    DispatchQueue.global(qos: .userInitiated).async {
      _ = session.feedOutput(Array("\u{1B}]21337;status=background\u{07}".utf8))
      delivered.fulfill()
    }
    wait(for: [delivered], timeout: 1)

    // AppModel.attachTabStatus now defers the model mutation onto the main queue
    // (to avoid a lock-order inversion against modelLock when the OSC bytes are
    // parsed by the off-main reader thread). Pump the main queue once so the
    // deferred apply runs before we read the metadata back. FIFO ordering on the
    // main queue guarantees the apply ran before this trailing dispatch.
    let mainPump = expectation(description: "main queue pumped")
    DispatchQueue.main.async { mainPump.fulfill() }
    wait(for: [mainPump], timeout: 1)

    XCTAssertEqual(model.tabs[0].titleMetadata.agentStatus.statusText, "background")
  }

  func testSurfaceSignalsCanMarkTransportDegradation() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    let changed = model.applySurfaceSignals(
      TabSurfaceSignals(
        agentStatus: TabAgentStatus(
          indicatorColor: "#f59e0b",
          statusText: "output skipped",
          statusTextColor: "#f59e0b")),
      forTab: tabId)

    XCTAssertTrue(changed)
    XCTAssertEqual(model.tabs[0].titleMetadata.agentStatus.indicatorColor, "#f59e0b")
    XCTAssertEqual(model.tabs[0].titleMetadata.agentStatus.statusText, "output skipped")
    XCTAssertEqual(model.tabs[0].titleMetadata.agentStatus.statusTextColor, "#f59e0b")
  }

  func testClearAgentStatusOnlyRemovesTheMatchingBadge() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let degraded = TabAgentStatus(
      indicatorColor: "#f59e0b",
      statusText: "output skipped",
      statusTextColor: "#f59e0b")

    _ = model.applySurfaceSignals(TabSurfaceSignals(agentStatus: degraded), forTab: tabId)
    XCTAssertEqual(model.tabs[0].titleMetadata.agentStatus.statusText, "output skipped")

    // A non-matching expected value must not clear it: this is what protects an
    // OSC 21337 status that shares titleMetadata.agentStatus from being wiped.
    XCTAssertFalse(
      model.clearAgentStatus(
        forTab: tabId, ifEquals: TabAgentStatus(statusText: "background")))
    XCTAssertEqual(model.tabs[0].titleMetadata.agentStatus.statusText, "output skipped")

    // The exact degraded badge clears back to empty.
    XCTAssertTrue(model.clearAgentStatus(forTab: tabId, ifEquals: degraded))
    XCTAssertTrue(model.tabs[0].titleMetadata.agentStatus.isEmpty)
  }

  func testActiveBellDoesNotSetAttention() throws {
    let model = try makeModel()
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    XCTAssertEqual(session.feedOutput([0x07]), 0)
    pumpMainQueue()

    XCTAssertFalse(model.tabs[0].titleMetadata.bellAttention)
  }

  func testInactiveBellSetsAttentionAndSelectionClearsIt() throws {
    let model = try makeModel()
    let firstTab = try XCTUnwrap(model.activeTab)
    let secondTab = try model.createTab()
    model.selectTab(firstTab.id)
    let secondSession = try XCTUnwrap(model.session(forTab: secondTab.id))

    XCTAssertEqual(secondSession.feedOutput([0x07]), 0)
    pumpMainQueue()

    var updatedSecond = try XCTUnwrap(model.tabs.first { $0.id == secondTab.id })
    XCTAssertFalse(updatedSecond.isActive)
    XCTAssertTrue(updatedSecond.titleMetadata.bellAttention)
    XCTAssertEqual(
      TabTitleResolver.resolve(
        updatedSecond.titleMetadata,
        fallbackPosition: updatedSecond.position
      ).statusBadge,
      "•")

    model.selectTab(secondTab.id)

    updatedSecond = try XCTUnwrap(model.tabs.first { $0.id == secondTab.id })
    XCTAssertTrue(updatedSecond.isActive)
    XCTAssertFalse(updatedSecond.titleMetadata.bellAttention)
  }

  func testSyncExitStateIsMonotonic() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("session not found")
      return
    }
    model.forceExitState(forTab: tabId, status: .exited(code: 0))
    XCTAssertEqual(model.tabs[0].status, .exited(code: 0))
    XCTAssertEqual(model.tabs[0].titleMetadata.activityState, .exited)
    XCTAssertEqual(model.tabs[0].titleMetadata.exitStatus, 0)
    let changed = model.syncExitState(forTab: tabId, from: session)
    XCTAssertFalse(changed, "syncExitState must be no-op once tab is already exited")
    XCTAssertEqual(model.tabs[0].status, .exited(code: 0))
  }

  func testTerminalTitleOwnedByForegroundProcessBeatsVersionedProcessName() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1001,
        process: "2.1.126",
        command: "/opt/homebrew/bin/2.1.126",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    XCTAssertEqual(model.tabs[0].title, "* Claude Code")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .terminal)
    XCTAssertEqual(model.tabs[0].titleMetadata.terminalTitle, "* Claude Code")
  }

  func testProcessIdentityChangeClearsTitleOnceOwnerIsGone() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    model.setTitleOwnerLivenessProbeForTesting { _ in false }

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1001,
        process: "2.1.126",
        command: "/opt/homebrew/bin/2.1.126",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    XCTAssertTrue(
      model.applyProcessMetadata(
        processMetadata(
          pid: 1002,
          process: "top",
          command: "/usr/bin/top",
          cwd: NSHomeDirectory()
        ),
        forTab: tabId
      ))

    XCTAssertNil(model.tabs[0].titleMetadata.terminalTitle)
    XCTAssertEqual(model.tabs[0].title, "top")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .process)
  }

  func testProcessIdentityChangeKeepsTitleWhileOwnerIsAlive() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    model.setTitleOwnerLivenessProbeForTesting { _ in true }

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1001,
        process: "2.1.126",
        command: "/opt/homebrew/bin/2.1.126",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    // An agent runs tool subprocesses that flutter the foreground identity
    // while the agent itself keeps running; its title must survive that.
    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1002,
        process: "git",
        command: "/usr/bin/git",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )

    XCTAssertEqual(model.tabs[0].titleMetadata.terminalTitle, "* Claude Code")
    XCTAssertEqual(model.tabs[0].title, "* Claude Code")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .terminal)
  }

  func testShellProcessIdentityChangeFallsBackToHomeCwd() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    model.setTitleOwnerLivenessProbeForTesting { _ in false }

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1001,
        process: "2.1.126",
        command: "/opt/homebrew/bin/2.1.126",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1002,
        process: "zsh",
        command: "/bin/zsh",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )

    XCTAssertNil(model.tabs[0].titleMetadata.terminalTitle)
    XCTAssertEqual(model.tabs[0].title, "~")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .cwd)
  }

  func testManualTitleSurvivesProcessAndTerminalChanges() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(pid: 1001, process: "2.1.126", command: "/opt/homebrew/bin/2.1.126"),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)
    try model.renameTab(tabId, title: "manual")
    _ = model.applyProcessMetadata(
      processMetadata(pid: 1002, process: "top", command: "/usr/bin/top"),
      forTab: tabId
    )
    try model.updateTerminalTitle("top", forTab: tabId)

    XCTAssertEqual(model.tabs[0].title, "manual")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .user)
  }

  func testFrozenTitleSurvivesProcessAndTerminalChanges() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(pid: 1001, process: "zsh", command: "/bin/zsh", cwd: NSHomeDirectory()),
      forTab: tabId
    )
    try model.updateTerminalTitle("zsh", forTab: tabId)
    try model.freezeTitle(forTab: tabId)
    _ = model.applyProcessMetadata(
      processMetadata(pid: 1002, process: "2.1.126", command: "/opt/homebrew/bin/2.1.126"),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    // The freeze captured the displayed title at freeze time — the terminal
    // title "zsh" under live-title precedence — and must survive both the
    // process change and the newer terminal title.
    XCTAssertEqual(model.tabs[0].title, "zsh")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .user)
  }

  func testSyncProcessMetadataUsesForegroundProcessForTitle() throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-app-process-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let tempPath = canonicalPath(tempURL.path)

    let exe = "/bin/sleep"
    let argStrings = ["/bin/sleep", "2"]
    try exe.withCString { exeCStr in
      try tempPath.withCString { cwdCStr in
        try withCArgv(argStrings) { argvPtr in
          var config = LabanLaunchConfig()
          config.executable = exeCStr
          config.argv = argvPtr
          config.cwd = cwdCStr
          config.fixture_mode = 0

          var size = LabanTerminalSize()
          size.rows = 24
          size.cols = 80

          let model = try AppModel(
            initialSize: size,
            sessionFactory: { sz in try Session(config: &config, size: sz) }
          )
          let tabId = model.tabs[0].id
          guard let session = model.session(forTab: tabId) else {
            XCTFail("session not found")
            return
          }

          let deadline = Date().addingTimeInterval(2.0)
          var changed = false
          while Date() < deadline {
            session.poll()
            changed = model.syncProcessMetadata(forTab: tabId, from: session) || changed
            if model.tabs[0].titleMetadata.process.foregroundProcess == "sleep" {
              break
            }
            Thread.sleep(forTimeInterval: 0.01)
          }

          XCTAssertTrue(changed)
          XCTAssertEqual(model.tabs[0].titleMetadata.process.foregroundProcess, "sleep")
          XCTAssertEqual(model.tabs[0].titleMetadata.workspace.cwd, tempPath)
          XCTAssertEqual(model.tabs[0].title, "sleep")
          XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .process)
          let snapshot = model.snapshotForPersistence(windowId: "win")
          XCTAssertEqual(
            snapshot.windows.first?.tabs.first?.shellPid,
            session.processMetadata()?.childPid)
        }
      }
    }
  }

  private func withCArgv(
    _ strings: [String],
    body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> Void
  ) rethrows {
    var mptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    mptrs.append(nil)
    defer { for p in mptrs { if let p { free(p) } } }
    let count = mptrs.count
    try mptrs.withUnsafeMutableBufferPointer { mbuf in
      try mbuf.baseAddress!.withMemoryRebound(
        to: UnsafePointer<CChar>?.self, capacity: count
      ) { rebound in
        try body(UnsafePointer(rebound))
      }
    }
  }

  func testAppModelRecordsExitStateFromRealPTY() {
    let exe = "/bin/sh"
    let argStrings = ["/bin/sh", "-c", "exit 7"]
    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        var config = LabanLaunchConfig()
        config.executable = exeCStr
        config.argv = argvPtr
        config.fixture_mode = 0

        var size = LabanTerminalSize()
        size.rows = 24
        size.cols = 80

        let model: AppModel
        do {
          model = try AppModel(
            initialSize: size,
            sessionFactory: { sz in try Session(config: &config, size: sz) }
          )
        } catch {
          XCTFail("AppModel init failed: \(error)")
          return
        }

        let tabId = model.tabs[0].id
        guard let session = model.session(forTab: tabId) else {
          XCTFail("session not found")
          return
        }

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
          session.poll()
          if model.syncExitState(forTab: tabId, from: session) { break }
          Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertNotEqual(model.tabs[0].status, .running)
        if case .exited(let code) = model.tabs[0].status {
          XCTAssertEqual(code, 7)
        } else {
          XCTFail("expected .exited(code:) but got \(model.tabs[0].status)")
        }
      }
    }
  }
}

private final class AppModelCaptureSink: CaptureSink {
  struct ByteEvent {
    var direction: CaptureByteDirection
    var sessionId: Session.ID?
    var frame: Int
    var bytes: [UInt8]
  }

  var sequence = 0
  var events: [CaptureTimelineEvent] = []
  var byteEvents: [ByteEvent] = []

  func nextSequence() -> Int {
    defer { sequence += 1 }
    return sequence
  }

  func record(_ event: CaptureTimelineEvent) {
    events.append(event)
  }

  func recordBytes(
    direction: CaptureByteDirection,
    sessionId: Session.ID?,
    frame: Int,
    bytes: UnsafeRawBufferPointer,
    preview: String?
  ) -> CaptureByteRef? {
    let array = bytes.bindMemory(to: UInt8.self).map { $0 }
    byteEvents.append(
      ByteEvent(direction: direction, sessionId: sessionId, frame: frame, bytes: array))
    return CaptureByteRef(
      stream: direction.rawValue,
      path: "streams/\(direction.streamFileName)",
      offset: 0,
      length: array.count,
      sha256: ""
    )
  }
}
