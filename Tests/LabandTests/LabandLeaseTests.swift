import Darwin
import Foundation
import LabanCore
import XCTest

final class LabandLeaseTests: XCTestCase {
  private var launchedDaemon: Process?

  override func tearDown() {
    if let launchedDaemon, launchedDaemon.isRunning {
      launchedDaemon.terminate()
      launchedDaemon.waitUntilExit()
    }
    launchedDaemon = nil
    super.tearDown()
  }

  func testMultiAttachObserversRequireCurrentLeaseForInputAndResize() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-lease-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let first = try waitForClient(root: root, socketPath: socketPath)
    defer { first.close() }
    let second = try waitForClient(root: root, socketPath: socketPath)
    defer { second.close() }

    let session = try first.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "m7-\(UUID().uuidString)"
      )
    )

    let grantedToFirst = try first.transferLease(
      sessionId: session.logicalSessionId,
      holderClientId: first.clientIdentifier
    )
    let firstLease = try XCTUnwrap(grantedToFirst.lease)
    XCTAssertEqual(grantedToFirst.leaseHolder, first.clientIdentifier)

    let attachedSecond = try second.attachSession(logicalSessionId: session.logicalSessionId)
    XCTAssertEqual(attachedSecond.attachedClientCount, 2)

    try first.writeInput(sessionId: session.logicalSessionId, bytes: Array("lease-a".utf8))
    let observerSnapshot = try waitForSnapshotText(
      client: second,
      sessionId: session.logicalSessionId,
      contains: "lease-a"
    )
    XCTAssertEqual(observerSnapshot.logicalSessionId, session.logicalSessionId)

    try assertLeaseDenied(code: "leaseRequired") {
      try second.writeInput(sessionId: session.logicalSessionId, bytes: Array("blocked".utf8))
    }
    try assertLeaseDenied(code: "leaseRequired") {
      _ = try second.resize(sessionId: session.logicalSessionId, rows: 30, cols: 100)
    }

    let transferredToSecond = try second.transferLease(
      sessionId: session.logicalSessionId,
      holderClientId: second.clientIdentifier
    )
    let secondLease = try XCTUnwrap(transferredToSecond.lease)
    XCTAssertEqual(transferredToSecond.leaseHolder, second.clientIdentifier)
    XCTAssertEqual(transferredToSecond.attachedClientCount, 2)
    XCTAssertNotEqual(secondLease.leaseId, firstLease.leaseId)
    XCTAssertGreaterThan(secondLease.epoch, firstLease.epoch)

    try assertLeaseDenied(code: "staleLease") {
      try first.writeInput(sessionId: session.logicalSessionId, bytes: Array("stale".utf8))
    }

    let catalogAfterTransfer = try waitForSessionInfo(
      client: second,
      logicalSessionId: session.logicalSessionId,
      attachedClientCount: 2,
      leaseHolder: second.clientIdentifier
    )
    XCTAssertEqual(catalogAfterTransfer.lease?.leaseId, secondLease.leaseId)

    usleep(450_000)
    try assertLeaseDenied(code: "leaseExpired") {
      try second.writeInput(sessionId: session.logicalSessionId, bytes: Array("expired".utf8))
    }

    let reacquiredByFirst = try first.transferLease(
      sessionId: session.logicalSessionId,
      holderClientId: first.clientIdentifier
    )
    let finalLease = try XCTUnwrap(reacquiredByFirst.lease)
    XCTAssertEqual(reacquiredByFirst.leaseHolder, first.clientIdentifier)
    XCTAssertGreaterThan(finalLease.epoch, secondLease.epoch)

    _ = try waitForSessionInfo(
      client: second,
      logicalSessionId: session.logicalSessionId,
      attachedClientCount: 2,
      leaseHolder: first.clientIdentifier
    )

    _ = try first.terminate(sessionId: session.logicalSessionId)
    second.close()
    try first.shutdownWhenIdle()
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
    var environment = ProcessInfo.processInfo.environment
    environment["LABAN_LABAND_LEASE_TTL_MS"] = "250"
    process.environment = environment
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
          return try LabandTerminalSessionClient(socketPath: socketPath, autoRenewLeases: false)
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

  private func waitForSessionInfo(
    client: LabandTerminalSessionClient,
    logicalSessionId: String,
    attachedClientCount: Int,
    leaseHolder: String
  ) throws -> LabandSessionInfo {
    let deadline = Date().addingTimeInterval(5)
    var last: LabandSessionInfo?
    while Date() < deadline {
      if let info = try client.listSessions().first(where: {
        $0.logicalSessionId == logicalSessionId
      }) {
        last = info
        if info.attachedClientCount == attachedClientCount, info.leaseHolder == leaseHolder {
          return info
        }
      }
      usleep(50_000)
    }
    XCTFail(
      "session \(logicalSessionId) never reached attachedClientCount=\(attachedClientCount), leaseHolder=\(leaseHolder); last=\(String(describing: last))"
    )
    throw POSIXError(.ETIMEDOUT)
  }

  private func assertLeaseDenied(code: String, _ operation: () throws -> Void) throws {
    XCTAssertThrowsError(try operation()) { error in
      XCTAssertTrue(
        String(describing: error).contains(code),
        "expected \(code), got \(String(describing: error))"
      )
    }
  }
}
