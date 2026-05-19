import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanCore

final class RestorePlannerTests: XCTestCase {

  private func tab(
    agent: AgentInfo?,
    status: PersistedProcessStatus? = .running,
    shellPid: Int? = nil
  ) -> TabState {
    TabState(
      id: "tab-1",
      cwd: "/tmp",
      launchCommand: "/bin/zsh -l",
      lastActiveAt: Date(),
      processStatus: status,
      shellPid: shellPid,
      agent: agent
    )
  }

  func testClaudeRunningAtQuitExecutesNow() {
    let state = tab(
      agent: AgentInfo(
        name: .claude,
        sessionId: "abc",
        jsonlPath: "/x.jsonl",
        wasRunningAtQuit: true))
    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .executeNow(command: "command claude --resume abc"))
  }

  func testCodexRunningAtQuitExecutesNow() {
    let state = tab(
      agent: AgentInfo(
        name: .codex,
        sessionId: "xyz",
        jsonlPath: "/y.jsonl",
        wasRunningAtQuit: true))
    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .executeNow(command: "codex resume xyz -C /tmp"))
  }

  func testClaudeDeadAtQuitPrefills() {
    let state = tab(
      agent: AgentInfo(
        name: .claude,
        sessionId: "abc",
        jsonlPath: "/x.jsonl",
        wasRunningAtQuit: false))
    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .prefillPrompt(command: "command claude --resume abc"))
  }

  func testCodexDeadAtQuitPrefills() {
    let state = tab(
      agent: AgentInfo(
        name: .codex,
        sessionId: "xyz",
        jsonlPath: "/y.jsonl",
        wasRunningAtQuit: false))
    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .prefillPrompt(command: "codex resume xyz -C /tmp"))
  }

  func testNoAgentMeansNoPrefill() {
    let state = tab(agent: nil)
    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .noPrefill)
  }

  func testPlannerIgnoresProcessStatusEvenWhenRunning() {
    // The planner MUST read agent.wasRunningAtQuit, never tab.processStatus.
    // A tab whose shell is running (processStatus == .running) but with
    // no captured agent must produce .noPrefill — not executeNow.
    let state = tab(agent: nil, status: .running)
    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state), .noPrefill)
  }

  func testPlannerDoesNotResumeGenericLaunchCommand() {
    let state = TabState(
      id: "tab-1",
      cwd: "/tmp",
      launchCommand: "echo hej",
      lastActiveAt: Date(),
      processStatus: .running,
      agent: nil
    )
    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .noPrefill,
      "launchCommand is metadata, not a generic terminal command resume path")
  }

  func testPlannerUsesAgentCwdAndFiltersClaudeArgv() {
    let state = tab(
      agent: AgentInfo(
        name: .claude,
        sessionId: "abc",
        jsonlPath: "/x.jsonl",
        wasRunningAtQuit: true,
        argv: ["claude", "--worktree", "new-tree", "--model", "sonnet"],
        env: ["TERM": "xterm-256color"],
        cwd: "/agent/cwd"))

    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .executeNow(command: "command claude --resume abc --model sonnet"))
  }

  func testPlannerBypassesClaudeShellFunctionAndNormalizesDuplicatedWrapperArgv() {
    let state = tab(
      agent: AgentInfo(
        name: .claude,
        sessionId: "abc",
        jsonlPath: "/x.jsonl",
        wasRunningAtQuit: true,
        argv: [
          "claude",
          "--chrome",
          "--resume",
          "old",
          "--chrome",
          "--chrome",
          "--dangerously-skip-permissions",
        ],
        cwd: "/agent/cwd"))

    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .executeNow(command: "command claude --resume abc --chrome --dangerously-skip-permissions"))
  }

  func testPlannerSkipsExecuteWhenSameAgentSessionIsAlreadyLive() {
    let state = tab(
      agent: AgentInfo(
        name: .claude,
        sessionId: "abc",
        jsonlPath: "/x.jsonl",
        wasRunningAtQuit: true),
      shellPid: 1234)

    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(
        for: state,
        activityChecker: FixedActivityChecker(isLive: true)),
      .noPrefill)
  }

  func testPlannerSkipsPrefillWhenSameAgentSessionIsAlreadyLive() {
    let state = tab(
      agent: AgentInfo(
        name: .codex,
        sessionId: "xyz",
        jsonlPath: "/y.jsonl",
        wasRunningAtQuit: false),
      shellPid: 1234)

    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(
        for: state,
        activityChecker: FixedActivityChecker(isLive: true)),
      .noPrefill)
  }

  func testPlannerStillResumesWhenPersistedSessionIsNotLive() {
    let state = tab(
      agent: AgentInfo(
        name: .claude,
        sessionId: "abc",
        jsonlPath: "/x.jsonl",
        wasRunningAtQuit: true),
      shellPid: 1234)

    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(
        for: state,
        activityChecker: FixedActivityChecker(isLive: false)),
      .executeNow(command: "command claude --resume abc"))
  }

  func testProcessTreeActivityCheckerMatchesSameLiveSessionUnderPersistedShellPid() {
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0101"
    let state = tab(
      agent: AgentInfo(
        name: .claude,
        sessionId: sessionId,
        jsonlPath: "/x.jsonl",
        wasRunningAtQuit: true),
      shellPid: 1234)
    let checker = ProcessTreeRestoreSessionActivityChecker(
      introspector: RestorePlannerMockIntrospector(
        children: [1234: [(1235, "claude")]],
        openVnodes: [
          1235: ["/Users/x/.claude/projects/p/\(sessionId).jsonl"]
        ]))

    XCTAssertTrue(checker.isAgentSessionLive(for: state))
  }

  func testPlannerUsesTabCwdFallbackForCodexAndPreservesResumeSafeArgv() {
    let state = tab(
      agent: AgentInfo(
        name: .codex,
        sessionId: "xyz",
        jsonlPath: "/y.jsonl",
        wasRunningAtQuit: true,
        argv: [
          "codex",
          "--dangerously-bypass-approvals-and-sandbox",
          "--model",
          "gpt-5.2",
        ]))

    XCTAssertEqual(
      RestoreLaunchPlanner.instruction(for: state),
      .executeNow(
        command:
          "codex resume xyz -C /tmp --dangerously-bypass-approvals-and-sandbox --model gpt-5.2")
    )
  }
}

private struct FixedActivityChecker: RestoreSessionActivityChecking {
  var isLive: Bool

  func isAgentSessionLive(for tab: TabState) -> Bool {
    isLive
  }
}

private struct RestorePlannerMockIntrospector: ProcessIntrospector {
  var children: [pid_t: [(pid_t, String)]]
  var openVnodes: [pid_t: [String]]

  func children(of parent: pid_t) -> [(pid: pid_t, basename: String)] {
    (children[parent] ?? []).map { (pid: $0.0, basename: $0.1) }
  }

  func openVnodePaths(of pid: pid_t) -> [String] {
    openVnodes[pid] ?? []
  }

  func arguments(of pid: pid_t) -> [String] { [] }

  func environment(of pid: pid_t) -> [String: String] { [:] }

  func currentWorkingDirectory(of pid: pid_t) -> String? { nil }
}
