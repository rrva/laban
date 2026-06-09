import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TabTitleMetadataTests: XCTestCase {

  private func makeModel() throws -> AppModel {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return try AppModel(initialSize: size)
  }

  func testTitleSourcePrecedence() {
    let metadata = TabTitleMetadata(
      userTitle: "manual task",
      terminalTitle: "zsh",
      displayTitle: "Tab 1",
      titleSource: .fallback,
      workspace: TabWorkspaceMetadata(
        cwd: "/tmp/laban",
        repoName: "laban",
        worktreeName: "cobra",
        branch: "main",
        isDirty: true
      ),
      process: TabProcessMetadata(foregroundProcess: "claude"),
      agent: TabAgentMetadata(taskLabel: "agent task")
    )

    let resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1)

    XCTAssertEqual(resolved.displayTitle, "manual task")
    XCTAssertEqual(resolved.titleSource, .user)
  }

  func testAgentBeatsRepoAndTerminalTitle() {
    let metadata = TabTitleMetadata(
      terminalTitle: "zsh",
      displayTitle: "Tab 1",
      titleSource: .fallback,
      workspace: TabWorkspaceMetadata(repoName: "laban", worktreeName: "cobra"),
      agent: TabAgentMetadata(sessionName: "fix flaky debug test")
    )

    let resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1)

    XCTAssertEqual(resolved.displayTitle, "fix flaky debug test")
    XCTAssertEqual(resolved.titleSource, .agent)
  }

  func testRepoCwdProcessTerminalAndFallbackSources() {
    let repo = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 2",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(repoName: "laban", worktreeName: "cobra")
      ),
      fallbackPosition: 2
    )
    XCTAssertEqual(repo.displayTitle, "laban@cobra")
    XCTAssertEqual(repo.titleSource, .repo)

    let cwd = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 3",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(
          cwd: (NSHomeDirectory() as NSString).appendingPathComponent("wrk/laban"))
      ),
      fallbackPosition: 3
    )
    // Basename — sidebar columns are narrow; the parent path adds noise
    // without disambiguating in the common case.
    XCTAssertEqual(cwd.displayTitle, "laban")
    XCTAssertEqual(cwd.titleSource, .cwd)

    let process = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 4",
        titleSource: .fallback,
        process: TabProcessMetadata(foregroundCommand: "/usr/local/bin/claude --resume")
      ),
      fallbackPosition: 4
    )
    XCTAssertEqual(process.displayTitle, "claude")
    XCTAssertEqual(process.titleSource, .process)

    let terminal = TabTitleResolver.resolve(
      TabTitleMetadata(
        terminalTitle: "vim README.md",
        displayTitle: "Tab 5",
        titleSource: .fallback
      ),
      fallbackPosition: 5
    )
    XCTAssertEqual(terminal.displayTitle, "vim README.md")
    XCTAssertEqual(terminal.titleSource, .terminal)

    let fallback = TabTitleResolver.resolve(
      TabTitleMetadata(displayTitle: "Tab 6", titleSource: .fallback),
      fallbackPosition: 6
    )
    XCTAssertEqual(fallback.displayTitle, "Tab 6")
    XCTAssertEqual(fallback.titleSource, .fallback)
  }

  func testShellForegroundUsesCwdInsteadOfStaleTerminalTitle() {
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        terminalTitle: "Claude Code",
        displayTitle: "Tab 1",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(cwd: NSHomeDirectory()),
        process: TabProcessMetadata(
          foregroundProcess: "zsh",
          foregroundCommand: "/bin/zsh"
        )
      ),
      fallbackPosition: 1
    )

    XCTAssertEqual(resolved.displayTitle, "~")
    XCTAssertEqual(resolved.titleSource, .cwd)
    XCTAssertEqual(resolved.infoLines, [])
  }

  func testLoginShellDashNameIsRecognizedAsShell() {
    // A login shell presents argv[0] as "-zsh"; it must be treated as a shell
    // (fall through to the cwd) rather than surfaced as the tab's program.
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 1",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(
          cwd: (NSHomeDirectory() as NSString).appendingPathComponent("wrk/laban")),
        process: TabProcessMetadata(foregroundProcess: "-zsh")
      ),
      fallbackPosition: 1
    )

    XCTAssertEqual(resolved.displayTitle, "laban")
    XCTAssertEqual(resolved.titleSource, .cwd)
    XCTAssertFalse(
      resolved.infoLines.contains("-zsh"),
      "a login shell must not appear as a running program in the info lines")
  }

  func testSpinnerDecoratedTitleSuppressesRepeatedFolderLine() {
    // Codex sets its OSC 0 title to a progress spinner + project name ("⠴ laban")
    // while active. The folder line must recognize that the title is really just
    // the project name and not render "laban" a second time underneath it.
    let cwd = (NSHomeDirectory() as NSString).appendingPathComponent("wrk/laban")
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        terminalTitle: "\u{2834} laban",
        displayTitle: "Tab 6",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(cwd: cwd),
        process: TabProcessMetadata(foregroundProcess: "codex")
      ),
      fallbackPosition: 6
    )

    XCTAssertEqual(resolved.displayTitle, "\u{2834} laban")
    XCTAssertFalse(
      resolved.infoLines.contains("laban"),
      "the folder line must not repeat the project name already in the title")
  }

  func testSpinnerDecoratedTitleStillShowsADifferentFolder() {
    // The decoration-stripping dedup must only drop an actual repeat — a folder
    // whose name differs from the title's core still earns its info line.
    let cwd = (NSHomeDirectory() as NSString).appendingPathComponent("wrk/laban")
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        terminalTitle: "\u{2834} building",
        displayTitle: "Tab 7",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(cwd: cwd),
        process: TabProcessMetadata(foregroundProcess: "codex")
      ),
      fallbackPosition: 7
    )

    XCTAssertTrue(
      resolved.infoLines.contains("laban"),
      "a folder that differs from the title core must still be shown")
  }

  func testCurrentTerminalTitleBeatsNonShellForegroundProcess() {
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        terminalTitle: "* Claude Code",
        displayTitle: "Tab 1",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(cwd: NSHomeDirectory()),
        process: TabProcessMetadata(
          foregroundProcess: "2.1.126",
          foregroundCommand: "/opt/homebrew/bin/2.1.126"
        )
      ),
      fallbackPosition: 1
    )

    XCTAssertEqual(resolved.displayTitle, "* Claude Code")
    XCTAssertEqual(resolved.titleSource, .terminal)
  }

  func testNonShellForegroundProcessBeatsCwdWhenNoTerminalTitle() {
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 1",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(cwd: NSHomeDirectory()),
        process: TabProcessMetadata(
          foregroundProcess: "top",
          foregroundCommand: "/usr/bin/top"
        )
      ),
      fallbackPosition: 1
    )

    XCTAssertEqual(resolved.displayTitle, "top")
    XCTAssertEqual(resolved.titleSource, .process)
  }

  func testProcessBinaryPathMatchingTitleDoesNotBecomeInfoLine() {
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 1",
        titleSource: .fallback,
        process: TabProcessMetadata(
          foregroundProcess: "mytool",
          foregroundCommand: "/Users/dev/.local/bin/mytool"
        )
      ),
      fallbackPosition: 1
    )

    XCTAssertEqual(resolved.displayTitle, "mytool")
    XCTAssertEqual(resolved.titleSource, .process)
    XCTAssertFalse(
      resolved.infoLines.contains { $0.contains("/Users/dev") || $0 == "mytool" },
      "binary path should not duplicate the process title: \(resolved.infoLines)")
  }

  func testNodeArgumentsRenderUsefulCommandDetail() {
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 1",
        titleSource: .fallback,
        process: TabProcessMetadata(
          foregroundProcess: "node",
          foregroundCommand: "/Users/dev/.volta/bin/node",
          foregroundArguments: [
            "/Users/dev/.volta/bin/node",
            "/Users/dev/projects/web-app/src/server.ts",
            "--watch",
          ]
        )
      ),
      fallbackPosition: 1
    )

    XCTAssertEqual(resolved.displayTitle, "node")
    XCTAssertEqual(resolved.infoLines, ["server.ts --watch"])
  }

  func testNodePackageRunnerArgumentsRenderTarget() {
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 1",
        titleSource: .fallback,
        process: TabProcessMetadata(
          foregroundProcess: "node",
          foregroundCommand: "/opt/homebrew/bin/node",
          foregroundArguments: [
            "/opt/homebrew/bin/node",
            "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js",
            "run",
            "dev",
          ]
        )
      ),
      fallbackPosition: 1
    )

    XCTAssertEqual(resolved.displayTitle, "node")
    XCTAssertEqual(resolved.infoLines, ["npm run dev"])
  }

  func testHomeRelativeCwdUsesBasename() {
    let resolved = TabTitleResolver.resolve(
      TabTitleMetadata(
        displayTitle: "Tab 1",
        titleSource: .fallback,
        workspace: TabWorkspaceMetadata(
          cwd: (NSHomeDirectory() as NSString).appendingPathComponent("src/laban"))
      ),
      fallbackPosition: 1
    )

    // Title and subtitle both collapse to the cwd basename — sidebar
    // columns are narrow and the parent dirs rarely disambiguate.
    XCTAssertEqual(resolved.displayTitle, "laban")
    XCTAssertEqual(resolved.titleSource, .cwd)
    XCTAssertEqual(resolved.subtitle, "laban")
  }

  func testHostileTerminalTitleIsSanitizedAndBounded() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let hostile = "  " + String(repeating: "a", count: 600) + "\u{01}\u{85}\nnext  "

    try model.updateTerminalTitle(hostile, forTab: tabId)

    let metadata = model.tabs[0].titleMetadata
    XCTAssertEqual(metadata.titleSource, .terminal)
    XCTAssertEqual(metadata.terminalTitle?.unicodeScalars.count, TerminalTitle.maxLength)
    XCTAssertFalse(metadata.displayTitle.unicodeScalars.contains { $0.value < 0x20 })
    XCTAssertLessThanOrEqual(metadata.displayTitle.unicodeScalars.count, TerminalTitle.maxLength)
  }

  func testManualTitleSurvivesLaterTerminalTitleChanges() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let sessionId = model.tabs[0].sessionId

    try model.updateTerminalTitle("zsh", forTab: tabId)
    try model.renameTab(tabId, title: "auth retry cleanup")
    try model.updateTerminalTitle("vim README.md", forTab: tabId)

    XCTAssertEqual(model.tabs[0].title, "auth retry cleanup")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .user)
    XCTAssertEqual(model.tabs[0].titleMetadata.terminalTitle, "vim README.md")
    XCTAssertEqual(model.tabs[0].id, tabId)
    XCTAssertEqual(model.tabs[0].sessionId, sessionId)
  }

  func testClearUserTitleReturnsToAutomaticTitle() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    try model.updateTerminalTitle("zsh", forTab: tabId)
    try model.renameTab(tabId, title: "manual")
    try model.clearUserTitle(forTab: tabId)

    XCTAssertEqual(model.tabs[0].title, "zsh")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .terminal)
  }

  func testSubtitleIncludesWorkspaceProcessAgeAndExit() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let activity = now.addingTimeInterval(-14)
    var metadata = TabTitleMetadata(
      displayTitle: "Tab 1",
      titleSource: .fallback,
      workspace: TabWorkspaceMetadata(
        repoName: "laban",
        worktreeName: "cobra",
        branch: "main",
        isDirty: true
      ),
      process: TabProcessMetadata(foregroundProcess: "claude")
    )

    var resolved = TabTitleResolver.resolve(
      metadata, fallbackPosition: 1, now: now, lastActivity: activity)
    XCTAssertEqual(resolved.subtitle, "laban@cobra | main* | claude | 14s")

    metadata.activityState = .exited
    metadata.exitStatus = 7
    resolved = TabTitleResolver.resolve(
      metadata, fallbackPosition: 1, now: now, lastActivity: activity)
    XCTAssertEqual(resolved.subtitle, "laban@cobra | main* | claude | exited 7")
    XCTAssertEqual(resolved.statusBadge, "!")
  }

  func testBellAttentionBadgePriority() {
    var metadata = TabTitleMetadata(
      displayTitle: "Tab 1",
      titleSource: .fallback,
      unseenOutput: true,
      bellAttention: true
    )

    var resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1)
    XCTAssertEqual(resolved.statusBadge, "•")

    metadata.activityState = .waiting
    resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1)
    XCTAssertEqual(resolved.statusBadge, "!")

    metadata.activityState = .exited
    metadata.exitStatus = 7
    resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1)
    XCTAssertEqual(resolved.statusBadge, "!")
  }

  func testDirectFieldMutationIsSanitizedBySetter() {
    // The render-time resolver no longer re-sanitizes, so a raw write that
    // bypasses the initializer must still be cleaned by the field's didSet.
    var metadata = TabTitleMetadata(displayTitle: "Tab 1", titleSource: .fallback)
    metadata.workspace.cwd = "/tmp/\u{01}evil\nname"
    metadata.process.foregroundProcess = "ze\u{07}sh"
    metadata.process.foregroundArguments = ["arg\u{1F}one", "\u{01}\u{02}"]
    metadata.agent.model = "claude\u{1B}-opus"
    metadata.terminalTitle = "ti\u{7F}tle"

    XCTAssertEqual(metadata.workspace.cwd, "/tmp/evil name")
    XCTAssertEqual(metadata.process.foregroundProcess, "zesh")
    XCTAssertEqual(metadata.process.foregroundArguments, ["argone"])
    XCTAssertEqual(metadata.agent.model, "claude-opus")
    XCTAssertEqual(metadata.terminalTitle, "title")

    let resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1)
    XCTAssertFalse(resolved.displayTitle.unicodeScalars.contains { $0.value < 0x20 })
    XCTAssertFalse(
      resolved.infoLines.joined().unicodeScalars.contains { $0.value < 0x20 })
  }
}
