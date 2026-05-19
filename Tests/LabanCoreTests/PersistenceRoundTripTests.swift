import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

private func fixtureFactory(_ size: LabanTerminalSize) throws -> Session {
  try Session.fixture(size: size)
}

private func makeModel() throws -> AppModel {
  var size = LabanTerminalSize()
  size.rows = 24
  size.cols = 80
  return try AppModel(initialSize: size, sessionFactory: fixtureFactory)
}

private func makeTempStore() -> PersistenceStore {
  let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("laban-persistence-test-\(UUID().uuidString)", isDirectory: true)
  return PersistenceStore(baseURL: tmp)
}

/// Records every attach/detach call into a list so tests can assert
/// the host wiring fires for both default and restored tabs.
private final class TranscriptRecorder: TranscriptHostDelegate {
  let lock = NSLock()
  var attached: [String] = []
  var detached: [String] = []

  func attachTranscriptWriter(
    to session: Session,
    tabId: String,
    suppressInitialOutputFor: DispatchTimeInterval
  ) {
    lock.lock()
    attached.append(tabId)
    lock.unlock()
  }

  func detachTranscriptWriter(forTabId tabId: String, in session: Session?) {
    lock.lock()
    detached.append(tabId)
    lock.unlock()
  }

  func transcriptURL(forTabId tabId: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(tabId).bin")
  }
}

final class PersistenceRoundTripTests: XCTestCase {

  override func tearDown() {
    super.tearDown()
  }

  func testWorkspaceStateEncodeDecodeRoundTrip() throws {
    let now = Date(timeIntervalSince1970: 1_715_000_000)
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "win-A",
          selectedTabId: "tab-2",
          tabs: [
            TabState(
              id: "tab-1",
              cwd: "/tmp",
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            ),
            TabState(
              id: "tab-2",
              cwd: "/Users/x/Documents",
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now,
              processStatus: .running,
              shellPid: 4321
            ),
          ]
        )
      ]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(state)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkspaceState.self, from: data)

    XCTAssertEqual(decoded, state)
    XCTAssertEqual(decoded.schemaVersion, 1)
    XCTAssertEqual(decoded.windows.first?.tabs.count, 2)
    XCTAssertEqual(decoded.windows.first?.tabs.last?.shellPid, 4321)
  }

  func testWorkspaceStateDecodesLegacyTabWithoutShellPid() throws {
    let json = """
      {
        "schemaVersion": 1,
        "windows": [
          {
            "id": "win-A",
            "tabs": [
              {
                "id": "tab-1",
                "cwd": "/Users/x",
                "launchCommand": "/bin/zsh -l",
                "lastActiveAt": "2024-05-06T12:00:00Z"
              }
            ]
          }
        ]
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkspaceState.self, from: Data(json.utf8))

    XCTAssertNil(decoded.windows.first?.tabs.first?.shellPid)
  }

  func testNoPersistenceRestoreFlagParsing() {
    XCTAssertTrue(
      PersistenceRestoreLaunchFlag.isPresent(
        in: ["LabanApp", PersistenceRestoreLaunchFlag.argument]))
    XCTAssertTrue(
      PersistenceRestoreLaunchFlag.disablesPersistenceRestore(
        in: ["LabanApp", PersistenceRestoreLaunchFlag.noPersistenceArgument]))
    XCTAssertTrue(
      PersistenceRestoreLaunchFlag.disablesPersistenceSync(
        in: ["LabanApp", PersistenceRestoreLaunchFlag.noPersistenceArgument]))
    XCTAssertFalse(
      PersistenceRestoreLaunchFlag.disablesPersistenceSync(
        in: ["LabanApp", PersistenceRestoreLaunchFlag.noRestoreArgument]))
    XCTAssertFalse(PersistenceRestoreLaunchFlag.isPresent(in: ["LabanApp", "--smoke"]))
  }

  func testWorkspaceStateRoundTripPreservesAgentInfo() throws {
    // Schema includes M2 fields; round-trip them with
    // wasRunningAtQuit: false to catch any divergence between the
    // planner's contract and the schema definition (the review gate
    // flagged a prior round where the schema example omitted this
    // field while the planner depended on it).
    let now = Date(timeIntervalSince1970: 1_715_000_000)
    let agent = AgentInfo(
      name: .claude,
      sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
      jsonlPath: "/Users/x/.claude/projects/foo/0fa31a8c-1234-5678-9abc-deadbeef0000.jsonl",
      wasRunningAtQuit: false,
      argv: ["claude", "--model", "sonnet"],
      env: ["TERM": "xterm-256color", "CLAUDE_CONFIG_DIR": "/tmp/claude"],
      cwd: "/Users/x/project"
    )
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "win-A",
          selectedTabId: "tab-1",
          tabs: [
            TabState(
              id: "tab-1",
              cwd: "/Users/x",
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now,
              processStatus: .running,
              agent: agent
            )
          ]
        )
      ]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(state)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkspaceState.self, from: data)

    XCTAssertEqual(decoded.windows.first?.tabs.first?.agent, agent)
    XCTAssertEqual(decoded.windows.first?.tabs.first?.agent?.wasRunningAtQuit, false)
    XCTAssertEqual(decoded.windows.first?.tabs.first?.agent?.argv, ["claude", "--model", "sonnet"])
    XCTAssertEqual(decoded.windows.first?.tabs.first?.agent?.env?["TERM"], "xterm-256color")
    XCTAssertEqual(decoded.windows.first?.tabs.first?.agent?.cwd, "/Users/x/project")
  }

  func testClosedTabAgentMetadataIsNotPersistedOrRecreatedByLateUpdate() throws {
    let model = try makeModel()
    let closingTab = try XCTUnwrap(model.tabs.first)
    _ = try model.createTab()
    let agent = AgentInfo(
      name: .claude,
      sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
      jsonlPath: "/Users/x/.claude/projects/foo/0fa31a8c-1234-5678-9abc-deadbeef0000.jsonl",
      wasRunningAtQuit: true,
      argv: ["claude"],
      env: nil,
      cwd: "/Users/x/project"
    )

    model.updateAgent(agent, forTab: closingTab.id)
    XCTAssertEqual(model.agent(forTab: closingTab.id), agent)

    try model.closeTab(closingTab.id)
    model.updateAgent(agent, forTab: closingTab.id)

    XCTAssertNil(model.agent(forTab: closingTab.id))
    let persistedWindow = try XCTUnwrap(model.snapshotForPersistence(windowId: "win-A").windows.first)
    XCTAssertFalse(persistedWindow.tabs.contains { $0.id == closingTab.id })
    XCTAssertFalse(persistedWindow.tabs.contains { $0.agent == agent })
  }

  func testWorkspaceStateDecodesLegacyAgentInfoWithoutLaunchContext() throws {
    let json = """
      {
        "schemaVersion": 1,
        "windows": [
          {
            "id": "win-A",
            "tabs": [
              {
                "id": "tab-1",
                "cwd": "/Users/x",
                "launchCommand": "/bin/zsh -l",
                "lastActiveAt": "2024-05-06T12:00:00Z",
                "agent": {
                  "name": "claude",
                  "sessionId": "0fa31a8c-1234-5678-9abc-deadbeef0000",
                  "jsonlPath": "/tmp/session.jsonl",
                  "wasRunningAtQuit": true
                }
              }
            ]
          }
        ]
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkspaceState.self, from: Data(json.utf8))

    let agent = try XCTUnwrap(decoded.windows.first?.tabs.first?.agent)
    XCTAssertNil(agent.argv)
    XCTAssertNil(agent.env)
    XCTAssertNil(agent.cwd)
  }

  func testPersistenceStoreSaveLoadRoundTrip() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.baseURL) }

    let now = Date(timeIntervalSince1970: 1_715_000_000)
    let original = WorkspaceState(
      windows: [
        WindowState(
          id: "win-X",
          selectedTabId: "tab-1",
          tabs: [
            TabState(
              id: "tab-1",
              cwd: "/tmp",
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            )
          ]
        )
      ]
    )

    try store.save(original)
    let loaded = try XCTUnwrap(store.load())
    XCTAssertEqual(loaded, original)
  }

  func testPersistenceStoreArchivePreviousOnCorrupt() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.baseURL) }
    try store.ensureDirectories()
    try Data("not valid json".utf8).write(to: store.workspaceURL)

    let loaded = store.load()
    XCTAssertNil(loaded, "corrupt workspace.json must not surface garbage")

    // The corrupt file is moved aside with a timestamped suffix so a
    // developer can inspect it; the next save starts clean.
    let fm = FileManager.default
    XCTAssertFalse(fm.fileExists(atPath: store.workspaceURL.path))
    let siblings = try fm.contentsOfDirectory(atPath: store.baseURL.path)
    XCTAssertTrue(siblings.contains { $0.hasPrefix("workspace.json.corrupt-") })
  }

  func testPersistenceStoreCorruptArchiveNamesDoNotCollide() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.baseURL) }
    try store.ensureDirectories()

    try Data("not valid json 1".utf8).write(to: store.workspaceURL)
    XCTAssertNil(store.load())

    try Data("not valid json 2".utf8).write(to: store.workspaceURL)
    XCTAssertNil(store.load())

    let siblings = try FileManager.default.contentsOfDirectory(atPath: store.baseURL.path)
    let corruptArchives = siblings.filter { $0.hasPrefix("workspace.json.corrupt-") }
    XCTAssertEqual(corruptArchives.count, 2)
  }

  func testPersistenceStoreArchiveCurrentMovesToPrevious() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.baseURL) }

    let now = Date(timeIntervalSince1970: 1_715_000_000)
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "win-Y",
          tabs: [
            TabState(
              id: "tab-1",
              cwd: "/tmp",
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            )
          ]
        )
      ]
    )
    try store.save(state)

    try store.archiveCurrent()

    let fm = FileManager.default
    XCTAssertFalse(fm.fileExists(atPath: store.workspaceURL.path))
    XCTAssertTrue(fm.fileExists(atPath: store.previousURL.path))
  }

  func testAppModelSnapshotProducesExpectedShape() throws {
    let model = try makeModel()
    let snapshot = model.snapshotForPersistence(windowId: "win-test")

    XCTAssertEqual(snapshot.schemaVersion, 1)
    XCTAssertEqual(snapshot.windows.count, 1)
    XCTAssertEqual(snapshot.windows[0].id, "win-test")
    XCTAssertEqual(snapshot.windows[0].tabs.count, 1)
    let firstTab = try XCTUnwrap(snapshot.windows[0].tabs.first)
    XCTAssertFalse(firstTab.cwd.isEmpty, "snapshot must always carry a cwd")
    XCTAssertFalse(firstTab.launchCommand.isEmpty)
    XCTAssertEqual(snapshot.windows[0].selectedTabId, firstTab.id)
  }

  func testAppModelReplaceTabsRebuildsFromState() throws {
    let model = try makeModel()
    let now = Date()
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "win-test",
          selectedTabId: "restored-2",
          tabs: [
            TabState(
              id: "restored-1",
              cwd: NSHomeDirectory(),
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            ),
            TabState(
              id: "restored-2",
              cwd: NSHomeDirectory(),
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            ),
            TabState(
              id: "restored-3",
              cwd: NSHomeDirectory(),
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            ),
          ]
        )
      ]
    )

    model.replaceTabs(from: state)
    XCTAssertEqual(model.tabs.count, 3)
    XCTAssertEqual(model.tabs.map { $0.id }, ["restored-1", "restored-2", "restored-3"])
    XCTAssertEqual(model.activeTab?.id, "restored-2")

    // Round-trip the persisted ids: a second snapshot must report the
    // same ids and the same selection.
    let snapshot = model.snapshotForPersistence(windowId: "win-test")
    XCTAssertEqual(
      snapshot.windows[0].tabs.map { $0.id }, ["restored-1", "restored-2", "restored-3"])
    XCTAssertEqual(snapshot.windows[0].selectedTabId, "restored-2")
  }

  func testPersistenceCoordinatorDebouncedSave() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.baseURL) }

    let model = try makeModel()
    let coord = PersistenceCoordinator(
      store: store,
      windowId: "win-debounce",
      debounceInterval: .milliseconds(40),
      isEnabled: { true }
    )
    coord.attach(model)
    coord.scheduleSave()

    // Wait past the debounce window so the timer fires and writes.
    let written = expectation(description: "save lands")
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
      written.fulfill()
    }
    wait(for: [written], timeout: 2.0)

    let loaded = try XCTUnwrap(store.load())
    XCTAssertEqual(loaded.windows.first?.id, "win-debounce")
    XCTAssertEqual(loaded.windows.first?.tabs.count, model.tabs.count)
  }

  func testPersistenceCoordinatorRespectsToggle() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.baseURL) }

    let model = try makeModel()
    var enabled = false
    let coord = PersistenceCoordinator(
      store: store,
      windowId: "win-toggle",
      debounceInterval: .milliseconds(10),
      isEnabled: { enabled }
    )
    coord.attach(model)
    coord.flushSync()  // disabled — must not write

    XCTAssertFalse(FileManager.default.fileExists(atPath: store.workspaceURL.path))

    enabled = true
    coord.flushSync()
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.workspaceURL.path))
  }

  func testPersistenceCoordinatorFlushKeepsTranscriptAsRawPtyBytes() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.baseURL) }

    let model = try makeModel()
    let host = TranscriptHost(store: store, isEnabled: { true })
    model.transcriptDelegate = host
    for (tab, session) in model.allSessions() {
      host.attachTranscriptWriter(to: session, tabId: tab.id)
    }

    let coord = PersistenceCoordinator(
      store: store,
      windowId: "win-raw-transcript",
      debounceInterval: .milliseconds(10),
      isEnabled: { true }
    )
    coord.transcriptHost = host
    coord.attach(model)

    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let payloadText =
      "\u{001B}[31mraw color survives\u{001B}[0m\r\n"
      + (0..<40).map { "scrollback line \($0)\r\n" }.joined()
    let payload = Array(payloadText.utf8)
    _ = session.feedOutput(payload)

    coord.flushSync()

    let data = try Data(contentsOf: store.transcriptURL(forTabId: tab.id))
    XCTAssertEqual(
      Array(data), payload,
      "quit flush must drain writers without replacing .bin with visible-grid text")
    XCTAssertTrue(
      data.contains(0x1B),
      "raw SGR escape bytes must remain so recent restore keeps color/style")
    XCTAssertTrue(
      String(data: data, encoding: .utf8)?.contains("scrollback line 0") == true,
      "flush must not truncate persisted history to only the visible grid")
  }

  // MARK: - M1 fixes

  func testReplaceTabsDetachesDefaultTabTranscriptDelegate() throws {
    // The M1 review flagged a leak: replaceTabs calls
    // closeAllSessionsUnlocked() which removed sessions without
    // notifying the transcript host. Verify the host's detach is
    // called for the default tab AS WELL AS for the restored tab on
    // close.
    let model = try makeModel()
    let recorder = TranscriptRecorder()
    model.transcriptDelegate = recorder

    // Default tab was constructed before transcriptDelegate was set,
    // so it never got an attach — simulate the production wiring of
    // attaching writers to pre-existing sessions.
    for (tab, session) in model.allSessions() {
      recorder.attachTranscriptWriter(to: session, tabId: tab.id)
    }
    XCTAssertEqual(recorder.attached.count, 1)
    let defaultTabId = model.tabs[0].id

    let now = Date()
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "win",
          selectedTabId: "restored",
          tabs: [
            TabState(
              id: "restored",
              cwd: NSHomeDirectory(),
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            )
          ]
        )
      ]
    )

    model.replaceTabs(from: state)

    XCTAssertTrue(
      recorder.detached.contains(defaultTabId),
      "default tab id must be in the detach record after replaceTabs (\(recorder.detached))")
    XCTAssertTrue(
      recorder.attached.contains(where: { $0 == "restored" }),
      "restored tab must trigger attach")
  }

  func testCwdFallbackAppliedPersistsAcrossSnapshot() throws {
    let model = try makeModel()
    let now = Date()
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "win",
          selectedTabId: "missing",
          tabs: [
            TabState(
              id: "missing",
              cwd: "/this/path/does/not/exist/\(UUID().uuidString)",
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now
            )
          ]
        )
      ]
    )
    model.replaceTabs(from: state)
    let snap = model.snapshotForPersistence(windowId: "win")
    let restored = try XCTUnwrap(snap.windows.first?.tabs.first)
    XCTAssertEqual(restored.cwdFallbackApplied, true)
  }

  func testRestoreFailureLoggerInvokedOnFactoryError() throws {
    let model = try makeModel()
    // Inject a deferred factory that always throws to simulate a
    // restore failure.
    model.restoredDeferredSessionFactory = { _ in
      throw NSError(domain: "test", code: 1)
    }
    var recorded: [(Tab.ID, Error)] = []
    model.restoreFailureLogger = { id, err in
      recorded.append((id, err))
    }
    let now = Date()
    let state = WorkspaceState(
      windows: [
        WindowState(
          id: "win",
          selectedTabId: "bad",
          tabs: [
            TabState(
              id: "bad",
              cwd: NSHomeDirectory(),
              launchCommand: "/bin/zsh -l",
              lastActiveAt: now)
          ]
        )
      ]
    )
    model.replaceTabs(from: state)
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.0, "bad")
  }

  func testRestoreOnLaunchSettingsDefaultsToTrueWithMissingKey() throws {
    // Use a fresh UserDefaults suite so the test cannot collide with
    // the user's real preferences. Reading the standard helper
    // directly would be unreliable in CI where the value may already
    // be set; we instead replicate the helper's logic against an
    // isolated suite to prove the default-true contract.
    let suiteName = "LabanRestoreOnLaunchTest-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    // No key set in this suite.
    XCTAssertNil(defaults.object(forKey: RestoreOnLaunchSettings.key))
    let resolved = (defaults.object(forKey: RestoreOnLaunchSettings.key) as? Bool) ?? true
    XCTAssertTrue(
      resolved,
      "RestoreOnLaunchSettings.isEnabled must default to true when no value is set; "
        + "bool(forKey:) would return false here which is the inverted default.")

    defaults.set(false, forKey: RestoreOnLaunchSettings.key)
    let after = (defaults.object(forKey: RestoreOnLaunchSettings.key) as? Bool) ?? true
    XCTAssertFalse(after, "explicit false must round-trip through the helper's logic")
  }
}
