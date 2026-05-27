import Darwin
import Foundation
import XCTest

@testable import LabanCore

final class LabptyDaemonTests: XCTestCase {
  private var launched: [Process] = []
  private var tempRoots: [URL] = []

  override func tearDown() {
    for process in launched where process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    launched.removeAll()
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  func testOpenAndListAndTerminate() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "open-list-terminate"))

    XCTAssertGreaterThan(descriptor.childPid, 0)
    XCTAssertEqual(Darwin.kill(pid_t(descriptor.childPid), 0), 0)
    let listed = try client.listLabptySessions()
    XCTAssertTrue(listed.contains { $0.ptyHandle == descriptor.ptyHandle && $0.alive })

    _ = try client.terminate(handle: descriptor.ptyHandle)
    try waitForDead(pid: pid_t(descriptor.childPid))
  }

  func testSignalSendsToProcessGroup() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "while true; do sleep 1; done"],
        logicalSessionId: "signal-test"))

    _ = try client.signal(handle: descriptor.ptyHandle, signal: Int32(SIGKILL))
    try waitForDead(pid: pid_t(descriptor.childPid))
  }

  func testResizeUpdatesWinsize() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "resize-test"))

    let resized = try client.resize(handle: descriptor.ptyHandle, rows: 41, cols: 132)
    XCTAssertEqual(resized.rows, 41)
    XCTAssertEqual(resized.cols, 132)
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testListSessionsCarriesByteRingPath() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "ring-path-test"))
    let listed = try XCTUnwrap(try client.listLabptySessions().first)

    XCTAssertEqual(listed.byteRingShmPath, descriptor.byteRingShmPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: listed.byteRingShmPath))
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testTerminateReleasesSlotsAndRingFilesForReuse() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    for index in 0...LabptyProtocolLimits.maxSessionDescriptorCount {
      let descriptor = try client.openSession(
        LabptyOpenSessionRequest(
          rows: 24,
          cols: 80,
          argv: ["/bin/sleep", "30"],
          logicalSessionId: "reuse-\(index)"))
      let ringPath = descriptor.byteRingShmPath
      XCTAssertTrue(FileManager.default.fileExists(atPath: ringPath))

      _ = try client.terminate(handle: descriptor.ptyHandle)
      try waitForDead(pid: pid_t(descriptor.childPid))
      try waitForPathGone(ringPath)
    }
  }

  func testInvalidRingCapacityDoesNotKillDaemon() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let badCapacities = [
      UInt64(LabptyByteRingLayout.minimumOutputRingCapacity - 1),
      UInt64(LabptyByteRingLayout.maximumOutputRingCapacity) + 1,
    ]
    for (index, capacity) in badCapacities.enumerated() {
      XCTAssertThrowsError(
        try client.openSession(
          LabptyOpenSessionRequest(
            rows: 24,
            cols: 80,
            outputRingCapacity: capacity,
            argv: ["/bin/sleep", "30"],
            logicalSessionId: "bad-capacity-\(index)")))
      XCTAssertTrue(harness.process.isRunning)
    }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "after-bad-capacity"))
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testStalledClientIsDisconnectedWithoutBlockingDaemon() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let raw = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(raw) }
    try setReceiveTimeout(fd: raw, milliseconds: 100)

    var byte: UInt8 = LabptyFrameHeader.magic[0]
    XCTAssertEqual(Darwin.write(raw, &byte, 1), 1)
    try waitForSocketClosed(fd: raw)

    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    _ = try client.hello()
  }

  func testSocketPathIsOwnerOnly() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let attrs = try FileManager.default.attributesOfItem(atPath: harness.socketPath)
    let permissions = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
  }

  func testShutdownSignalTerminatesSessionsAndUnlinksArtifacts() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "shutdown-cleanup"))
    let ringPath = descriptor.byteRingShmPath
    XCTAssertTrue(FileManager.default.fileExists(atPath: ringPath))

    XCTAssertEqual(Darwin.kill(pid_t(harness.process.processIdentifier), SIGTERM), 0)
    try waitForProcessExit(harness.process)
    try waitForDead(pid: pid_t(descriptor.childPid))
    try waitForPathGone(harness.socketPath)
    try waitForPathGone(ringPath)
  }

  func testByteRingHeaderAndCapacity() throws {
    let url = try temporaryRingURL()
    let writer = try LabptyByteRingWriter(
      path: url.path,
      outputRingCapacity: UInt64(LabptyByteRingLayout.minimumOutputRingCapacity),
      logicalSessionId: "header")
    _ = writer
    let reader = try LabptyByteRingReader(path: url.path)

    XCTAssertEqual(reader.outputRingOffset, LabptyByteRingLayout.inputRingOffset)
    XCTAssertEqual(reader.outputRingCapacity, UInt64(LabptyByteRingLayout.minimumOutputRingCapacity))
  }

  func testByteRingRoundTripSmall() throws {
    let url = try temporaryRingURL()
    let writer = try LabptyByteRingWriter(
      path: url.path,
      outputRingCapacity: UInt64(LabptyByteRingLayout.minimumOutputRingCapacity),
      logicalSessionId: "small")
    let reader = try LabptyByteRingReader(path: url.path)

    writer.write(Data("hello labpty".utf8))
    let result = reader.readSince(0)

    XCTAssertEqual(String(data: result.bytes, encoding: .utf8), "hello labpty")
    XCTAssertFalse(result.overflowed)
  }

  func testByteRingWrapDetection() throws {
    let url = try temporaryRingURL()
    let capacity = UInt64(LabptyByteRingLayout.minimumOutputRingCapacity)
    let writer = try LabptyByteRingWriter(path: url.path, outputRingCapacity: capacity)
    let reader = try LabptyByteRingReader(path: url.path)
    let payload = Data(repeating: 0x41, count: Int(capacity * 2 + 32))

    writer.write(payload)
    let result = reader.readSince(0)

    XCTAssertTrue(result.overflowed)
    XCTAssertEqual(result.bytes.count, Int(capacity))
    XCTAssertEqual(result.newOffset, UInt64(payload.count))
  }

  func testProducerAliveHeartbeat() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "heartbeat"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    let first = reader.producerAliveMonoNs()
    usleep(150_000)
    let second = reader.producerAliveMonoNs()

    XCTAssertGreaterThan(second, first + 50_000_000)
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testHighVolumeOutputIsNotSplitOrLost() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let command =
      "i=1; while [ $i -le 100000 ]; do printf 'line-%06d\\n' \"$i\"; i=$((i+1)); done; sleep 2"
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", command],
        logicalSessionId: "high-volume"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    let output = try waitForOutput(reader: reader, contains: "line-100000")
    let regex = try NSRegularExpression(pattern: #"line-(\d{6})"#)
    let nsOutput = output as NSString
    let matches = regex.matches(
      in: output,
      range: NSRange(location: 0, length: nsOutput.length))

    XCTAssertEqual(matches.count, 100_000)
    XCTAssertEqual(nsOutput.substring(with: matches.first!.range), "line-000001")
    XCTAssertEqual(nsOutput.substring(with: matches.last!.range), "line-100000")
    for (index, match) in matches.enumerated() {
      let expected = String(format: "line-%06d", index + 1)
      let actual = nsOutput.substring(with: match.range)
      if actual != expected {
        XCTFail("expected \(expected), got \(actual) at match \(index)")
        break
      }
    }
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  private struct Harness {
    let socketPath: String
    let shmDir: String
    let process: Process
  }

  private func launchHarness() throws -> Harness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "labpty-\(UUID().uuidString)"
    let tempRoot = ".tmp/\(runId)"
    let shmDir = "\(tempRoot)/shm"
    tempRoots.append(root.appendingPathComponent(tempRoot, isDirectory: true))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(shmDir),
      withIntermediateDirectories: true)
    let socketPath = "\(tempRoot)/s.sock"
    let executable = root.appendingPathComponent(".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("build labpty first: swift build --product labpty")
    }
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--shm-dir", shmDir]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    launched.append(process)
    return Harness(socketPath: socketPath, shmDir: shmDir, process: process)
  }

  private func waitForClient(socketPath: String) throws -> LabptyTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        do {
          return try LabptyTerminalSessionClient(socketPath: socketPath)
        } catch {
          lastError = error
        }
      }
      usleep(50_000)
    }
    if let lastError { throw lastError }
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForSocketFile(socketPath: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        return
      }
      usleep(50_000)
    }
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForDead(pid: pid_t) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if Darwin.kill(pid, 0) != 0 && errno == ESRCH {
        return
      }
      usleep(50_000)
    }
    XCTFail("pid \(pid) was still alive")
  }

  private func waitForPathGone(_ path: String) throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if !FileManager.default.fileExists(atPath: path) {
        return
      }
      usleep(20_000)
    }
    XCTFail("path \(path) still existed")
  }

  private func waitForProcessExit(_ process: Process) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if !process.isRunning {
        return
      }
      usleep(20_000)
    }
    XCTFail("process \(process.processIdentifier) was still running")
  }

  private func waitForSocketClosed(fd: Int32) throws {
    let deadline = Date().addingTimeInterval(2)
    var byte: UInt8 = 0
    while Date() < deadline {
      let n = Darwin.read(fd, &byte, 1)
      if n == 0 {
        return
      }
      if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        usleep(20_000)
        continue
      }
      if n < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    XCTFail("stalled socket was not closed")
  }

  private func connectRaw(socketPath: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
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
    return fd
  }

  private func setReceiveTimeout(fd: Int32, milliseconds: Int) throws {
    var timeout = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32((milliseconds % 1000) * 1000))
    let result = setsockopt(
      fd,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size))
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func waitForOutput(reader: LabptyByteRingReader, contains needle: String) throws -> String {
    let deadline = Date().addingTimeInterval(10)
    var offset: UInt64 = 0
    var data = Data()
    while Date() < deadline {
      let result = reader.readSince(offset)
      offset = result.newOffset
      data.append(result.bytes)
      if let text = String(data: data, encoding: .utf8), text.contains(needle) {
        return text
      }
      usleep(10_000)
    }
    let text = String(data: data, encoding: .utf8) ?? "<invalid utf8>"
    XCTFail("output never contained \(needle); got \(text.suffix(200))")
    throw POSIXError(.ETIMEDOUT)
  }

  private func temporaryRingURL() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let dir = root.appendingPathComponent(".tmp")
      .appendingPathComponent("labpty-ring-tests-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("ring.br")
  }
}
