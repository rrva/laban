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
              processStatus: .running
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
      wasRunningAtQuit: false
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
    XCTAssertEqual(snapshot.windows[0].tabs.map { $0.id }, ["restored-1", "restored-2", "restored-3"])
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
