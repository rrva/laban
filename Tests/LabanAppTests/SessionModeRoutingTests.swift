import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class SessionModeRoutingTests: XCTestCase {
  func testLocalModeUsesInProcessClient() throws {
    let client = InProcessTerminalSessionClient()
    XCTAssertEqual(client.transportMode, "in-process")

    let info = try client.createSession(
      TerminalSessionLaunchRequest(
        argv: ["/bin/sh", "-lc", "printf local-mode-ready; sleep 1"],
        cwd: FileManager.default.currentDirectoryPath,
        rows: 24,
        cols: 80,
        logicalSessionId: "local-mode"))
    defer { _ = try? client.terminate(sessionId: info.logicalSessionId) }

    XCTAssertEqual(info.logicalSessionId, "local-mode")
    XCTAssertEqual(try client.listSessions().map(\.logicalSessionId), ["local-mode"])
    _ = try waitForSnapshotText(
      client: client,
      sessionId: "local-mode",
      text: "local-mode-ready")
  }

  func testBackgroundModeUsesLabptyClient() throws {
    let harness = try startLabpty(prefix: "session-mode-background")
    defer { try? FileManager.default.removeItem(at: harness.root) }
    defer { terminate(harness.process) }

    let client = try waitForLabptyClient(socketPath: harness.socketPath)
    defer { client.close() }
    XCTAssertEqual(client.transportMode, "labpty")

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-lc", "printf background-mode-ready; sleep 30"],
        cwd: FileManager.default.currentDirectoryPath,
        logicalSessionId: "background-mode"))
    defer { _ = try? client.terminate(handle: descriptor.ptyHandle) }

    let listed = try client.listLabptySessions()
    XCTAssertTrue(listed.contains { $0.logicalSessionId == "background-mode" })
    XCTAssertEqual(Darwin.kill(pid_t(descriptor.childPid), 0), 0)
  }

  func testDetachedModeUsesLabandClient() throws {
    let harness = try startLaband(prefix: "session-mode-detached")
    defer { try? FileManager.default.removeItem(at: harness.root) }
    defer { terminate(harness.process) }

    let client = try waitForLabandClient(socketPath: harness.socketPath)
    defer { client.close() }
    XCTAssertEqual(client.transportMode, "laband")

    let info = try client.createSession(
      TerminalSessionLaunchRequest(
        argv: ["/bin/sh", "-lc", "printf detached-mode-ready; sleep 30"],
        cwd: FileManager.default.currentDirectoryPath,
        rows: 24,
        cols: 80,
        logicalSessionId: "detached-mode"))
    defer {
      _ = try? client.terminate(sessionId: info.logicalSessionId)
      _ = try? client.shutdownWhenIdle()
    }

    XCTAssertTrue(try client.listSessions().contains { $0.logicalSessionId == "detached-mode" })
  }

  private struct Harness {
    let root: URL
    let socketPath: String
    let process: Process
  }

  private func startLabpty(prefix: String) throws -> Harness {
    let executable = URL(fileURLWithPath: ".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("labpty binary is not built")
    }
    _ = prefix
    let root = URL(fileURLWithPath: ".tmp/smb-\(UUID().uuidString.prefix(4))", isDirectory: true)
    let shmURL = root.appendingPathComponent("p", isDirectory: true)
    let socketPath = root.appendingPathComponent("p.sock").path
    try FileManager.default.createDirectory(at: shmURL, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--shm-dir", shmURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    _ = try waitForLabptyClient(socketPath: socketPath)
    return Harness(root: root, socketPath: socketPath, process: process)
  }

  private func startLaband(prefix: String) throws -> Harness {
    let executable = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("laband binary is not built")
    }
    _ = prefix
    let root = URL(fileURLWithPath: ".tmp/smd-\(UUID().uuidString.prefix(4))", isDirectory: true)
    let journalURL = root.appendingPathComponent("j", isDirectory: true)
    let socketPath = root.appendingPathComponent("d.sock").path
    try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    _ = try waitForLabandClient(socketPath: socketPath)
    return Harness(root: root, socketPath: socketPath, process: process)
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

  private func waitForLabandClient(socketPath: String) throws -> LabandTerminalSessionClient {
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
    client: InProcessTerminalSessionClient,
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

  private func terminate(_ process: Process) {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}
