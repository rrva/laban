import Darwin
import Foundation
import LabanCore
import XCTest

final class LabandControlProtocolTests: XCTestCase {
  private var launchedDaemon: Process?

  override func tearDown() {
    if let launchedDaemon, launchedDaemon.isRunning {
      launchedDaemon.terminate()
      launchedDaemon.waitUntilExit()
    }
    launchedDaemon = nil
    super.tearDown()
  }

  func testDaemonOwnsPtyBackedSessionOverControlProtocol() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-control-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let client = try waitForClient(root: root, socketPath: socketPath)
    defer { client.close() }

    let hello = try client.hello()
    XCTAssertEqual(hello.protocolVersion, LabandProtocolVersion.current)
    XCTAssertEqual(hello.capabilities.contains("control-json/v1"), true)
    XCTAssertTrue(
      hello.capabilities.contains(LabandCapabilities.snapshotCellExplicitBackgroundV1))

    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80
      )
    )
    XCTAssertFalse(session.logicalSessionId.isEmpty)
    XCTAssertFalse(session.incarnationId.isEmpty)
    XCTAssertEqual(session.daemonProcessPid, Int(daemon.processIdentifier))
    let childPid = try XCTUnwrap(session.childPid)
    XCTAssertEqual(try parentPid(of: childPid), Int(daemon.processIdentifier))

    try client.writeInput(sessionId: session.logicalSessionId, bytes: Array("x".utf8))

    let snapshot = try waitForSnapshotText(
      client: client,
      sessionId: session.logicalSessionId,
      contains: "x"
    )
    XCTAssertEqual(snapshot.logicalSessionId, session.logicalSessionId)
    XCTAssertEqual(snapshot.incarnationId, session.incarnationId)
    XCTAssertEqual(snapshot.rows, 24)
    XCTAssertEqual(snapshot.cols, 80)
    XCTAssertEqual(snapshot.cells.first?.text, "x")

    let terminate = try client.terminate(sessionId: session.logicalSessionId)
    XCTAssertEqual(terminate.lifecycleState, .terminated)

    let list = try client.listSessions()
    XCTAssertEqual(list.count, 1)
    XCTAssertEqual(list.first?.logicalSessionId, session.logicalSessionId)
    XCTAssertEqual(list.first?.lifecycleState, .terminated)

    try client.shutdownWhenIdle()
    daemon.waitUntilExit()
    XCTAssertEqual(daemon.terminationStatus, 0)
    launchedDaemon = nil
  }

  func testThemeApplyUpdatesDaemonSessionPalette() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-theme-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let client = try waitForClient(root: root, socketPath: socketPath)
    defer { client.close() }

    let hello = try client.hello()
    XCTAssertTrue(hello.capabilities.contains("theme-palette/v1"))

    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80
      )
    )
    try client.writeInput(sessionId: session.logicalSessionId, bytes: Array("t".utf8))
    _ = try waitForSnapshotText(
      client: client,
      sessionId: session.logicalSessionId,
      contains: "t"
    )

    try client.applyTheme(
      sessionId: session.logicalSessionId,
      paletteBytes: Array("\u{1B}]10;#112233\u{07}\u{1B}]11;#445566\u{07}".utf8),
      colorScheme: .dark)

    let snapshot = try client.snapshot(sessionId: session.logicalSessionId)
    let themedCell = try XCTUnwrap(snapshot.cells.first { $0.text == "t" })
    XCTAssertEqual(themedCell.foregroundRGBA, 0x1122_33FF)
    XCTAssertEqual(themedCell.backgroundRGBA, 0x4455_66FF)

    _ = try client.terminate(sessionId: session.logicalSessionId)
    try client.shutdownWhenIdle()
    daemon.waitUntilExit()
    XCTAssertEqual(daemon.terminationStatus, 0)
    launchedDaemon = nil
  }

  func testScrollViewportMovesDaemonSessionScrollback() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-scroll-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let client = try waitForClient(root: root, socketPath: socketPath)
    defer { client.close() }

    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: [
          "/bin/sh", "-lc",
          "i=1; while [ $i -le 30 ]; do printf 'line-%02d\\n' \"$i\"; i=$((i+1)); done; sleep 60",
        ],
        cwd: root.path,
        rows: 5,
        cols: 40
      )
    )

    let bottom = try waitForSnapshotText(
      client: client,
      sessionId: session.logicalSessionId,
      contains: "line-30"
    )
    XCTAssertFalse(bottom.visibleText.contains("line-10"))

    _ = try client.scrollViewport(sessionId: session.logicalSessionId, deltaRows: -20)
    let older = try waitForSnapshotText(
      client: client,
      sessionId: session.logicalSessionId,
      contains: "line-10"
    )
    XCTAssertFalse(older.visibleText.contains("line-30"))

    _ = try client.terminate(sessionId: session.logicalSessionId)
    try client.shutdownWhenIdle()
    daemon.waitUntilExit()
    XCTAssertEqual(daemon.terminationStatus, 0)
    launchedDaemon = nil
  }

  func testSnapshotRingPublishesCoherentEchoedCells() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-ring-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let client = try waitForClient(root: root, socketPath: socketPath)
    defer { client.close() }

    let hello = try client.hello()
    XCTAssertTrue(hello.capabilities.contains("snapshot-ring/v1"))

    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80
      )
    )
    let attachment = try client.attachSnapshotRing(sessionId: session.logicalSessionId)
    XCTAssertEqual(attachment.headerBytes, Int(LabandSnapshotRingLayout.fileHeaderBytes))
    XCTAssertEqual(attachment.slotHeaderBytes, Int(LabandSnapshotRingLayout.slotHeaderBytes))
    XCTAssertEqual(attachment.cellBytes, Int(LabandSnapshotRingLayout.cellBytes))
    XCTAssertGreaterThanOrEqual(attachment.slotCount, LabandSnapshotRingLayout.minimumSlotCount)
    XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))

    let reader = try client.snapshotRingReader(sessionId: session.logicalSessionId)
    try client.writeInput(sessionId: session.logicalSessionId, bytes: Array("ring-ok".utf8))
    let snapshot = try waitForRingSnapshotText(reader: reader, contains: "ring-ok")
    XCTAssertEqual(snapshot.logicalSessionId, session.logicalSessionId)
    XCTAssertEqual(snapshot.incarnationId, session.incarnationId)
    XCTAssertEqual(snapshot.cells.first?.text, "r")
    XCTAssertTrue(snapshot.visibleText.contains("ring-ok"))
    let frame = try client.snapshotFrame(sessionId: session.logicalSessionId)
    XCTAssertNotNil(frame.generation)
    XCTAssertGreaterThan(frame.generation ?? 0, 0)
    XCTAssertNotNil(frame.dirtyRanges)
    XCTAssertFalse(frame.dirtyRanges?.isEmpty ?? true)
    XCTAssertNotNil(frame.ptyDrainMonoNs)
    XCTAssertNotNil(frame.snapshotPublishMonoNs)
    XCTAssertGreaterThan(frame.ptyDrainMonoNs ?? 0, 0)
    XCTAssertGreaterThan(frame.snapshotPublishMonoNs ?? 0, 0)
    XCTAssertGreaterThanOrEqual(frame.snapshotPublishMonoNs ?? 0, frame.ptyDrainMonoNs ?? 0)
    XCTAssertNotNil(frame.snapshotPublishedAt())
    XCTAssertTrue(frame.snapshot.visibleText.contains("ring-ok"))

    _ = try client.terminate(sessionId: session.logicalSessionId)
    try client.shutdownWhenIdle()
    daemon.waitUntilExit()
    XCTAssertEqual(daemon.terminationStatus, 0)
    launchedDaemon = nil
  }

  func testFailedSnapshotRingAttachDoesNotRetainClient() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-ring-failure-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let owner = try waitForClient(root: root, socketPath: socketPath)
    defer { owner.close() }
    let session = try owner.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80
      ))
    XCTAssertEqual(session.attachedClientCount, 1)

    let blockedRingDirectory = root.appendingPathComponent(journalPath)
      .appendingPathComponent("snapshot-rings")
    XCTAssertTrue(
      FileManager.default.createFile(atPath: blockedRingDirectory.path, contents: Data()))

    let failingClient = try waitForClient(root: root, socketPath: socketPath)
    XCTAssertThrowsError(
      try failingClient.attachSnapshotRing(sessionId: session.logicalSessionId))
    failingClient.close()

    _ = try waitForSessionInfo(
      client: owner,
      logicalSessionId: session.logicalSessionId,
      attachedClientCount: 1)

    _ = try owner.terminate(sessionId: session.logicalSessionId)
    try owner.shutdownWhenIdle()
    daemon.waitUntilExit()
    XCTAssertEqual(daemon.terminationStatus, 0)
    launchedDaemon = nil
  }

  func testClientIOTimeoutBoundsSilentDaemonRead() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".tmp/laband-silent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let socketPath = root.appendingPathComponent("laband.sock").path
    let listenFD = try bindUnixSocketForTest(path: socketPath)
    defer { Darwin.close(listenFD) }

    let accepted = DispatchSemaphore(value: 0)
    let serverDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      let clientFD = Darwin.accept(listenFD, nil, nil)
      guard clientFD >= 0 else {
        accepted.signal()
        serverDone.signal()
        return
      }
      accepted.signal()
      var header = [UInt8](repeating: 0, count: 4)
      _ = Darwin.read(clientFD, &header, header.count)
      usleep(350_000)
      Darwin.close(clientFD)
      serverDone.signal()
    }

    let client = try LabandTerminalSessionClient(
      socketPath: socketPath,
      autoRenewLeases: false,
      ioTimeoutMilliseconds: 100)
    XCTAssertEqual(accepted.wait(timeout: .now() + 1), .success)
    let startedAt = Date()
    XCTAssertThrowsError(try client.hello())
    XCTAssertLessThan(
      Date().timeIntervalSince(startedAt),
      1,
      "a silent optional daemon must not wedge its serial transport queue")
    client.closeAfterTransportFailure()
    XCTAssertEqual(serverDone.wait(timeout: .now() + 1), .success)
  }

  func testClientAttachLifecycleUpdatesAttachedCount() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-attach-\(UUID().uuidString)"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let daemon = try launchDaemon(root: root, socketPath: socketPath, journalPath: journalPath)
    launchedDaemon = daemon

    let first = try waitForClient(root: root, socketPath: socketPath)
    let session = try first.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "m5-\(UUID().uuidString)"
      )
    )
    XCTAssertEqual(session.attachedClientCount, 1)
    let logicalSessionId = session.logicalSessionId
    let incarnationId = session.incarnationId
    let childPid = session.childPid
    first.close()

    let second = try waitForClient(root: root, socketPath: socketPath)
    defer { second.close() }
    let detached = try waitForSessionInfo(
      client: second,
      logicalSessionId: logicalSessionId,
      attachedClientCount: 0
    )
    XCTAssertEqual(detached.incarnationId, incarnationId)
    XCTAssertEqual(detached.childPid, childPid)
    XCTAssertEqual(detached.lifecycleState, .running)

    let reattached = try second.attachSession(logicalSessionId: logicalSessionId)
    XCTAssertEqual(reattached.attachedClientCount, 1)
    XCTAssertEqual(reattached.incarnationId, incarnationId)
    XCTAssertEqual(reattached.childPid, childPid)

    _ = try second.terminate(sessionId: logicalSessionId)
    try second.shutdownWhenIdle()
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

  private func bindUnixSocketForTest(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      for index in 0..<pathBytes.count {
        ptr.advanced(by: index).pointee = pathBytes[index]
      }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      Darwin.close(fd)
      throw error
    }
    return fd
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

  private func waitForRingSnapshotText(
    reader: LabandSnapshotRingReader,
    contains needle: String
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(5)
    var lastSnapshot: LabandSnapshotResponse?
    while Date() < deadline {
      if let snapshot = try? reader.latestSnapshot() {
        lastSnapshot = snapshot
        if snapshot.visibleText.contains(needle) {
          return snapshot
        }
      }
      usleep(50_000)
    }
    XCTFail(
      "snapshot ring never contained \(needle); last=\(lastSnapshot?.visibleText ?? "<none>")")
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForSessionInfo(
    client: LabandTerminalSessionClient,
    logicalSessionId: String,
    attachedClientCount: Int
  ) throws -> LabandSessionInfo {
    let deadline = Date().addingTimeInterval(5)
    var last: LabandSessionInfo?
    while Date() < deadline {
      if let info = try client.listSessions().first(where: {
        $0.logicalSessionId == logicalSessionId
      }) {
        last = info
        if info.attachedClientCount == attachedClientCount {
          return info
        }
      }
      usleep(50_000)
    }
    XCTFail(
      "session \(logicalSessionId) never reached attachedClientCount=\(attachedClientCount); last=\(String(describing: last))"
    )
    throw POSIXError(.ETIMEDOUT)
  }

  private func parentPid(of pid: Int) throws -> Int? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "ppid=", "-p", "\(pid)"]
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
