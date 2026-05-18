import Foundation
import LabanCore
import XCTest

@testable import LabanCore

final class RestorePlannerTests: XCTestCase {

  private func tab(
    agent: AgentInfo?,
    status: PersistedProcessStatus? = .running
  ) -> TabState {
    TabState(
      id: "tab-1",
      cwd: "/tmp",
      launchCommand: "/bin/zsh -l",
      lastActiveAt: Date(),
      processStatus: status,
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
      .executeNow(command: "claude --resume abc"))
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
      .prefillPrompt(command: "claude --resume abc"))
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
      .executeNow(command: "claude --resume abc --model sonnet"))
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
