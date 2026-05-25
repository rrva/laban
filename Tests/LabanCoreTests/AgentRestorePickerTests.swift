import Foundation
import XCTest

@testable import LabanCore

final class AgentRestorePickerTests: XCTestCase {
  func testCandidateShowsAgeAndDefaultsUnchecked() {
    let now = Date(timeIntervalSince1970: 1_000)
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "window",
          selectedTabId: "agent-tab",
          tabs: [
            TabState(
              id: "agent-tab",
              cwd: "/repo",
              launchCommand: "/bin/zsh -l",
              lastActiveAt: Date(timeIntervalSince1970: 940),
              agent: AgentInfo(
                name: .claude,
                sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
                jsonlPath: "/mirror/session.jsonl",
                wasRunningAtQuit: true,
                argv: ["claude", "--model", "sonnet"],
                cwd: "/repo")),
          ])
      ])

    let candidates = AgentRestorePicker.candidates(
      from: state,
      now: now,
      cwdExists: { $0 == "/repo" },
      repoFingerprint: { _ in nil })

    XCTAssertEqual(candidates.count, 1)
    XCTAssertEqual(candidates[0].tabId, "agent-tab")
    XCTAssertEqual(candidates[0].ageSeconds, 60)
    XCTAssertEqual(candidates[0].checkedByDefault, false)
    XCTAssertEqual(
      candidates[0].command,
      "command claude --resume 0fa31a8c-1234-5678-9abc-deadbeef0000 --model sonnet")
    XCTAssertTrue(candidates[0].warnings.isEmpty)
  }

  func testMissingCwdAndRepoFingerprintMismatchWarnAndFallbackHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let tab = TabState(
      id: "agent-tab",
      cwd: "/missing/repo",
      launchCommand: "/bin/zsh -l",
      lastActiveAt: Date(timeIntervalSince1970: 1_000),
      repoFingerprint: "root=/old;gitdir=/old/.git",
      agent: AgentInfo(
        name: .codex,
        sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0001",
        jsonlPath: "/mirror/codex.jsonl",
        wasRunningAtQuit: true,
        cwd: "/missing/repo"))

    let candidate = AgentRestorePicker.candidate(
      for: tab,
      now: Date(timeIntervalSince1970: 1_010),
      cwdExists: { _ in false },
      repoFingerprint: { _ in nil })

    let unwrapped = try! XCTUnwrap(candidate)
    XCTAssertEqual(unwrapped.launchCwd, home)
    XCTAssertEqual(
      unwrapped.warnings.map(\.code),
      [.cwdMissing, .repoFingerprintMismatch])
    XCTAssertEqual(unwrapped.checkedByDefault, false)
    XCTAssertTrue(unwrapped.command.contains("codex resume 0fa31a8c"))
    XCTAssertTrue(unwrapped.command.contains("-C \(home)"))
  }
}
