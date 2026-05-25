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

    let hello = try client.send(
      LabandRequest(requestId: "hello-1", type: .hello)
    )
    XCTAssertTrue(hello.ok)
    XCTAssertEqual(hello.hello?.protocolVersion, LabandProtocolVersion.current)
    XCTAssertEqual(hello.hello?.capabilities.contains("control-json/v1"), true)

    let create = try client.send(
      LabandRequest(
        requestId: "create-1",
        type: .createSession,
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: root.path,
        rows: 24,
        cols: 80
      )
    )
    XCTAssertTrue(create.ok, create.error?.message ?? "")
    let session = try XCTUnwrap(create.session)
    XCTAssertFalse(session.logicalSessionId.isEmpty)
    XCTAssertFalse(session.incarnationId.isEmpty)
    XCTAssertEqual(session.daemonProcessPid, Int(daemon.processIdentifier))
    let childPid = try XCTUnwrap(session.childPid)
    XCTAssertEqual(try parentPid(of: childPid), Int(daemon.processIdentifier))

    let write = try client.send(
      LabandRequest(
        requestId: "write-1",
        type: .writeInput,
        sessionId: session.logicalSessionId,
        text: "x"
      )
    )
    XCTAssertTrue(write.ok, write.error?.message ?? "")

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

    let terminate = try client.send(
      LabandRequest(
        requestId: "terminate-1",
        type: .terminateSession,
        sessionId: session.logicalSessionId
      )
    )
    XCTAssertTrue(terminate.ok, terminate.error?.message ?? "")
    XCTAssertEqual(terminate.session?.lifecycleState, .terminated)

    let list = try client.send(
      LabandRequest(requestId: "list-1", type: .listSessions)
    )
    XCTAssertTrue(list.ok, list.error?.message ?? "")
    XCTAssertEqual(list.sessions?.count, 1)
    XCTAssertEqual(list.sessions?.first?.logicalSessionId, session.logicalSessionId)
    XCTAssertEqual(list.sessions?.first?.lifecycleState, .terminated)

    let shutdown = try client.send(
      LabandRequest(requestId: "shutdown-1", type: .shutdownWhenIdle)
    )
    XCTAssertTrue(shutdown.ok, shutdown.error?.message ?? "")
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

  private func waitForClient(root: URL, socketPath: String) throws -> LabandTestClient {
    let absoluteSocketPath = root.appendingPathComponent(socketPath).path
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: absoluteSocketPath) {
        do {
          return try LabandTestClient(socketPath: socketPath)
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
    client: LabandTestClient,
    sessionId: String,
    contains needle: String
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(5)
    var lastSnapshot: LabandSnapshotResponse?
    while Date() < deadline {
      let response = try client.send(
        LabandRequest(
          requestId: "snapshot-\(UUID().uuidString)",
          type: .snapshot,
          sessionId: sessionId
        )
      )
      if let snapshot = response.snapshot {
        lastSnapshot = snapshot
        if snapshot.visibleText.contains(needle) {
          return snapshot
        }
      }
      usleep(50_000)
    }
    XCTFail("snapshot never contained \(needle); last=\(lastSnapshot?.visibleText ?? "<none>")")
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

private final class LabandTestClient {
  private let fd: Int32
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(socketPath: String) throws {
    fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      for index in 0..<pathBytes.count {
        ptr.advanced(by: index).pointee = pathBytes[index]
      }
    }
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let err = errno
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
  }

  func close() {
    Darwin.close(fd)
  }

  func send(_ request: LabandRequest) throws -> LabandResponse {
    let payload = try encoder.encode(request)
    try writeFrame(payload)
    let responsePayload = try readFrame()
    return try decoder.decode(LabandResponse.self, from: responsePayload)
  }

  private func readFrame() throws -> Data {
    let header = try readExact(count: 4)
    let bytes = [UInt8](header)
    let length = Int(
      UInt32(bytes[0])
        | (UInt32(bytes[1]) << 8)
        | (UInt32(bytes[2]) << 16)
        | (UInt32(bytes[3]) << 24)
    )
    return try readExact(count: length)
  }

  private func writeFrame(_ payload: Data) throws {
    let length = UInt32(payload.count)
    var header = Data()
    header.append(UInt8(length & 0xFF))
    header.append(UInt8((length >> 8) & 0xFF))
    header.append(UInt8((length >> 16) & 0xFF))
    header.append(UInt8((length >> 24) & 0xFF))
    try writeAll(header)
    try writeAll(payload)
  }

  private func readExact(count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let n = data.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(fd, base.advanced(by: offset), count - offset)
      }
      if n == 0 { throw POSIXError(.ECONNRESET) }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
    return data
  }

  private func writeAll(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
  }
}
