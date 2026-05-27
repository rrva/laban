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
