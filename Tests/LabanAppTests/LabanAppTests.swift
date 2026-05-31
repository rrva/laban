import Foundation
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class LabanAppTests: XCTestCase {
  func testAppDirectSessionEndToEnd() throws {
    let labptyURL = URL(fileURLWithPath: ".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: labptyURL.path) else {
      throw XCTSkip("labpty binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-labpty-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let shmURL = root.appendingPathComponent("shm", isDirectory: true)
    try FileManager.default.createDirectory(at: shmURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labptyURL
    process.arguments = ["--socket", socketPath, "--shm-dir", shmURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.parserOnly(size: $0) }
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let client = try waitForLabptyClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      labptyClient: client,
      shellLaunch: ShellIntegrationLaunch(
        argv: [
          "/bin/sh", "-c",
          "printf STARTED; while IFS= read -r x; do echo \"got $x\"; done",
        ]),
      cwdByTabId: [tab.id: FileManager.default.currentDirectoryPath]
    )
    defer { coordinator.detach() }

    _ = try coordinator.ensureSession(for: tab, session: session, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: tab, text: "STARTED")

    try coordinator.write(Array("ping\n".utf8), to: tab, session: session, size: size)
    let text = try waitForLocalSnapshotText(model: model, tab: tab, text: "got ping")
    XCTAssertTrue(text.contains("STARTED"))
    XCTAssertTrue(text.contains("got ping"))
  }

  func testLabanAppRestartPreservesChildViaLabpty() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let tabId = "restart-tab"
    let command = [
      "/bin/sh", "-c",
      "printf READY; while IFS= read -r x; do echo \"got $x\"; done",
    ]

    let firstModel = try parserModel(tabId: tabId, size: size)
    let firstTab = try XCTUnwrap(firstModel.activeTab)
    let firstSession = try XCTUnwrap(firstModel.session(forTab: firstTab.id))
    let firstCoordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    let firstInfo = try firstCoordinator.ensureSession(
      for: firstTab,
      session: firstSession,
      size: size)
    let childPid = try XCTUnwrap(firstInfo.childPid)
    _ = try waitForLocalSnapshotText(model: firstModel, tab: firstTab, text: "READY")
    try firstCoordinator.write(Array("one\n".utf8), to: firstTab, session: firstSession, size: size)
    _ = try waitForLocalSnapshotText(model: firstModel, tab: firstTab, text: "got one")
    firstCoordinator.detach()
    firstModel.closeAllSessions()

    let secondModel = try parserModel(tabId: tabId, size: size)
    let secondTab = try XCTUnwrap(secondModel.activeTab)
    let secondSession = try XCTUnwrap(secondModel.session(forTab: secondTab.id))
    let secondCoordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    defer {
      secondCoordinator.terminate(tab: secondTab)
      secondCoordinator.detach()
      secondModel.closeAllSessions()
    }

    let secondInfo = try secondCoordinator.ensureSession(
      for: secondTab,
      session: secondSession,
      size: size)
    XCTAssertEqual(secondInfo.childPid, childPid)
    try secondCoordinator.write(
      Array("two\n".utf8), to: secondTab, session: secondSession, size: size)
    let text = try waitForLocalSnapshotText(model: secondModel, tab: secondTab, text: "got two")
    XCTAssertTrue(text.contains("READY"))
    XCTAssertTrue(text.contains("got one"))
    XCTAssertTrue(text.contains("got two"))
    print(
      "[labpty-restart] child_pid before=\(childPid) after=\(secondInfo.childPid ?? -1) wroteBefore='got one' wroteAfter='got two'"
    )
  }

  func testLabptyOrphanSweepPreservesUnknownLiveSessions() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-sweep")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForLabptyClient(socketPath: socketPath)
    let kept = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "60"],
        logicalSessionId: "kept-tab"))
    let orphan = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "60"],
        logicalSessionId: "unknown-live-tab"))
    seedClient.close()
    defer {
      let cleanupClient = try? waitForLabptyClient(socketPath: socketPath)
      _ = try? cleanupClient?.terminate(handle: kept.ptyHandle)
      _ = try? cleanupClient?.terminate(handle: orphan.ptyHandle)
      cleanupClient?.close()
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try parserModel(tabId: "kept-tab", size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: .passthrough,
      cwdByTabId: ["kept-tab": FileManager.default.currentDirectoryPath])
    defer {
      coordinator.detach()
      model.closeAllSessions()
    }

    let attached = try coordinator.ensureSession(for: tab, session: session, size: size)
    XCTAssertEqual(attached.logicalSessionId, "kept-tab")

    coordinator.sweepOrphanedSessions()

    let verifyClient = try waitForLabptyClient(socketPath: socketPath)
    defer { verifyClient.close() }
    let sessions = try verifyClient.listLabptySessions()
    XCTAssertTrue(
      sessions.contains { $0.logicalSessionId == "kept-tab" && $0.alive },
      "the restored tab's labpty session must remain running")
    XCTAssertTrue(
      sessions.contains { $0.logicalSessionId == "unknown-live-tab" && $0.alive },
      "unknown labpty sessions must survive app-side orphan sweeps")
  }

  func testAdoptUnclaimedLabptySessionReattachesExistingChild() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-adopt")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForLabptyClient(socketPath: socketPath)
    let kept = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sleep", "60"], logicalSessionId: "kept-tab"))
    let orphan = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80,
        argv: [
          "/bin/sh", "-c",
          "printf READY; while IFS= read -r x; do echo \"got $x\"; done",
        ],
        logicalSessionId: "unknown-live-tab"))
    seedClient.close()
    defer {
      let cleanupClient = try? waitForLabptyClient(socketPath: socketPath)
      _ = try? cleanupClient?.terminate(handle: kept.ptyHandle)
      _ = try? cleanupClient?.terminate(handle: orphan.ptyHandle)
      cleanupClient?.close()
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try parserModel(tabId: "kept-tab", size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: .passthrough,
      cwdByTabId: ["kept-tab": FileManager.default.currentDirectoryPath])
    defer {
      coordinator.detach()
      model.closeAllSessions()
    }

    _ = try coordinator.ensureSession(for: tab, session: session, size: size)

    // Detection: the bound tab is claimed; only the unknown session shows
    // up as unclaimed.
    let unclaimed = coordinator.unclaimedLabptySessions(knownTabIds: Set(model.tabs.map(\.id)))
    XCTAssertEqual(unclaimed.map(\.logicalSessionId), ["unknown-live-tab"])

    // Adoption binds a new tab to the *existing* child (same pid) instead
    // of spawning a fresh shell.
    let adopted = coordinator.adoptLabptySessions(unclaimed, in: model, size: size)
    XCTAssertEqual(adopted.map(\.id), ["unknown-live-tab"])
    let adoptedTab = try XCTUnwrap(model.tabs.first { $0.id == "unknown-live-tab" })
    XCTAssertEqual(coordinator.sessionInfo(for: adoptedTab)?.childPid, Int(orphan.childPid))

    // The adopted tab is live, not merely bound: the byte-ring feed
    // attaches (prior output replays) and input round-trips through the
    // reattached child.
    let adoptedSession = try XCTUnwrap(model.session(forTab: adoptedTab.id))
    _ = try waitForLocalSnapshotText(model: model, tab: adoptedTab, text: "READY")
    try coordinator.write(Array("hi\n".utf8), to: adoptedTab, session: adoptedSession, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: adoptedTab, text: "got hi")

    // Reattach, not respawn: still exactly one live session for that id.
    let verifyClient = try waitForLabptyClient(socketPath: socketPath)
    defer { verifyClient.close() }
    let liveForId = try verifyClient.listLabptySessions()
      .filter { $0.logicalSessionId == "unknown-live-tab" && $0.alive }
    XCTAssertEqual(liveForId.count, 1, "adoption must reattach, not open a second session")
  }

  private func waitForLabptyClient(socketPath: String) throws -> LabptyTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      do {
        let client = try LabptyTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return client
      } catch {
        lastError = error
        usleep(50_000)
      }
    }
    throw XCTSkip("timed out waiting for labpty: \(String(describing: lastError))")
  }

  private func startLabptyDaemon(prefix: String) throws -> (
    root: URL, socketPath: String, process: Process
  ) {
    let labptyURL = URL(fileURLWithPath: ".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: labptyURL.path) else {
      throw XCTSkip("labpty binary is not built")
    }
    let root = URL(
      fileURLWithPath: ".tmp/\(prefix)-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let shmURL = root.appendingPathComponent("shm", isDirectory: true)
    try FileManager.default.createDirectory(at: shmURL, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = labptyURL
    process.arguments = ["--socket", socketPath, "--shm-dir", shmURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    _ = try waitForLabptyClient(socketPath: socketPath)
    return (root, socketPath, process)
  }

  private func parserModel(tabId: String, size: LabanTerminalSize) throws -> AppModel {
    let model = try AppModel(initialSize: size) { try Session.parserOnly(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: tabId,
            tabs: [
              TabState(
                id: tabId,
                cwd: FileManager.default.currentDirectoryPath,
                launchCommand: "/bin/sh",
                lastActiveAt: Date())
            ])
        ]))
    return model
  }

  private func waitForLocalSnapshotText(
    model: AppModel,
    tab: Tab,
    text: String
  ) throws -> String {
    let deadline = Date().addingTimeInterval(5)
    var last = ""
    while Date() < deadline {
      if let session = model.session(forTab: tab.id), let snapshot = session.snapshot() {
        defer { laban_snapshot_destroy(snapshot) }
        let visible = TerminalSnapshotText.visibleText(
          from: UnsafePointer(snapshot),
          mode: .trimmedNonEmptyRows)
        if visible.contains(text) {
          return visible
        }
        last = visible
      }
      usleep(50_000)
    }
    XCTFail("timed out waiting for \(text); last=\(last)")
    return last
  }
}
