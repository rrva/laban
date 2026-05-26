import Foundation
import LabanCore
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
}
