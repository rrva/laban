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
        cwd: "/Users/rrj/wrk/laban",
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
    var metadata = TabTitleMetadata(
      displayTitle: "Tab 1",
      titleSource: .fallback,
      workspace: TabWorkspaceMetadata(
        repoName: "laban",
        worktreeName: "cobra",
        branch: "main",
        isDirty: true
      ),
      process: TabProcessMetadata(foregroundProcess: "claude"),
      lastOutputAt: now.addingTimeInterval(-14)
    )

    var resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1, now: now)
    XCTAssertEqual(resolved.subtitle, "laban@cobra | main* | claude | 14s")

    metadata.activityState = .exited
    metadata.exitStatus = 7
    resolved = TabTitleResolver.resolve(metadata, fallbackPosition: 1, now: now)
    XCTAssertEqual(resolved.subtitle, "laban@cobra | main* | claude | exited 7")
    XCTAssertEqual(resolved.statusBadge, "!")
  }
}
