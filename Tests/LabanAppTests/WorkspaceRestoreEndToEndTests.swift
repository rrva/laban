import Darwin
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Multi-cycle quit/restore tests that exercise the production
/// wiring chain (AppModel + PersistenceCoordinator + TranscriptHost +
/// deferred-spawn factory + TranscriptRenderer) end-to-end without
/// AppKit. Each cycle:
///   1. Tears down the prior "session" (drops Swift refs, lets
///      persistence flush).
///   2. Constructs a fresh AppModel against the same persistence
///      directory.
///   3. Loads `workspace.json` and calls `replaceTabs(from:)`.
///   4. Asserts the new AppModel's tabs match what the prior session
///      saved.
///   5. Asserts per-tab transcript files exist and replay produces
///      the expected text.
///
/// Three back-to-back cycles catch regressions where the persistence
/// path works once but corrupts state on the second relaunch.
final class WorkspaceRestoreEndToEndTests: XCTestCase {

  private struct Harness {
    let baseDir: URL
    let model: AppModel
    let coordinator: PersistenceCoordinator
    let transcriptHost: TranscriptHost
  }

  /// Build the same wiring `MainWindowController.makeAndShow` uses,
  /// minus the AppKit window. Fixture sessions instead of real
  /// shells so the test is fast and deterministic.
  private func makeHarness(
    baseDir: URL,
    restoring restoredState: WorkspaceState? = nil
  ) throws -> Harness {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(
      initialSize: size,
      sessionFactory: { try Session.fixture(size: $0) })

    let transcriptHost = TranscriptHost(
      store: PersistenceStore(baseURL: baseDir),
      isEnabled: { true })
    model.transcriptDelegate = transcriptHost
    // Deferred factory used by replaceTabs(from:). Replays the
    // transcript into a fresh fixture session, then "starts" it
    // (no-op for fixture mode but the call matches production).
    model.restoredDeferredSessionFactory = { spec in
      let session = try Session.fixture(size: spec.size)
      if let url = spec.transcriptURL {
        TranscriptRenderer.render(
          fileURL: url,
          into: session,
          altBufferAtQuit: spec.altBufferAtQuit)
      }
      return session
    }

    // Attach writers to the default tab created by AppModel.init.
    for (tab, session) in model.allSessions() {
      transcriptHost.attachTranscriptWriter(to: session, tabId: tab.id)
    }

    if let restoredState, !restoredState.windows.isEmpty {
      model.replaceTabs(from: restoredState)
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

    // Each restored session's libghostty grid must contain the
    // prior content (the renderer replayed the bin file).
    assertVisible(
      harness1.model, tabId: defaultTabId, contains: "default tab content")
    assertVisible(
      harness1.model, tabId: tab1Id, contains: "tab one content")
    assertVisible(
      harness1.model, tabId: tab2Id, contains: "tab two content")

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
    // Original content + new content should BOTH be visible in
    // tab1's restored grid (the transcript file accumulated both).
    assertVisible(harness2.model, tabId: tab1Id, contains: "tab one content")
    assertVisible(harness2.model, tabId: tab1Id, contains: "tab one AFTER restore")
    assertVisible(harness2.model, tabId: tab3Id, contains: "tab three NEW content")

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

  // MARK: - Helpers

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
}
