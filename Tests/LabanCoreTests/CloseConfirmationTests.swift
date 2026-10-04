import LabanTerminalCore
import XCTest

@testable import LabanCore

private func fixtureFactory(_ size: LabanTerminalSize) throws -> Session {
  try Session.fixture(size: size)
}

private func makeModel() throws -> AppModel {
  var size = LabanTerminalSize()
  size.rows = 4
  size.cols = 20
  return try AppModel(initialSize: size, sessionFactory: fixtureFactory)
}

private func pumpMainQueue(timeout: TimeInterval = 1.0) {
  let pumped = XCTestExpectation(description: "main queue pumped")
  DispatchQueue.main.async { pumped.fulfill() }
  XCTWaiter().wait(for: [pumped], timeout: timeout)
}

/// The foreground process is pid 42; the pane's own shell is `shellPid`
/// (42 by default, i.e. the shell itself is in the foreground).
private func input(
  _ arguments: [String]?, shellPid: Int32? = 42, exited: Bool = false, progress: Bool = false,
  agentNamed: Bool = false
) -> PaneCloseInput {
  PaneCloseInput(
    sessionId: "s", tabId: "t", tabTitle: "~/src", exited: exited, shellPid: shellPid,
    foreground: arguments.map { ForegroundProcess(pid: 42, arguments: $0) },
    progressActive: progress, agentNamed: agentNamed)
}

private let safeList = CloseConfirmationSettings.defaultSafeList

final class CloseConfirmationTests: XCTestCase {
  func testShellAtPromptIsIdle() {
    let verdict = CloseConfirmation.evaluate(input(["-zsh"]), safeList: safeList)
    XCTAssertFalse(verdict.busy)
    XCTAssertEqual(verdict.signal, .safeList)
    XCTAssertEqual(verdict.program, "zsh", "a login shell's leading dash is not part of its name")
  }

  func testShellScriptIsBusy() {
    let verdict = CloseConfirmation.evaluate(
      input(["/bin/bash", "./deploy.sh"], shellPid: 7), safeList: safeList)
    XCTAssertTrue(verdict.busy, "a script runs under a shell that is not the pane's own")
    XCTAssertEqual(verdict.program, "deploy.sh")
  }

  func testInlineShellAndSubshellAreBusy() {
    let inline = CloseConfirmation.evaluate(
      input(["sh", "-c", "make"], shellPid: 7), safeList: safeList)
    XCTAssertTrue(inline.busy)
    XCTAssertEqual(inline.program, "sh")
    XCTAssertTrue(CloseConfirmation.evaluate(input(["zsh"], shellPid: 7), safeList: safeList).busy)
  }

  func testUnknownShellPidFallsBackToName() {
    XCTAssertFalse(CloseConfirmation.evaluate(input(["zsh"], shellPid: nil), safeList: safeList).busy)
  }

  func testMultiplexerIsIdle() {
    XCTAssertFalse(CloseConfirmation.evaluate(input(["tmux", "attach"]), safeList: safeList).busy)
  }

  func testOtherProgramIsBusy() {
    let verdict = CloseConfirmation.evaluate(input(["/usr/bin/vim", "notes.md"]), safeList: safeList)
    XCTAssertTrue(verdict.busy)
    XCTAssertEqual(verdict.signal, .foregroundProcess)
    XCTAssertEqual(verdict.program, "vim")
    XCTAssertNil(verdict.agentState)
  }

  /// A tab launched straight into ssh has ssh as its session leader; the
  /// leader is not a shell, so it still asks.
  func testSSHIsBusy() {
    XCTAssertTrue(CloseConfirmation.evaluate(input(["ssh", "host"]), safeList: safeList).busy)
  }

  func testEditedSafeListIsHonored() {
    XCTAssertFalse(CloseConfirmation.evaluate(input(["ssh", "host"]), safeList: ["ssh"]).busy)
    XCTAssertTrue(CloseConfirmation.evaluate(input(["zsh"]), safeList: []).busy)
  }

  func testExitedPaneIsIdle() {
    let verdict = CloseConfirmation.evaluate(input(["vim"], exited: true), safeList: safeList)
    XCTAssertFalse(verdict.busy)
    XCTAssertEqual(verdict.signal, .exited)
  }

  func testUninspectablePaneIsIdle() {
    let verdict = CloseConfirmation.evaluate(input(nil), safeList: safeList)
    XCTAssertFalse(verdict.busy)
    XCTAssertEqual(verdict.signal, .noProcessInfo)
  }

  func testClaudeCodeWorkingAndWaiting() {
    // The native install runs a version-named binary with argv[0] "claude".
    let working = CloseConfirmation.evaluate(input(["claude"], progress: true), safeList: safeList)
    XCTAssertEqual(working.program, "Claude Code")
    XCTAssertEqual(working.agentState, .working)
    // An npm install runs under node.
    let waiting = CloseConfirmation.evaluate(
      input(["node", "/opt/homebrew/bin/claude"]), safeList: safeList)
    XCTAssertTrue(waiting.busy)
    XCTAssertEqual(waiting.program, "Claude Code")
    XCTAssertEqual(waiting.agentState, .waiting)
  }

  func testAgentNamedByMetadataGetsAgentState() {
    let verdict = CloseConfirmation.evaluate(
      input(["python3", "agent.py"], progress: true, agentNamed: true), safeList: safeList)
    XCTAssertEqual(verdict.program, "python3")
    XCTAssertEqual(verdict.agentState, .working)
  }

  // MARK: - Dialog

  private func busy(_ program: String, _ tab: String, working: Bool = false) -> PaneCloseVerdict {
    PaneCloseVerdict(
      sessionId: program, tabId: tab, tabTitle: tab, busy: true, signal: .foregroundProcess,
      program: program, agentState: working ? .working : nil)
  }

  private let idle = PaneCloseVerdict(
    sessionId: "i", tabId: "t", tabTitle: "~", busy: false, signal: .safeList, program: "zsh")

  func testNoDialogWhenNothingRuns() {
    XCTAssertNil(CloseConfirmation.dialog(scope: .tab, verdicts: [idle], mode: .whenRunning))
  }

  func testNeverModeNeverAsks() {
    XCTAssertNil(
      CloseConfirmation.dialog(scope: .tab, verdicts: [busy("vim", "a")], mode: .never))
  }

  func testAlwaysModeAsksForIdlePane() throws {
    let dialog = try XCTUnwrap(
      CloseConfirmation.dialog(scope: .pane, verdicts: [idle], mode: .always))
    XCTAssertEqual(dialog.messageText, "Close this pane?")
    XCTAssertEqual(dialog.informativeText, "The terminal session will end.")
    XCTAssertEqual(dialog.confirmButtonTitle, "Close Pane")
    XCTAssertTrue(dialog.busyPanes.isEmpty)
  }

  func testSingleProgramNamesIt() throws {
    let dialog = try XCTUnwrap(
      CloseConfirmation.dialog(scope: .tab, verdicts: [idle, busy("vim", "a")], mode: .whenRunning)
    )
    XCTAssertEqual(dialog.messageText, "Close this tab?")
    XCTAssertEqual(dialog.informativeText, "vim is running and will be ended.")
    XCTAssertEqual(dialog.busyPanes.map(\.program), ["vim"])
  }

  func testWorkingAgentSaysItWillBeInterrupted() throws {
    let dialog = try XCTUnwrap(
      CloseConfirmation.dialog(
        scope: .pane, verdicts: [busy("Claude Code", "a", working: true)], mode: .whenRunning))
    XCTAssertEqual(dialog.informativeText, "Claude Code is working and will be interrupted.")
  }

  func testSeveralProgramsAreListedOnce() throws {
    let dialog = try XCTUnwrap(
      CloseConfirmation.dialog(
        scope: .quit,
        verdicts: [busy("vim", "notes"), idle, busy("Claude Code", "laban", working: true)],
        mode: .whenRunning))
    XCTAssertEqual(dialog.messageText, "Quit Laban?")
    XCTAssertEqual(dialog.confirmButtonTitle, "Quit")
    XCTAssertEqual(
      dialog.informativeText,
      "These programs will be ended:\n• vim in “notes”\n• Claude Code (working) in “laban”")
  }

  func testDialogTextGoesThroughLocalizer() throws {
    let dialog = try XCTUnwrap(
      CloseConfirmation.dialog(
        scope: .tab, verdicts: [busy("vim", "a")], mode: .whenRunning,
        localize: { $0 == "%@ is running and will be ended." ? "[%@]" : "<\($0)>" }))
    XCTAssertEqual(dialog.messageText, "<Close this tab?>")
    XCTAssertEqual(dialog.informativeText, "[vim]")
    XCTAssertEqual(dialog.confirmButtonTitle, "<Close Tab>")
  }

  // MARK: - Settings

  func testSettingsDefaultsAndRoundTrip() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "CloseConfirmationTests.\(UUID())"))
    XCTAssertEqual(CloseConfirmationSettings.mode(defaults: defaults), .whenRunning)
    XCTAssertEqual(CloseConfirmationSettings.safeList(defaults: defaults), safeList)
    CloseConfirmationSettings.setMode(.always, defaults: defaults)
    CloseConfirmationSettings.setSafeList([" ssh ", "", "zsh", "ssh"], defaults: defaults)
    XCTAssertEqual(CloseConfirmationSettings.mode(defaults: defaults), .always)
    XCTAssertEqual(CloseConfirmationSettings.safeList(defaults: defaults), ["ssh", "zsh"])
  }

  // MARK: - Model integration

  func testVerdictsReadPaneProgressFromTheModel() throws {
    let model = try makeModel()
    let tab = model.tabs[0]
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    session.feedOutput(Array("\u{1b}]9;4;3\u{07}".utf8))
    pumpMainQueue()
    let verdicts = CloseConfirmation.verdicts(
      for: tab.allSessionIds, model: model, safeList: safeList,
      shellPid: { _ in 7 }, probe: { _ in ForegroundProcess(pid: 9, arguments: ["claude"]) })
    XCTAssertEqual(verdicts.count, 1)
    XCTAssertEqual(verdicts.first?.tabId, tab.id)
    XCTAssertEqual(verdicts.first?.agentState, .working)
    XCTAssertEqual(verdicts.first?.foregroundPid, 9)
  }

  func testFixtureSessionHasNoProcessToInspect() throws {
    let model = try makeModel()
    let id = model.tabs[0].focusedSessionId
    XCTAssertNil(CloseConfirmation.shellPid(for: id, model: model))
    let verdicts = CloseConfirmation.verdicts(
      for: [id], model: model, safeList: safeList,
      shellPid: { CloseConfirmation.shellPid(for: $0, model: model) })
    XCTAssertEqual(verdicts.first?.signal, .noProcessInfo)
  }

  // MARK: - Foreground probe against a real pty

  func testProbeSeesShellThenForegroundJob() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.debugShell(size: size)
    defer { session.close() }
    let shellPid = try XCTUnwrap(session.processMetadata()?.childPid).map(Int32.init)
    let pid = try XCTUnwrap(shellPid)

    // Until the forked child execs, it still carries the test runner's name.
    let shells: Set<String> = ["sh", "bash", "dash"]
    let atPrompt = try XCTUnwrap(
      waitForProbe(pid) { shells.contains($0.name) }, "the shell never reached its prompt")
    XCTAssertEqual(atPrompt.pid, pid, "the shell owns the foreground at its prompt")
    XCTAssertFalse(
      CloseConfirmation.evaluate(
        PaneCloseInput(sessionId: "s", tabId: "t", tabTitle: "t", foreground: atPrompt),
        safeList: safeList
      ).busy, "\(atPrompt.name) at its prompt must be idle")

    _ = session.write(Array("sleep 30\r".utf8))
    let job = try XCTUnwrap(waitForProbe(pid) { $0.name == "sleep" }, "sleep never took the foreground")
    XCTAssertNotEqual(job.pid, pid)
    XCTAssertTrue(
      CloseConfirmation.evaluate(
        PaneCloseInput(sessionId: "s", tabId: "t", tabTitle: "t", shellPid: pid, foreground: job),
        safeList: safeList
      ).busy)
    kill(job.pid, SIGKILL)
  }

  /// A shell running a script is a safe-listed name in the foreground, but
  /// not the pane's own shell, so it must count as busy.
  func testProbeSeesScriptShellAsBusy() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.debugShell(size: size)
    defer { session.close() }
    let pid = try XCTUnwrap(session.processMetadata()?.childPid.map(Int32.init))
    let shells: Set<String> = ["sh", "bash", "dash"]
    _ = try XCTUnwrap(waitForProbe(pid) { shells.contains($0.name) }, "shell never started")

    // `; :` keeps sh from exec-ing sleep, so the script shell stays the leader.
    _ = session.write(Array("sh -c 'sleep 30; :'\r".utf8))
    let job = try XCTUnwrap(
      waitForProbe(pid) { $0.pid != pid && $0.name == "sh" }, "script shell never took the foreground")
    let verdict = CloseConfirmation.evaluate(
      PaneCloseInput(sessionId: "s", tabId: "t", tabTitle: "t", shellPid: pid, foreground: job),
      safeList: safeList)
    XCTAssertTrue(verdict.busy)
    kill(-job.pid, SIGKILL)
  }

  private func waitForProbe(
    _ shellPid: Int32, timeout: TimeInterval = 5, until accept: (ForegroundProcess) -> Bool
  ) -> ForegroundProcess? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let process = ForegroundProcessProbe.foreground(ofShell: shellPid), accept(process) {
        return process
      }
      usleep(20_000)
    }
    return nil
  }
}
