import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class AppLabandSessionCoordinatorTests: XCTestCase {
  func testRestoredAppTabAttachesExistingDaemonSession() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForClient(socketPath: socketPath)
    let seed = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: ["/bin/sh", "-lc", "printf app-laband-existing-ready; sleep 60"],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "top-tab"
      ))
    _ = try seedClient.detachSession(sessionId: seed.logicalSessionId)
    seedClient.close()

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "top-tab",
            tabs: [
              TabState(
                id: "top-tab",
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                launchCommand: "top",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try LabandTerminalSessionClient(socketPath: socketPath)
    let coordinator = AppLabandSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: ["top-tab": FileManager.default.homeDirectoryForCurrentUser.path]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    let attached = try coordinator.ensureSession(for: tab, size: size)
    XCTAssertEqual(attached.logicalSessionId, seed.logicalSessionId)
    XCTAssertEqual(attached.incarnationId, seed.incarnationId)
    XCTAssertEqual(attached.childPid, seed.childPid)

    let snapshot = try waitForSnapshotText(
      coordinator: coordinator,
      tab: tab,
      size: size,
      text: "app-laband-existing-ready")
    XCTAssertEqual(snapshot.logicalSessionId, "top-tab")

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "top-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  func testRestoredAppTabReappliesCurrentThemeToExistingDaemonSession() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let previousTheme = Theme.current
    let previousFollowsSystem = Theme.followsSystemAppearance
    defer {
      Theme.current = previousTheme
      Theme.followsSystemAppearance = previousFollowsSystem
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-theme-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForClient(socketPath: socketPath)
    let seed = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "theme-tab"
      ))
    try seedClient.writeInput(sessionId: seed.logicalSessionId, bytes: Array("t".utf8))
    _ = try waitForSnapshotText(
      client: seedClient,
      sessionId: seed.logicalSessionId,
      text: "t")
    try seedClient.applyTheme(
      sessionId: seed.logicalSessionId,
      paletteBytes: ThemePaletteInjector.paletteBytes(for: Theme.selenizedDark),
      colorScheme: .dark)
    _ = try seedClient.detachSession(sessionId: seed.logicalSessionId)
    seedClient.close()

    Theme.current = Theme.selenizedLight
    Theme.followsSystemAppearance = false

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "theme-tab",
            tabs: [
              TabState(
                id: "theme-tab",
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                launchCommand: "cat",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try LabandTerminalSessionClient(socketPath: socketPath)
    let coordinator = AppLabandSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: ["theme-tab": FileManager.default.homeDirectoryForCurrentUser.path]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    _ = try coordinator.ensureSession(for: tab, size: size)
    let snapshot = try waitForSnapshotText(
      coordinator: coordinator,
      tab: tab,
      size: size,
      text: "t")
    let themedCell = try XCTUnwrap(snapshot.cells.first { $0.text == "t" })
    XCTAssertEqual(themedCell.foregroundRGBA, Theme.selenizedLight.fg0)
    XCTAssertEqual(themedCell.backgroundRGBA, Theme.selenizedLight.bg0)

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "theme-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  private func waitForClient(socketPath: String) throws -> LabandTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      do {
        let client = try LabandTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return client
      } catch {
        lastError = error
        usleep(50_000)
      }
    }
    throw XCTSkip("timed out waiting for laband: \(String(describing: lastError))")
  }

  private func waitForSnapshotText(
    coordinator: AppLabandSessionCoordinator,
    tab: Tab,
    size: LabanTerminalSize,
    text: String
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(5)
    var last: LabandSnapshotResponse?
    while Date() < deadline {
      let snapshot = try coordinator.snapshot(for: tab, size: size)
      if snapshot.visibleText.contains(text) {
        return snapshot
      }
      last = snapshot
      usleep(50_000)
    }
    XCTFail("timed out waiting for \(text); last=\(last?.visibleText ?? "")")
    return try XCTUnwrap(last)
  }

  private func waitForSnapshotText(
    client: LabandTerminalSessionClient,
    sessionId: String,
    text: String
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(5)
    var last: LabandSnapshotResponse?
    while Date() < deadline {
      let snapshot = try client.snapshot(sessionId: sessionId)
      if snapshot.visibleText.contains(text) {
        return snapshot
      }
      last = snapshot
      usleep(50_000)
    }
    XCTFail("timed out waiting for \(text); last=\(last?.visibleText ?? "")")
    return try XCTUnwrap(last)
  }
}
