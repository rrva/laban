import Darwin
import Foundation
import LabanCore
import XCTest

/// Verifies that the laband daemon surfaces foreground-process metadata —
/// not just `childPid`/`foregroundPid`, but the human-readable
/// `foregroundCommand` / `foregroundArguments` / `foregroundCwd` strings
/// the app sidebar needs to show "claude" instead of "Tab 1" in
/// background-session mode.
final class LabandSessionMetadataTests: XCTestCase {
  private var launchedDaemon: Process?

  override func tearDown() {
    if let launchedDaemon, launchedDaemon.isRunning {
      launchedDaemon.terminate()
      launchedDaemon.waitUntilExit()
    }
    launchedDaemon = nil
    super.tearDown()
  }

  func testListSessionsExposesForegroundCommandMetadata() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-fg-meta-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let client = try waitForClient(root: root, socketPath: socketPath)
    defer { client.close() }

    // /bin/sh -c 'sleep 30' — a stable two-frame foreground tree: the
    // immediate child is `sh`, and `sleep` becomes the foreground process
    // group leader on the PTY. The daemon's process_metadata.c poll should
    // see the `sleep` command.
    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: ["/bin/sh", "-c", "sleep 30"],
        cwd: root.path,
        rows: 24,
        cols: 80
      )
    )
    defer {
      _ = try? client.terminate(sessionId: session.logicalSessionId)
    }

    // Give the daemon a moment to poll process metadata on `sleep`.
    let info = try waitForSessionForegroundCommand(
      client: client,
      logicalSessionId: session.logicalSessionId,
      contains: "sleep"
    )
    XCTAssertNotNil(info.foregroundPid, "foregroundPid should be populated")
    XCTAssertNotNil(
      info.foregroundCommand,
      "daemon must surface foregroundCommand so the sidebar can show it")
    if let cmd = info.foregroundCommand {
      XCTAssertTrue(
        cmd.contains("sleep"),
        "expected sleep in foregroundCommand, got \(cmd)")
    }
  }

  private func waitForSessionForegroundCommand(
    client: LabandTerminalSessionClient,
    logicalSessionId: String,
    contains needle: String
  ) throws -> LabandSessionInfo {
    let deadline = Date().addingTimeInterval(5)
    var lastInfo: LabandSessionInfo?
    while Date() < deadline {
      let infos = try client.listSessions()
      if let info = infos.first(where: { $0.logicalSessionId == logicalSessionId }) {
        lastInfo = info
        if let cmd = info.foregroundCommand, cmd.contains(needle) {
          return info
        }
      }
      usleep(100_000)
    }
    XCTFail(
      "session never reported foregroundCommand containing \(needle); last=\(String(describing: lastInfo?.foregroundCommand))"
    )
    throw POSIXError(.ETIMEDOUT)
  }

  private func launchDaemon(
    root: URL,
    socketPath: String,
    journalPath: String
  ) throws -> Process {
    let executable = root.appendingPathComponent(".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("build laband first: swift build --product laband")
    }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".tmp"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".artifacts/runs"),
      withIntermediateDirectories: true
    )
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--journal", journalPath]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
  }

  private func waitForClient(
    root: URL,
    socketPath: String
  ) throws -> LabandTerminalSessionClient {
    let absoluteSocketPath = root.appendingPathComponent(socketPath).path
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: absoluteSocketPath) {
        do {
          return try LabandTerminalSessionClient(socketPath: socketPath)
        } catch {
          lastError = error
        }
      }
      usleep(50_000)
    }
    if let lastError { throw lastError }
    XCTFail("laband socket did not appear at \(absoluteSocketPath)")
    throw POSIXError(.ETIMEDOUT)
  }
}
