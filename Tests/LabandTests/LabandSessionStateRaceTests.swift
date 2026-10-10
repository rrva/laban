import Darwin
import Foundation
import LabanCore
import XCTest

/// Regression for laban#44: every socket client runs `LabandDaemon.handle` on
/// its own thread, and `snapshot`, `resizeSession` and the foreground-process
/// refresh wrote a session's title/rows/cols/lifecycle/metadata fields while
/// `listSessions` read them, with no lock in common. Torn String reads could
/// garble catalog and journal entries or crash the daemon.
///
/// The test hammers those writers and readers from separate connections at
/// once, against a child that keeps changing the window title, and checks
/// that every observed value is one that was actually written and that the
/// daemon survives. Under `swift test --sanitize=thread` the daemon binary is
/// instrumented too, so its stderr must carry no ThreadSanitizer report.
final class LabandSessionStateRaceTests: XCTestCase {
  private var launchedDaemon: Process?

  override func tearDown() {
    if let launchedDaemon, launchedDaemon.isRunning {
      launchedDaemon.terminate()
      launchedDaemon.waitUntilExit()
    }
    launchedDaemon = nil
    super.tearDown()
  }

  func testConcurrentSnapshotResizeAndListSeeOnlyWrittenSessionState() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "laband-race-\(UUID().uuidString.prefix(8))"
    let socketPath = ".tmp/\(runId)/laband.sock"
    let journalPath = ".artifacts/runs/\(runId)/laband"
    let stderrPath = root.appendingPathComponent(".artifacts/runs/\(runId)/laband.stderr")
    let daemon = try launchDaemon(
      root: root, socketPath: socketPath, journalPath: journalPath, stderrPath: stderrPath)
    launchedDaemon = daemon

    let owner = try waitForClient(root: root, socketPath: socketPath)
    defer { owner.close() }

    // The child keeps rewriting the window title, so the daemon's snapshot
    // path keeps replacing the title String while readers copy it. It pauses
    // briefly every 20 titles so it does not starve parallel test shards.
    let titlePadding = String(repeating: "x", count: 48)
    let session = try owner.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: [
          "/bin/sh", "-c",
          "i=0; while :; do i=$((i+1)); printf '\\033]0;t%d-\(titlePadding)\\007' \"$i\";"
            + " [ $((i % 20)) -eq 0 ] && sleep 0.01; done",
        ],
        cwd: root.path,
        rows: 24,
        cols: 80
      )
    )
    let sessionId = session.logicalSessionId
    defer { _ = try? owner.terminate(sessionId: sessionId) }
    XCTAssertNotNil(owner.currentLease(sessionId: sessionId), "creator should hold the lease")

    let sizes = [(24, 80), (30, 100), (40, 132), (50, 160)]
    let allowedSizes = Set(sizes.map { "\($0.0)x\($0.1)" })
    let titlePattern = try NSRegularExpression(pattern: "^(sh|t[0-9]+-\(titlePadding))$")
    func isWrittenTitle(_ title: String) -> Bool {
      titlePattern.firstMatch(
        in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    let failures = FailureLog()
    let deadline = Date().addingTimeInterval(1.5)
    let group = DispatchGroup()
    func worker(_ name: String, _ body: @escaping () throws -> Void) {
      group.enter()
      Thread {
        defer { group.leave() }
        while Date() < deadline {
          do {
            try body()
          } catch {
            failures.record("\(name): \(error)")
            return
          }
        }
      }.start()
    }

    var sizeIndex = 0
    worker("resize") {
      sizeIndex = (sizeIndex + 1) % sizes.count
      let (rows, cols) = sizes[sizeIndex]
      _ = try owner.resize(sessionId: sessionId, rows: rows, cols: cols)
    }
    for index in 0..<2 {
      let raw = try RawLabandConnection(socketPath: socketPath)
      worker("snapshot\(index)") {
        let response = try raw.send(
          LabandRequest(requestId: UUID().uuidString, type: .snapshot, sessionId: sessionId))
        guard let snapshot = response.snapshot else {
          failures.record("snapshot\(index): \(String(describing: response.error))")
          return
        }
        if !isWrittenTitle(snapshot.title) {
          failures.record("snapshot\(index): torn title \(snapshot.title.debugDescription)")
        }
      }
    }
    for index in 0..<2 {
      let lister = try owner.makeIndependentClient()
      worker("list\(index)") {
        for info in try lister.listSessions() where info.logicalSessionId == sessionId {
          if !isWrittenTitle(info.title) {
            failures.record("list\(index): torn title \(info.title.debugDescription)")
          }
          if !allowedSizes.contains("\(info.rows)x\(info.cols)") {
            failures.record("list\(index): unwritten size \(info.rows)x\(info.cols)")
          }
          if info.lifecycleState != .running {
            failures.record("list\(index): lifecycle \(info.lifecycleState)")
          }
        }
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "workers did not finish")
    XCTAssertTrue(daemon.isRunning, "laband died under concurrent session access")
    XCTAssertEqual(failures.entries, [])

    _ = try? owner.terminate(sessionId: sessionId)
    daemon.terminate()
    daemon.waitUntilExit()
    let stderr = (try? String(contentsOf: stderrPath, encoding: .utf8)) ?? ""
    XCTAssertFalse(
      stderr.contains("ThreadSanitizer"),
      "laband reported a data race:\n\(stderr.prefix(4000))")
  }

  private func launchDaemon(
    root: URL,
    socketPath: String,
    journalPath: String,
    stderrPath: URL
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
      at: stderrPath.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // A file, not a Pipe: a sanitizer report can outgrow the pipe buffer and
    // block the daemon mid-write.
    FileManager.default.createFile(atPath: stderrPath.path, contents: nil)
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--journal", journalPath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = try FileHandle(forWritingTo: stderrPath)
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

private final class FailureLog: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  func record(_ failure: String) {
    lock.withLock {
      if recorded.count < 20 { recorded.append(failure) }
    }
  }

  var entries: [String] { lock.withLock { recorded } }
}

/// The session client answers `snapshot` from the shared-memory ring, which
/// never reaches the daemon's `snapshot` request handler. This connection
/// sends raw control frames so the test drives that handler directly.
private final class RawLabandConnection {
  private let fd: Int32
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(socketPath: String) throws {
    fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: pathBytes)
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      Darwin.close(fd)
      throw error
    }
  }

  deinit {
    Darwin.close(fd)
  }

  func send(_ request: LabandRequest) throws -> LabandResponse {
    let payload = try encoder.encode(request)
    let length = UInt32(payload.count)
    var frame = Data([
      UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
      UInt8((length >> 16) & 0xFF), UInt8((length >> 24) & 0xFF),
    ])
    frame.append(payload)
    try writeAll(frame)
    let header = [UInt8](try readExact(count: 4))
    let responseLength =
      Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
    return try decoder.decode(LabandResponse.self, from: readExact(count: responseLength))
  }

  private func writeAll(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { raw in
        Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
  }

  private func readExact(count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let n = data.withUnsafeMutableBytes { raw in
        Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
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
}
