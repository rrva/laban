import Darwin
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Multi-cycle quit/restore tests that exercise the production
/// wiring chain (AppModel + PersistenceCoordinator + TranscriptHost +
/// deferred-spawn factory) end-to-end without AppKit. Each cycle:
///   1. Tears down the prior "session" (drops Swift refs, lets
///      persistence flush).
///   2. Constructs a fresh AppModel against the same persistence
///      directory.
///   3. Loads `workspace.json` and calls `replaceTabs(from:)`.
///   4. Asserts the new AppModel's tabs match what the prior session
///      saved.
///   5. Asserts per-tab transcript files remain diagnostic artifacts
///      and are not silently replayed into restored terminals.
///
/// Three back-to-back cycles catch regressions where the persistence
/// path works once but corrupts state on the second relaunch.
final class WorkspaceRestoreEndToEndTests: XCTestCase {

  private enum HarnessSessionMode {
    case fixture
    case realShell
  }

  private enum HarnessError: Error {
    case spawnFailed
  }

  private struct Harness {
    let baseDir: URL
    let model: AppModel
    let coordinator: PersistenceCoordinator
    let transcriptHost: TranscriptHost
  }

  /// Build the same wiring `MainWindowController.makeAndShow` uses,
  /// minus the AppKit window. Fixture sessions instead of real
  /// shells so most tests are fast and deterministic.
  private func makeHarness(
    baseDir: URL,
    restoring restoredState: WorkspaceState? = nil,
    sessionMode: HarnessSessionMode = .fixture
  ) throws -> Harness {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(
      initialSize: size,
      sessionFactory: { size in
        try Self.makeFreshSession(size: size, mode: sessionMode)
      })

    let transcriptHost = TranscriptHost(
      store: PersistenceStore(baseURL: baseDir),
      isEnabled: { true })
    model.transcriptDelegate = transcriptHost
    // Deferred factory used by replaceTabs(from:). It intentionally
    // does not replay transcripts: historical output is diagnostic
    // data, not live terminal state.
    model.restoredDeferredSessionFactory = { spec in
      let session = try Self.makeRestoredSession(spec: spec, mode: sessionMode)
      if case .realShell = sessionMode {
        let override = spec.cwdFallbackApplied ? spec.cwd : nil
        guard session.startSpawn(overrideCwd: override) == 0 else {
          throw HarnessError.spawnFailed
        }
      }
      return session
    }

    // Attach writers to the default tab created by AppModel.init.
    for (tab, session) in model.allSessions() {
      transcriptHost.attachTranscriptWriter(to: session, tabId: tab.id)
    }

    if let restoredState, !restoredState.windows.isEmpty {
      model.replaceTabs(from: restoredState)
      applyRestoreLaunchPlans(for: restoredState, model: model)
    }
    // Mirror MainWindowController: restore can leave zero tabs; the
    // app shell layer falls back to a fresh default tab.
    if model.tabs.isEmpty {
      _ = try? model.createTab()
    }

    let coordinator = PersistenceCoordinator(
      store: PersistenceStore(baseURL: baseDir),
      windowId: "main-window",
      debounceInterval: .milliseconds(20),
      isEnabled: { true })
    coordinator.transcriptHost = transcriptHost
    coordinator.attach(model)
    coordinator.scheduleSave()

    return Harness(
      baseDir: baseDir,
      model: model,
      coordinator: coordinator,
      transcriptHost: transcriptHost)
  }

  /// Simulate Cmd-Q: flush the persistence coordinator (which
  /// drains transcript writers and writes workspace.json), then
  /// close every session. The harness is dropped by the caller.
  private func quit(_ harness: Harness) {
    harness.coordinator.flushSync()
    harness.model.closeAllSessions()
  }

  private func tempBase() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-e2e-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func makeFreshSession(
    size: LabanTerminalSize,
    mode: HarnessSessionMode
  ) throws -> Session {
    switch mode {
    case .fixture:
      return try Session.fixture(size: size)
    case .realShell:
      let session = try Session.makeDeferred(size: size, cwd: NSHomeDirectory())
      guard session.startSpawn() == 0 else { throw HarnessError.spawnFailed }
      return session
    }
  }

  private static func makeRestoredSession(
    spec: RestoredSessionSpec,
    mode: HarnessSessionMode
  ) throws -> Session {
    switch mode {
    case .fixture:
      return try Session.fixture(size: spec.size)
    case .realShell:
      return try Session.makeDeferred(size: spec.size, cwd: spec.cwd)
    }
  }

  // MARK: - Cycle test

  func testCleanSlateThenThreeQuitRestoreCycles() throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }

    // -------- Cycle 0: clean slate. No prior workspace.json. --------
    let store = PersistenceStore(baseURL: base)
    XCTAssertNil(store.load(), "clean slate must have no workspace state")

    let harness0 = try makeHarness(baseDir: base)
    XCTAssertEqual(harness0.model.tabs.count, 1, "fresh launch starts with one default tab")

    // Create two additional tabs and feed each some bytes through
    // its fixture session's PTY pipeline.
    let tab1 = try harness0.model.createTab()
    let tab2 = try harness0.model.createTab()
    XCTAssertEqual(harness0.model.tabs.count, 3)

    let defaultTabId = harness0.model.tabs[0].id
    let tab1Id = tab1.id
    let tab2Id = tab2.id

    // Feed distinct content into each tab. fixture mode routes
    // feedOutput through laban_vt_write_capture, which triggers the
    // persistence callback registered by TranscriptHost.
    _ = harness0.model.session(forTab: defaultTabId)?.feedOutput(
      Array("default tab content\r\n".utf8))
    _ = harness0.model.session(forTab: tab1Id)?.feedOutput(
      Array("tab one content\r\n".utf8))
    _ = harness0.model.session(forTab: tab2Id)?.feedOutput(
      Array("tab two content\r\n".utf8))

    // Select the middle tab so the restore round-trip exercises
    // selectedTabId persistence.
    harness0.model.selectTab(tab1Id)

    quit(harness0)
    let _ = harness0

    // -------- Cycle 1: relaunch from disk. --------
    let workspace1 = try XCTUnwrap(store.load(), "workspace.json must exist after quit")
    XCTAssertEqual(workspace1.windows.count, 1)
    XCTAssertEqual(workspace1.windows[0].tabs.count, 3, "all three tabs must persist")
    XCTAssertEqual(workspace1.windows[0].tabs.map { $0.id }, [defaultTabId, tab1Id, tab2Id])
    XCTAssertEqual(workspace1.windows[0].selectedTabId, tab1Id)

    // Each tab's transcript file must exist with the captured bytes.
    for tabId in [defaultTabId, tab1Id, tab2Id] {
      let url = store.transcriptURL(forTabId: tabId)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: url.path),
        "transcript for tab \(tabId) must persist")
    }

    let harness1 = try makeHarness(baseDir: base, restoring: workspace1)
    XCTAssertEqual(harness1.model.tabs.count, 3, "restore must rebuild three tabs")
    XCTAssertEqual(
      harness1.model.tabs.map { $0.id },
      [defaultTabId, tab1Id, tab2Id],
      "tab IDs and order must round-trip")
    XCTAssertEqual(harness1.model.activeTab?.id, tab1Id, "selection must round-trip")

    // Transcript files are historical diagnostics. Restored live
    // terminals must not paint prior output as if shell state
    // survived relaunch.
    assertNotVisible(
      harness1.model, tabId: defaultTabId, contains: "default tab content")
    assertNotVisible(
      harness1.model, tabId: tab1Id, contains: "tab one content")
    assertNotVisible(
      harness1.model, tabId: tab2Id, contains: "tab two content")

    // Restored tabs suppress capture for ~500ms after attach so the
    // new shell's spawn-time prompt doesn't accumulate across
    // restore cycles. Wait past that window before injecting
    // "post-restore user activity" so the test asserts the
    // captured-after-startup path.
    Thread.sleep(forTimeInterval: 0.6)

    // Add a new tab in this cycle, write new content to existing
    // tabs, and shift the selection.
    let tab3 = try harness1.model.createTab()
    let tab3Id = tab3.id
    _ = harness1.model.session(forTab: tab3Id)?.feedOutput(
      Array("tab three NEW content\r\n".utf8))
    _ = harness1.model.session(forTab: tab1Id)?.feedOutput(
      Array("tab one AFTER restore\r\n".utf8))
    harness1.model.selectTab(defaultTabId)

    quit(harness1)
    let _ = harness1

    // -------- Cycle 2: second relaunch. --------
    let workspace2 = try XCTUnwrap(store.load())
    XCTAssertEqual(workspace2.windows[0].tabs.count, 4, "cycle-1 additions must persist")
    XCTAssertEqual(workspace2.windows[0].selectedTabId, defaultTabId)

    let harness2 = try makeHarness(baseDir: base, restoring: workspace2)
    XCTAssertEqual(harness2.model.tabs.count, 4)
    XCTAssertEqual(harness2.model.activeTab?.id, defaultTabId)
    assertNotVisible(harness2.model, tabId: tab1Id, contains: "tab one content")
    assertNotVisible(harness2.model, tabId: tab1Id, contains: "tab one AFTER restore")
    assertNotVisible(harness2.model, tabId: tab3Id, contains: "tab three NEW content")

    // Close a tab to verify close-then-quit-then-restore works.
    try harness2.model.closeTab(tab2Id)
    XCTAssertEqual(harness2.model.tabs.count, 3)
    quit(harness2)
    let _ = harness2

    // -------- Cycle 3: third relaunch. --------
    let workspace3 = try XCTUnwrap(store.load())
    XCTAssertEqual(
      workspace3.windows[0].tabs.count, 3,
      "closed tab must be gone from persisted state")
    XCTAssertFalse(
      workspace3.windows[0].tabs.contains(where: { $0.id == tab2Id }))

    let harness3 = try makeHarness(baseDir: base, restoring: workspace3)
    XCTAssertEqual(harness3.model.tabs.count, 3)
    XCTAssertEqual(
      Set(harness3.model.tabs.map { $0.id }),
      Set([defaultTabId, tab1Id, tab3Id]))

    quit(harness3)
    let _ = harness3
  }

  func testSmallEchoTranscriptStaysStableAcrossRepeatedRestoreCycles() throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = PersistenceStore(baseURL: base)

    let first = try makeHarness(baseDir: base)
    let tabId = try XCTUnwrap(first.model.activeTab?.id)
    let echoBytes = Array("e\u{0008}echo hej\r\nhej\r\n".utf8)
    _ = first.model.session(forTab: tabId)?.feedOutput(echoBytes)
    quit(first)
    let _ = first

    for cycle in 1...5 {
      let workspace = try XCTUnwrap(
        store.load(),
        "workspace must exist before restore cycle \(cycle)")
      let restored = try makeHarness(baseDir: base, restoring: workspace)

      let visible = visibleText(restored.model, tabId: tabId)
      XCTAssertFalse(
        visible.contains("echo hej"),
        "cycle \(cycle) silently replayed the old command; visible=\(visible.debugDescription)")
      XCTAssertFalse(
        visible.contains("hej"),
        "cycle \(cycle) silently replayed the old output; visible=\(visible.debugDescription)")
      XCTAssertFalse(
        visible.contains("eecho hej"),
        "cycle \(cycle) duplicated the first character; visible=\(visible.debugDescription)")
      XCTAssertFalse(
        visible.contains("%"),
        "cycle \(cycle) persisted zsh PROMPT_SP marker; visible=\(visible.debugDescription)")
      XCTAssertFalse(
        visible.unicodeScalars.contains { $0.value == 0 },
        "cycle \(cycle) rendered a NUL glyph; visible=\(visible.debugDescription)")

      let data = try Data(contentsOf: store.transcriptURL(forTabId: tabId))
      XCTAssertEqual(
        Array(data), echoBytes,
        "cycle \(cycle) must not rewrite or append to the original echo transcript")

      // Simulate the restored shell's startup prompt while the
      // restored-tab capture suppression window is still active. This
      // output may paint the current process, but it must not enter
      // the persisted diagnostic transcript.
      let promptNoise = Array("\u{001B}[1m\u{001B}[7m%\u{001B}[27m\u{001B}[K\r~$ ".utf8)
      _ = restored.model.session(forTab: tabId)?.feedOutput(promptNoise)
      quit(restored)
      let _ = restored
    }
  }

  func testAgentRestoreExecutesNativeResumeWithoutDestructiveOriginalFlags() throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let now = Date()
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0000"
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "main-window",
          selectedTabId: "agent-tab",
          tabs: [
            TabState(
              id: "agent-tab",
              cwd: "/tmp",
              launchCommand: "claude --model sonnet --worktree throwaway",
              lastActiveAt: now,
              agent: AgentInfo(
                name: .claude,
                sessionId: sessionId,
                jsonlPath: "/Users/x/.claude/projects/p/\(sessionId).jsonl",
                wasRunningAtQuit: true,
                argv: ["claude", "--model", "sonnet", "--worktree", "throwaway"],
                env: ["TERM": "xterm-256color"],
                cwd: "/tmp"))
          ])
      ])

    let harness = try makeHarness(baseDir: base, restoring: state)
    let visible = visibleText(harness.model, tabId: "agent-tab")
    let visibleCommandText = visible.replacingOccurrences(of: "\n", with: "")
    XCTAssertTrue(
      visibleCommandText.contains("claude --resume \(sessionId) --model sonnet"),
      "restored agent tab should receive the native resume command; visible=\(visible.debugDescription)"
    )
    XCTAssertFalse(
      visibleCommandText.contains("--worktree"),
      "native resume must not replay destructive original flags; visible=\(visible.debugDescription)"
    )
    XCTAssertFalse(
      visibleCommandText.contains("throwaway"),
      "native resume must not replay destructive flag values; visible=\(visible.debugDescription)")

    quit(harness)
    let _ = harness
  }

  func testRestoreWithEmptyWindowFallsBackToFreshDefaultTab() throws {
    let base = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }

    // Degenerate state: a persisted window with zero tabs. This shape
    // is reachable when the user closed the last tab right before
    // quit. replaceTabs(from:) will tear down the auto-created
    // default tab and find nothing to spawn — the app shell must
    // recover by opening a fresh default-shell tab, the same path
    // the "+" titlebar button uses.
    let state = WorkspaceState(
      windows: [WindowState(id: "main-window", selectedTabId: nil, tabs: [])])

    let harness = try makeHarness(baseDir: base, restoring: state)
    XCTAssertEqual(
      harness.model.tabs.count, 1,
      "empty-window restore must fall back to one fresh default tab")
    XCTAssertNotNil(
      harness.model.activeTab,
      "the fallback tab must be selected so the user has a focused terminal")

    quit(harness)
    let _ = harness
  }

  func testRealZshEchoStaysStableAcrossRepeatedRestoreCycles() throws {
    guard access("/bin/zsh", X_OK) == 0 else {
      throw XCTSkip("/bin/zsh is not available")
    }
    let base = tempBase()
    let zdotdir = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    defer { try? FileManager.default.removeItem(at: zdotdir) }
    try writeMinimalZshConfig(to: zdotdir)

    try withEnvironment(["SHELL": "/bin/zsh", "ZDOTDIR": zdotdir.path]) {
      let store = PersistenceStore(baseURL: base)
      let first = try makeHarness(baseDir: base, sessionMode: .realShell)
      let tabId = try XCTUnwrap(first.model.activeTab?.id)
      let session = try XCTUnwrap(first.model.session(forTab: tabId))

      _ = session.write(Array("echo hej\n".utf8))
      XCTAssertTrue(
        waitForVisibleText(first.model, tabId: tabId, contains: "hej"),
        "initial zsh session never rendered echo output")
      quit(first)
      let _ = first

      let transcriptURL = store.transcriptURL(forTabId: tabId)
      let baseline = try Data(contentsOf: transcriptURL)
      XCTAssertFalse(baseline.isEmpty)
      XCTAssertTrue(
        String(data: baseline, encoding: .utf8)?.contains("hej") == true,
        "baseline transcript should contain the echo output")

      for cycle in 1...4 {
        let workspace = try XCTUnwrap(
          store.load(),
          "workspace must exist before real zsh restore cycle \(cycle)")
        let restored = try makeHarness(
          baseDir: base,
          restoring: workspace,
          sessionMode: .realShell)

        // Let zsh finish painting its startup prompt. Restored-tab
        // capture suppression should drop those bytes, so a
        // quit/reopen loop without user input does not append another
        // prompt or PROMPT_SP marker to the transcript.
        Thread.sleep(forTimeInterval: 0.7)
        let visible = visibleText(restored.model, tabId: tabId)
        XCTAssertFalse(
          visible.contains("echo hej"),
          "cycle \(cycle) silently replayed the command; visible=\(visible.debugDescription)")
        XCTAssertFalse(
          visible.contains("hej"),
          "cycle \(cycle) silently replayed the output; visible=\(visible.debugDescription)")
        XCTAssertFalse(
          visible.contains("eecho hej"),
          "cycle \(cycle) duplicated the first character; visible=\(visible.debugDescription)")
        XCTAssertFalse(
          visible.contains("%"),
          "cycle \(cycle) rendered zsh PROMPT_SP marker; visible=\(visible.debugDescription)")
        XCTAssertFalse(
          visible.unicodeScalars.contains { $0.value == 0 },
          "cycle \(cycle) rendered a NUL glyph; visible=\(visible.debugDescription)")

        quit(restored)
        let _ = restored

        let afterQuit = try Data(contentsOf: transcriptURL)
        XCTAssertEqual(
          afterQuit, baseline,
          "cycle \(cycle) must not append zsh startup prompt bytes on quit")
      }
    }
  }

  func testRealZshEchoCanMutateAcrossRepeatedRestoreCycles() throws {
    guard access("/bin/zsh", X_OK) == 0 else {
      throw XCTSkip("/bin/zsh is not available")
    }
    let base = tempBase()
    let zdotdir = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    defer { try? FileManager.default.removeItem(at: zdotdir) }
    try writeMinimalZshConfig(to: zdotdir)

    try withEnvironment(["SHELL": "/bin/zsh", "ZDOTDIR": zdotdir.path]) {
      let store = PersistenceStore(baseURL: base)
      var commandCount = 0

      let first = try makeHarness(baseDir: base, sessionMode: .realShell)
      let tabId = try XCTUnwrap(first.model.activeTab?.id)
      try writeEchoCommand(
        first.model,
        tabId: tabId,
        expectedCommandCount: commandCount + 1,
        context: "initial zsh session")
      commandCount += 1
      assertCleanEchoState(
        first.model,
        tabId: tabId,
        expectedCommandCount: commandCount,
        context: "initial zsh session")
      quit(first)
      let _ = first
      try assertCleanEchoTranscript(
        store,
        tabId: tabId,
        expectedCommandCount: commandCount,
        context: "initial quit")

      for cycle in 1...4 {
        let workspace = try XCTUnwrap(
          store.load(),
          "workspace must exist before mutating restore cycle \(cycle)")
        let restored = try makeHarness(
          baseDir: base,
          restoring: workspace,
          sessionMode: .realShell)

        // Wait out restored-tab capture suppression before sending
        // intentional input. Startup prompt bytes should be ignored,
        // but user input after this point must still persist.
        Thread.sleep(forTimeInterval: 0.7)
        assertCleanEchoState(
          restored.model,
          tabId: tabId,
          expectedCommandCount: 0,
          context: "cycle \(cycle) before new input")

        try writeEchoCommand(
          restored.model,
          tabId: tabId,
          expectedCommandCount: 1,
          context: "cycle \(cycle) after new input")
        commandCount += 1
        assertCleanEchoState(
          restored.model,
          tabId: tabId,
          expectedCommandCount: 1,
          context: "cycle \(cycle) after new input")

        quit(restored)
        let _ = restored
        try assertCleanEchoTranscript(
          store,
          tabId: tabId,
          expectedCommandCount: commandCount,
          context: "cycle \(cycle) quit")
      }

      let workspace = try XCTUnwrap(store.load(), "workspace must exist before final restore")
      let final = try makeHarness(
        baseDir: base,
        restoring: workspace,
        sessionMode: .realShell)
      Thread.sleep(forTimeInterval: 0.7)
      assertCleanEchoState(
        final.model,
        tabId: tabId,
        expectedCommandCount: 0,
        context: "final restore")
      quit(final)
      let _ = final
    }
  }

  func testRealZshStartupPromptDoesNotStackAcrossNoInputRestarts() throws {
    guard access("/bin/zsh", X_OK) == 0 else {
      throw XCTSkip("/bin/zsh is not available")
    }
    let base = tempBase()
    let zdotdir = tempBase()
    defer { try? FileManager.default.removeItem(at: base) }
    defer { try? FileManager.default.removeItem(at: zdotdir) }
    try writePromptSpZshConfig(to: zdotdir)

    try withEnvironment(["SHELL": "/bin/zsh", "ZDOTDIR": zdotdir.path]) {
      let store = PersistenceStore(baseURL: base)
      let first = try makeHarness(baseDir: base, sessionMode: .realShell)
      let tabId = try XCTUnwrap(first.model.activeTab?.id)
      let session = try XCTUnwrap(first.model.session(forTab: tabId))

      _ = session.write(Array("echo hej\n".utf8))
      XCTAssertTrue(
        waitForVisibleText(first.model, tabId: tabId, contains: "hej"),
        "initial zsh session never rendered echo output")
      quit(first)
      let _ = first

      let transcriptURL = store.transcriptURL(forTabId: tabId)
      let baseline = try Data(contentsOf: transcriptURL)

      for cycle in 1...4 {
        let workspace = try XCTUnwrap(
          store.load(),
          "workspace must exist before PROMPT_SP restore cycle \(cycle)")
        let restored = try makeHarness(
          baseDir: base,
          restoring: workspace,
          sessionMode: .realShell)

        Thread.sleep(forTimeInterval: 1.0)
        let visible = visibleText(restored.model, tabId: tabId)
        XCTAssertFalse(
          visible.contains("echo hej"),
          "cycle \(cycle) silently replayed the command text; visible=\(visible.debugDescription)")
        XCTAssertFalse(
          visible.contains("%"),
          "cycle \(cycle) rendered a stacked zsh PROMPT_SP marker; visible=\(visible.debugDescription)"
        )

        quit(restored)
        let _ = restored

        let afterQuit = try Data(contentsOf: transcriptURL)
        XCTAssertGreaterThanOrEqual(
          afterQuit.count,
          baseline.count,
          "diagnostic transcript should remain readable across no-input restarts")
      }
    }
  }

  // MARK: - Helpers

  private func writeMinimalZshConfig(to zdotdir: URL) throws {
    let zshConfig = "PROMPT='$ '\nRPROMPT=''\n"
    try zshConfig.write(
      to: zdotdir.appendingPathComponent(".zshenv"),
      atomically: true,
      encoding: .utf8)
    try zshConfig.write(
      to: zdotdir.appendingPathComponent(".zshrc"),
      atomically: true,
      encoding: .utf8)
  }

  private func applyRestoreLaunchPlans(for state: WorkspaceState, model: AppModel) {
    guard let window = state.windows.first else { return }
    for tabState in window.tabs {
      let instruction = RestoreLaunchPlanner.instruction(for: tabState)
      switch instruction {
      case .noPrefill:
        continue
      case .executeNow(let command):
        guard let session = model.session(forTab: tabState.id) else { continue }
        _ = session.write(Array("clear && \(command)\n".utf8))
      case .prefillPrompt(let command):
        guard let session = model.session(forTab: tabState.id) else { continue }
        _ = session.write(Array(command.utf8))
      }
    }
  }

  private func writePromptSpZshConfig(to zdotdir: URL) throws {
    let zshConfig = """
      setopt PROMPT_SP
      PROMPT='~$ '
      RPROMPT=''
      PROMPT_EOL_MARK='%'

      """
    try zshConfig.write(
      to: zdotdir.appendingPathComponent(".zshenv"),
      atomically: true,
      encoding: .utf8)
    let zshRc = zshConfig + "sleep 0.8\nprintf partial\n"
    try zshRc.write(
      to: zdotdir.appendingPathComponent(".zshrc"),
      atomically: true,
      encoding: .utf8)
  }

  private func withEnvironment(
    _ updates: [String: String],
    _ body: () throws -> Void
  ) throws {
    let prior = updates.mapValues { _ -> String? in nil }
    var saved = prior
    for key in updates.keys {
      saved[key] = getenv(key).map { String(cString: $0) }
    }
    for (key, value) in updates {
      setenv(key, value, 1)
    }
    defer {
      for (key, value) in saved {
        if let value {
          setenv(key, value, 1)
        } else {
          unsetenv(key)
        }
      }
    }
    try body()
  }

  private func waitForVisibleText(
    _ model: AppModel,
    tabId: String,
    contains needle: String,
    timeout: TimeInterval = 3.0
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      _ = model.session(forTab: tabId)?.poll()
      if visibleText(model, tabId: tabId).contains(needle) {
        return true
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return false
  }

  private func waitForEchoCommandCount(
    _ model: AppModel,
    tabId: String,
    expected: Int,
    timeout: TimeInterval = 3.0
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      _ = model.session(forTab: tabId)?.poll()
      if echoCommandCount(in: visibleText(model, tabId: tabId)) >= expected {
        return true
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return false
  }

  private func writeEchoCommand(
    _ model: AppModel,
    tabId: String,
    expectedCommandCount: Int,
    context: String,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    let session = try XCTUnwrap(model.session(forTab: tabId), file: file, line: line)
    _ = session.write(Array("echo hej\n".utf8))
    XCTAssertTrue(
      waitForEchoCommandCount(model, tabId: tabId, expected: expectedCommandCount),
      "\(context) never rendered echo command \(expectedCommandCount)",
      file: file,
      line: line)
  }

  private func assertCleanEchoState(
    _ model: AppModel,
    tabId: String,
    expectedCommandCount: Int,
    context: String,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    _ = model.session(forTab: tabId)?.poll()
    let visible = visibleText(model, tabId: tabId)
    XCTAssertEqual(
      echoCommandCount(in: visible),
      expectedCommandCount,
      "\(context) has the wrong number of echo commands; visible=\(visible.debugDescription)",
      file: file,
      line: line)
    XCTAssertFalse(
      visible.contains("eecho hej"),
      "\(context) duplicated the first character; visible=\(visible.debugDescription)",
      file: file,
      line: line)
    XCTAssertFalse(
      visible.contains("%"),
      "\(context) rendered zsh PROMPT_SP marker; visible=\(visible.debugDescription)",
      file: file,
      line: line)
    XCTAssertFalse(
      visible.unicodeScalars.contains { $0.value == 0 },
      "\(context) rendered a NUL glyph; visible=\(visible.debugDescription)",
      file: file,
      line: line)
  }

  private func assertCleanEchoTranscript(
    _ store: PersistenceStore,
    tabId: String,
    expectedCommandCount: Int,
    context: String,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    let data = try Data(contentsOf: store.transcriptURL(forTabId: tabId))
    let transcript = String(decoding: data, as: UTF8.self)
    XCTAssertEqual(
      echoCommandCount(in: transcript),
      expectedCommandCount,
      "\(context) persisted the wrong number of echo commands",
      file: file,
      line: line)
    XCTAssertFalse(
      transcript.contains("eecho hej"),
      "\(context) persisted a duplicated command prefix",
      file: file,
      line: line)
    XCTAssertFalse(
      data.contains(0),
      "\(context) persisted a NUL byte",
      file: file,
      line: line)
  }

  private func echoCommandCount(in text: String) -> Int {
    occurrenceCount(of: "echo hej", in: text)
  }

  private func occurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var start = haystack.startIndex
    while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
      count += 1
      start = range.upperBound
    }
    return count
  }

  private func visibleText(_ model: AppModel, tabId: String) -> String {
    guard let session = model.session(forTab: tabId),
      let snap = session.snapshot()
    else {
      return ""
    }
    defer { laban_snapshot_destroy(snap) }
    return TerminalSnapshotText.visibleText(
      from: UnsafePointer(snap), mode: .trimmedNonEmptyRows)
  }

  private func assertVisible(
    _ model: AppModel, tabId: String, contains needle: String,
    file: StaticString = #file, line: UInt = #line
  ) {
    guard let session = model.session(forTab: tabId) else {
      XCTFail("no session for tab \(tabId)", file: file, line: line)
      return
    }
    guard let snap = session.snapshot() else {
      XCTFail("no snapshot for tab \(tabId)", file: file, line: line)
      return
    }
    defer { laban_snapshot_destroy(snap) }
    let text = TerminalSnapshotText.visibleText(
      from: UnsafePointer(snap), mode: .trimmedNonEmptyRows)
    XCTAssertTrue(
      text.contains(needle),
      "tab \(tabId) visible text does not contain \(needle.debugDescription); got: \(text.debugDescription)",
      file: file, line: line)
  }

  private func assertNotVisible(
    _ model: AppModel, tabId: String, contains needle: String,
    file: StaticString = #file, line: UInt = #line
  ) {
    guard let session = model.session(forTab: tabId) else {
      XCTFail("no session for tab \(tabId)", file: file, line: line)
      return
    }
    guard let snap = session.snapshot() else {
      XCTFail("no snapshot for tab \(tabId)", file: file, line: line)
      return
    }
    defer { laban_snapshot_destroy(snap) }
    let text = TerminalSnapshotText.visibleText(
      from: UnsafePointer(snap), mode: .trimmedNonEmptyRows)
    XCTAssertFalse(
      text.contains(needle),
      "tab \(tabId) visible text unexpectedly contains \(needle.debugDescription); got: \(text.debugDescription)",
      file: file, line: line)
  }
}
