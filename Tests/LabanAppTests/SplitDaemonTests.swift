import Foundation
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class SplitDaemonHarness {
  let root: URL
  let process: Process
  let client: LabptyTerminalSessionClient
  let model: AppModel
  let coordinator: AppSessionCoordinator
  let size: LabanTerminalSize

  init() throws {
    root = URL(fileURLWithPath: ".tmp/split-daemon-\(UUID().uuidString.prefix(8))")
    let shm = root.appendingPathComponent("shm")
    try FileManager.default.createDirectory(at: shm, withIntermediateDirectories: true)
    let socket = root.appendingPathComponent("s.sock").path
    process = Process()
    process.executableURL = URL(fileURLWithPath: ".build/debug/labpty")
    process.arguments = ["--socket", socket, "--shm-dir", shm.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(5)
    var connected: LabptyTerminalSessionClient?
    while Date() < deadline {
      if let c = try? LabptyTerminalSessionClient(socketPath: socket) {
        connected = c
        break
      }
      usleep(20_000)
    }
    guard let connected else {
      process.terminate()
      throw NSError(domain: "split-daemon", code: 1)
    }
    client = connected
    var grid = LabanTerminalSize()
    grid.rows = 24
    grid.cols = 100
    grid.cell_width = 8
    grid.cell_height = 16
    grid.pixel_width = 800
    grid.pixel_height = 384
    size = grid
    model = try AppModel(
      initialSize: grid,
      sessionFactory: { size, context in
        try Session.parserOnly(size: size, sessionID: context.sessionID)
      })
    coordinator = AppSessionCoordinator(
      labptyClient: client,
      shellLaunch: ShellIntegrationLaunch(argv: [
        "/bin/sh", "-c", "printf READY; exec /bin/sleep 60",
      ]))
    try coordinator.ensureSessions(for: model.tabs, in: model, size: grid)
  }
  func split() throws -> Tab {
    let tab = try XCTUnwrap(model.activeTab)
    _ = try model.splitPane(inTab: tab.id) { id, size, _ in
      let session = try Session.parserOnly(size: size, sessionID: id)
      let target = Tab(id: tab.id, position: 1, title: "Tab 1", isActive: true, sessionId: id)
      _ = try coordinator.ensureSession(for: target, session: session, size: size)
      return session
    }
    return try XCTUnwrap(model.activeTab)
  }
  deinit {
    for tab in model.tabs { coordinator.terminate(tab: tab) }
    coordinator.detach()
    model.closeAllSessions()
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: root)
  }
}

extension AppSessionCoordinatorTests {
  func testFirstSessionLogicalIdEqualsTabId() throws {
    let h = try SplitDaemonHarness()
    let tab = try XCTUnwrap(h.model.activeTab)
    XCTAssertEqual(tab.id, tab.focusedSessionId)
    XCTAssertEqual(h.coordinator.sessionInfo(for: tab)?.logicalSessionId, tab.id)
  }
  func testSplitTabOpensTwoDistinctLogicalSessions() throws {
    let h = try SplitDaemonHarness()
    let tab = try h.split()
    let sessions = try h.client.listLabptySessions().filter(\.alive)
    XCTAssertEqual(Set(sessions.map(\.logicalSessionId)), Set(tab.allSessionIds))
    XCTAssertEqual(Set(sessions.map(\.childPid)).count, 2)
  }
  func testBackgroundSplitRestoreDoesNotResizeDaemonPanesToFullWidth() throws {
    let h = try SplitDaemonHarness()
    let split = try h.split()
    _ = try h.model.createTab()
    try h.coordinator.ensureSessions(for: h.model.tabs, in: h.model, size: h.size)
    let persisted = h.model.snapshotForPersistence(windowId: "window")
    h.coordinator.detach()
    let restored = try AppModel(initialSize: h.size)
    restored.replaceTabs(from: persisted)
    let coordinator = AppSessionCoordinator(
      labptyClient: h.client,
      shellLaunch: ShellIntegrationLaunch(argv: ["/bin/sh"]))
    defer {
      coordinator.detach()
      restored.closeAllSessions()
    }
    try coordinator.ensureSessions(for: restored.tabs, in: restored, size: h.size)
    coordinator.resize(tabs: restored.tabs, in: restored, size: h.size)
    let sessions = try h.client.listLabptySessions()
    for id in split.allSessionIds {
      let descriptor = try XCTUnwrap(sessions.first { $0.logicalSessionId == id })
      XCTAssertEqual(Int(descriptor.cols), Int(restored.terminalSize(for: id).cols))
      XCTAssertLessThan(descriptor.cols, 51)
    }
  }

  func testResizeSendsDifferentSizesPerSession() throws {
    let h = try SplitDaemonHarness()
    let tab = try h.split()
    var left = h.size
    left.cols = 43
    var right = h.size
    right.cols = 57
    h.coordinator.resize(sizesBySession: [tab.allSessionIds[0]: left, tab.allSessionIds[1]: right])
    let deadline = Date().addingTimeInterval(3)
    var sessions = try h.client.listLabptySessions()
    while Date() < deadline
      && sessions.contains(where: {
        $0.logicalSessionId == tab.allSessionIds[0] && $0.cols != 43
          || $0.logicalSessionId == tab.allSessionIds[1] && $0.cols != 57
      })
    {
      usleep(20_000)
      sessions = try h.client.listLabptySessions()
    }
    XCTAssertEqual(sessions.first { $0.logicalSessionId == tab.allSessionIds[0] }?.cols, 43)
    XCTAssertEqual(sessions.first { $0.logicalSessionId == tab.allSessionIds[1] }?.cols, 57)
  }
}
