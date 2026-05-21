import Foundation
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanDebug

/// Regression for the headless restore path. `.executeNow` agent
/// resumes are launched at spawn as `$SHELL -l -i -c '<resume>; exec
/// $SHELL -l -i'`. The post-spawn pass shared by headless launch
/// restore and `persistenceRelaunch`
/// (`HeadlessDebugRuntime.applyRestoreLaunchPlans`) must therefore NOT
/// also type the resume command — doing so would resume the agent a
/// second time. This guards against re-adding the old `.executeNow`
/// write to that shared static.
final class HeadlessRestoreInjectionTests: XCTestCase {

  func testHeadlessRestoreDoesNotTypeExecuteNowResumeIntoSession() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-restore-inject-\(UUID().uuidString)")
    let persistence = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-restore-inject-persist-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: artifacts)
      try? FileManager.default.removeItem(at: persistence)
    }

    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0000"
    let store = PersistenceStore(baseURL: persistence)
    try store.save(
      WorkspaceState(
        windows: [
          WindowState(
            id: "headless-window",
            selectedTabId: "agent-tab",
            tabs: [
              // wasRunningAtQuit + no shellPid → planner yields
              // `.executeNow` (no live session can be detected for a
              // bogus/absent pid).
              TabState(
                id: "agent-tab",
                cwd: NSHomeDirectory(),
                launchCommand: "claude --model sonnet",
                lastActiveAt: Date(),
                agent: AgentInfo(
                  name: .claude,
                  sessionId: sessionId,
                  jsonlPath: "/Users/x/.claude/projects/p/\(sessionId).jsonl",
                  wasRunningAtQuit: true,
                  argv: ["claude", "--model", "sonnet"],
                  env: ["TERM": "xterm-256color"],
                  cwd: NSHomeDirectory()))
            ])
        ]))

    // Fixture mode: there is no real shell to inject into, so the only
    // thing that could write the resume command is the post-spawn pass.
    // A fixture session echoes anything written to it back into the
    // grid, so if the pass (wrongly) types `.executeNow`, the resume
    // command becomes visible terminal text.
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "restore-inject-regression",
      persistenceBaseURL: persistence,
      restorePersistedState: true)

    XCTAssertEqual(
      runtime.model.tabs.map { $0.id }, ["agent-tab"],
      "the executeNow agent tab must be restored")

    let session = try XCTUnwrap(runtime.model.session(forTab: "agent-tab"))
    _ = session.poll()
    let snapshot = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snapshot) }
    let visible = TerminalSnapshotText.visibleText(
      from: UnsafePointer(snapshot), mode: .trimmedNonEmptyRows)
    XCTAssertFalse(
      visible.contains("--resume"),
      "headless restore must not type the executeNow resume command; visible=\(visible.debugDescription)"
    )
  }
}
