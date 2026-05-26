import Darwin
import Foundation
import LabanCore
import XCTest

final class LabandJournalTests: XCTestCase {
  private var launchedDaemon: Process?

  override func tearDown() {
    if let launchedDaemon, launchedDaemon.isRunning {
      launchedDaemon.terminate()
      launchedDaemon.waitUntilExit()
    }
    launchedDaemon = nil
    super.tearDown()
  }

  func testLifecycleJournalReplaysTerminatedSessionAndLeaseHistory() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-journal-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"

    var daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon
    let client = try waitForClient(root: root, socketPath: socketPath)
    defer { client.close() }

    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80
      )
    )
    try client.writeInput(sessionId: session.logicalSessionId, bytes: Array("journal-ok".utf8))
    _ = try waitForSnapshotText(
      client: client,
      sessionId: session.logicalSessionId,
      contains: "journal-ok"
    )

    let leased = try client.transferLease(
      sessionId: session.logicalSessionId,
      holderClientId: client.clientIdentifier
    )
    XCTAssertEqual(leased.leaseHolder, client.clientIdentifier)
    XCTAssertEqual(leased.leaseHistory.last?.leaseHolder, client.clientIdentifier)

    let terminated = try client.terminate(sessionId: session.logicalSessionId)
    XCTAssertEqual(terminated.lifecycleState, .terminated)
    let childPid = terminated.childPid

    try client.shutdownWhenIdle()
    daemon.waitUntilExit()
    XCTAssertEqual(daemon.terminationStatus, 0)
    launchedDaemon = nil

    let records = try readJournalRecords(journalPath: journalPath)
    XCTAssertTrue(records.map(\.event).contains("sessionCreated"))
    XCTAssertTrue(records.map(\.event).contains("leaseTransferred"))
    XCTAssertTrue(records.map(\.event).contains("terminateRequested"))
    XCTAssertTrue(records.map(\.event).contains("sessionTerminated"))
    XCTAssertEqual(records.map(\.offset), records.map(\.offset).sorted())
    for pair in zip(records, records.dropFirst()) {
      XCTAssertLessThan(pair.0.offset, pair.1.offset)
    }

    daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon
    let restarted = try waitForClient(root: root, socketPath: socketPath)
    defer { restarted.close() }

    let catalog = try restarted.listSessions()
    let replayed = try XCTUnwrap(catalog.first { $0.logicalSessionId == session.logicalSessionId })
    XCTAssertEqual(replayed.incarnationId, session.incarnationId)
    XCTAssertEqual(replayed.lifecycleState, .terminated)
    XCTAssertEqual(replayed.childPid, childPid)
    XCTAssertEqual(replayed.cwd, root.path)
    XCTAssertEqual(replayed.leaseHolder, client.clientIdentifier)
    XCTAssertEqual(replayed.leaseHistory.last?.leaseHolder, client.clientIdentifier)

    try restarted.shutdownWhenIdle()
    daemon.waitUntilExit()
    XCTAssertEqual(daemon.terminationStatus, 0)
    launchedDaemon = nil
  }

  private func launchDaemon(root: URL, socketPath: String, journalPath: String) throws -> Process {
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

  private func waitForClient(root: URL, socketPath: String) throws -> LabandTerminalSessionClient {
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

  private func waitForSnapshotText(
    client: TerminalSessionClient,
    sessionId: String,
    contains needle: String
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(5)
    var lastSnapshot: LabandSnapshotResponse?
    while Date() < deadline {
      let snapshot = try client.snapshot(sessionId: sessionId)
      lastSnapshot = snapshot
      if snapshot.visibleText.contains(needle) {
        return snapshot
      }
      usleep(50_000)
    }
    XCTFail("snapshot never contained \(needle); last=\(lastSnapshot?.visibleText ?? "<none>")")
    throw POSIXError(.ETIMEDOUT)
  }

  private struct JournalRecord: Decodable {
    var offset: UInt64
    var event: String
  }

  private func readJournalRecords(journalPath: String) throws -> [JournalRecord] {
    let url = URL(fileURLWithPath: journalPath).appendingPathComponent("lifecycle.jsonl")
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map { line in
      try JSONDecoder().decode(JournalRecord.self, from: Data(String(line).utf8))
    }
  }
}
