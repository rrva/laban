import Darwin
import Foundation
import LabanControl
import XCTest

@testable import LabanAgent

final class ControlAttachProxyServerTests: XCTestCase {
  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-agent-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  func testIsDescendant() {
    XCTAssertTrue(ControlAttachProxyServer.isDescendant(pid: getpid(), of: 1))
    XCTAssertFalse(ControlAttachProxyServer.isDescendant(pid: 1, of: getpid()))
  }

  func testProxyDirectoryIsPrivate() throws {
    let upstream = try FakeUpstreamServer().start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }

    var st = stat()
    XCTAssertEqual(stat(proxy.testTempDirectory.path, &st), 0)
    XCTAssertEqual(st.st_uid, getuid())
    XCTAssertEqual(st.st_mode & 0o777, 0o700)
  }

  func testListenerFDIsCloseOnExec() throws {
    let upstream = try FakeUpstreamServer().start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }

    let flags = fcntl(proxy.testListenerFD, F_GETFD)
    XCTAssertTrue(flags & FD_CLOEXEC != 0)
  }

  func testStopRemovesSocketFileAndTempDirectory() throws {
    let upstream = try FakeUpstreamServer().start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(upstreamFD: upstream.clientFD, allowedRootPID: nil)
    let tempDirectory = proxy.testTempDirectory
    let socketPath = proxy.socketPath
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.path))

    proxy.stop()

    XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
  }

  func testStopIsIdempotent() throws {
    let upstream = try FakeUpstreamServer().start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(upstreamFD: upstream.clientFD, allowedRootPID: nil)
    let socketPath = proxy.socketPath

    proxy.stop()
    // A second stop() must not crash, throw, or resurrect the socket.
    proxy.stop()

    XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
  }

  // NOTE: a `deinit`-triggered cleanup test (constructing a proxy, dropping
  // every strong reference, and asserting the socket/temp dir are gone
  // without an explicit `stop()`) was attempted here but is not reachable as
  // a cheap test: `init` starts an accept thread as
  // `Thread { [weak self] in self?.acceptLoop() }`, and `self?.acceptLoop()`
  // promotes `self` to a strong local reference for the entire call, which
  // blocks in `accept()` until a client connects or `stop()` closes the
  // listener fd. That means the accept thread itself keeps the proxy alive
  // for as long as nothing calls `stop()`, so `deinit` cannot fire from ARC
  // alone in the "constructed, abandoned, no explicit stop" scenario this
  // finding asked to cover. `testStopIsIdempotent` and
  // `testStopRemovesSocketFileAndTempDirectory` above cover the explicit
  // `stop()` cleanup path, which is the reachable one.

  func testProxyRejectsPeerOutsideChildTree() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }

    // Launch an unrelated child and restrict proxy access to its tree.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    try child.run()
    defer { child.terminate() }
    proxy.setAllowedRootPID(child.processIdentifier)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let request = Data(#"{"method":"GET","path":"/debug/state"}"#.utf8) + Data([0x0A])
    try sendAll(fd: clientFD, data: request)

    let received = try readAvailable(fd: clientFD, timeout: 1.0)
    guard let newline = received.firstIndex(of: 0x0A) else {
      XCTFail("proxy returned no response")
      return
    }
    let raw = received[..<newline]
    let response = try JSONDecoder().decode(LiveControlAttachResponse.self, from: raw)
    XCTAssertEqual(response.status, 403)
  }

  func testProxyRejectsPeerBeforeRootBoundWhenRequired() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    // requireBoundRoot: true with no root bound yet must reject every peer,
    // closing the window between accept-loop start and a launched child's
    // pid becoming known via setAllowedRootPID.
    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil,
      requireBoundRoot: true)
    defer { proxy.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let request = Data(#"{"method":"GET","path":"/debug/state"}"#.utf8) + Data([0x0A])
    try sendAll(fd: clientFD, data: request)

    let response = try readLineJSON(fd: clientFD, timeout: 1.0)
    XCTAssertEqual(response?.status, 403)
  }

  func testProxyAcceptsPeerAfterRootBoundWhenRequired() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil,
      requireBoundRoot: true)
    defer { proxy.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    // Once the root pid is bound, the connecting test process (itself the
    // peer over the loopback UDS) must be accepted as the root.
    proxy.setAllowedRootPID(getpid())

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let request = Data(#"{"method":"GET","path":"/debug/state"}"#.utf8) + Data([0x0A])
    try sendAll(fd: clientFD, data: request)

    let response = try readLineJSON(fd: clientFD, timeout: 1.0)
    XCTAssertEqual(response?.status, 200)
  }

  func testIsDescendantTerminatesOnSyntheticCycle() {
    // A pathological parent-lookup that cycles (100 -> 200 -> 100 -> ...)
    // must not spin forever; the depth cap forces termination with `false`.
    let cyclicParents: [pid_t: pid_t] = [100: 200, 200: 100]
    let result = ControlAttachProxyServer.isDescendant(
      pid: 100, of: 999, parentLookup: { cyclicParents[$0] })
    XCTAssertFalse(result)
  }

  func testAcceptedClientFDIsCloseOnExec() throws {
    let upstream = try FakeUpstreamServer().start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }

    let accepted = XCTestExpectation(description: "accepted client")
    var acceptedFD: Int32 = -1
    proxy.testClientAcceptedHandler = { fd in
      acceptedFD = fd
      accepted.fulfill()
    }

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    wait(for: [accepted], timeout: 1.0)
    XCTAssertGreaterThan(acceptedFD, 0)

    let flags = fcntl(acceptedFD, F_GETFD)
    XCTAssertTrue(flags & FD_CLOEXEC != 0)
  }

  func testProxySendsHeartbeat() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let limits = ProxyLimits(
      maxLineBytes: 64 * 1024,
      maxBodyBytes: 32 * 1024,
      maxConcurrentClients: 16,
      maxQueueDepth: 64,
      clientIdleSeconds: 60,
      heartbeatIntervalSeconds: 0.2)
    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil,
      limits: limits)
    defer { proxy.stop() }

    Thread.sleep(forTimeInterval: 0.6)
    XCTAssertGreaterThanOrEqual(upstream.requestCount, 1)
    XCTAssertTrue(
      upstream.requestPaths.contains("/debug/health"),
      "expected heartbeat path, got \(upstream.requestPaths)")
  }

  func testProxyRejectsTooManyConcurrentClients() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let limits = ProxyLimits(
      maxLineBytes: 64 * 1024,
      maxBodyBytes: 32 * 1024,
      maxConcurrentClients: 1,
      maxQueueDepth: 10,
      clientIdleSeconds: 60,
      heartbeatIntervalSeconds: 3600)
    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil,
      limits: limits)
    defer { proxy.stop() }

    let first = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(first) }
    Thread.sleep(forTimeInterval: 0.05)

    let second = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(second) }

    let response = try readLineJSON(fd: second, timeout: 1.0)
    XCTAssertEqual(response?.status, 429)
  }

  func testProxyRejectsIdleClient() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let limits = ProxyLimits(
      maxLineBytes: 64 * 1024,
      maxBodyBytes: 32 * 1024,
      maxConcurrentClients: 16,
      maxQueueDepth: 64,
      clientIdleSeconds: 1,
      heartbeatIntervalSeconds: 3600)
    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil,
      limits: limits)
    defer { proxy.stop() }

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let response = try readLineJSON(fd: clientFD, timeout: 2.0)
    XCTAssertEqual(response?.status, 408)
  }

  func testProxyRejectsFullQueue() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let limits = ProxyLimits(
      maxLineBytes: 64 * 1024,
      maxBodyBytes: 32 * 1024,
      maxConcurrentClients: 16,
      maxQueueDepth: 0,
      clientIdleSeconds: 60,
      heartbeatIntervalSeconds: 3600)
    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil,
      limits: limits)
    defer { proxy.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let request = Data(#"{"method":"GET","path":"/debug/state"}"#.utf8) + Data([0x0A])
    try sendAll(fd: clientFD, data: request)

    let response = try readLineJSON(fd: clientFD, timeout: 1.0)
    XCTAssertEqual(response?.status, 429)
  }

  func testChildDoesNotInheritProxyOrUpstreamFDs() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }

    let config = try ChildLauncher.prepareConfiguration(
      command: ["sh", "-c", "ls /dev/fd"],
      inheritedEnvironment: ["PATH": "/bin:/usr/bin"],
      agentControlURL: proxy.socketPath)

    XCTAssertTrue(
      fcntl(upstream.clientFD, F_GETFD) & FD_CLOEXEC != 0,
      "upstream fd is not close-on-exec")
    XCTAssertTrue(
      fcntl(proxy.testListenerFD, F_GETFD) & FD_CLOEXEC != 0,
      "listener fd is not close-on-exec")

    var pipe: [Int32] = [-1, -1]
    XCTAssertEqual(Darwin.pipe(&pipe), 0)
    defer {
      if pipe[0] >= 0 { Darwin.close(pipe[0]) }
      if pipe[1] >= 0 { Darwin.close(pipe[1]) }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, pipe[0])

    let pid = try ChildLauncher.launch(config, fileActions: actions)
    Darwin.close(pipe[1])
    pipe[1] = -1

    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, 0)
    } while result == -1 && errno == EINTR
    XCTAssertEqual(ChildLauncher.exitStatus(waitResult: result, status: status), 0)

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = Darwin.read(pipe[0], &buffer, buffer.count)
      if n <= 0 { break }
      data.append(contentsOf: buffer[0..<Int(n)])
    }

    let output = String(data: data, encoding: .utf8) ?? ""
    let childFDs =
      output
      .components(separatedBy: .newlines)
      .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

    XCTAssertFalse(
      childFDs.contains(upstream.clientFD),
      "child inherited upstream fd \(upstream.clientFD)")
    XCTAssertFalse(
      childFDs.contains(proxy.testListenerFD),
      "child inherited listener fd \(proxy.testListenerFD)")
  }

  func testProxyForwardsRequest() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }
    // Give the accept thread a moment to start listening.
    Thread.sleep(forTimeInterval: 0.05)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let request = Data(#"{"method":"GET","path":"/debug/state"}"#.utf8) + Data([0x0A])
    try sendAll(fd: clientFD, data: request)

    let received = try readAvailable(fd: clientFD, timeout: 1.0)
    guard let newline = received.firstIndex(of: 0x0A) else {
      XCTFail(
        "proxy returned no newline-delimited response: \(String(data: received, encoding: .utf8) ?? "<non-utf8>")"
      )
      return
    }
    let raw = received[..<newline]
    let response = try JSONDecoder().decode(LiveControlAttachResponse.self, from: raw)
    XCTAssertEqual(response.path, "/debug/state")
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, "{\"ok\":true}")
  }

  func testProxyForwardsMultipleRequestsOnOneConnection() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    for path in ["/debug/state", "/debug/health"] {
      let request = Data(#"{"method":"GET","path":"\#(path)"}"#.utf8) + Data([0x0A])
      try sendAll(fd: clientFD, data: request)

      let response = try readLineJSON(fd: clientFD, timeout: 1.0)
      XCTAssertEqual(response?.path, path)
      XCTAssertEqual(response?.status, 200)
    }
  }

  func testProxyRejectsOversizedLine() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let oversized = Data(
      repeating: UInt8(ascii: "x"), count: ControlAttachProxyServer.maxLineBytes + 1)
    try sendAll(fd: clientFD, data: oversized)

    let response = try readLineJSON(fd: clientFD, timeout: 1.0)
    XCTAssertEqual(response?.status, 413)

    // The upstream must stay alive: a fresh connection should still work.
    let clientFD2 = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD2) }
    let request = Data(#"{"method":"GET","path":"/debug/state"}"#.utf8) + Data([0x0A])
    try sendAll(fd: clientFD2, data: request)
    let recovery = try readLineJSON(fd: clientFD2, timeout: 1.0)
    XCTAssertEqual(recovery?.status, 200)
  }

  func testProxyRejectsOversizedBody() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let hugeBody = String(repeating: "x", count: ControlAttachProxyServer.maxBodyBytes + 1)
    let line =
      #"{"method":"POST","path":"/debug/actions","body":"\#(hugeBody)"}"# + "\n"
    try sendAll(fd: clientFD, data: Data(line.utf8))

    let response = try readLineJSON(fd: clientFD, timeout: 1.0)
    XCTAssertEqual(response?.status, 413)
  }

  func testProxyRejectsMalformedJSON() throws {
    let upstream = try FakeUpstreamServer(
      response: (
        status: 200,
        body: Data(#"{"ok":true}"#.utf8)
      )
    ).start()
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD,
      allowedRootPID: nil)
    defer { proxy.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    let clientFD = try connectNoSigPipe(socketPath: proxy.socketPath)
    defer { Darwin.close(clientFD) }

    let request = Data(#"{not json}"#.utf8) + Data([0x0A])
    try sendAll(fd: clientFD, data: request)

    let response = try readLineJSON(fd: clientFD, timeout: 1.0)
    XCTAssertEqual(response?.status, 400)
  }

  private func readLineJSON(fd: Int32, timeout: TimeInterval) throws -> LiveControlAttachResponse? {
    let data = try readAvailable(fd: fd, timeout: timeout)
    guard let newline = data.firstIndex(of: 0x0A) else { return nil }
    return try JSONDecoder().decode(LiveControlAttachResponse.self, from: data[..<newline])
  }
}

// MARK: - Helpers

private func sendAll(fd: Int32, data: Data) throws {
  try data.withUnsafeBytes { raw in
    guard let base = raw.baseAddress else { return }
    var sent = 0
    while sent < raw.count {
      let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      sent += n
    }
  }
}

private func readLine(fd: Int32) throws -> Data? {
  var buffer = [UInt8](repeating: 0, count: 4096)
  var data = Data()
  while data.count < 1024 * 1024 {
    let n = recv(fd, &buffer, buffer.count, 0)
    if n < 0 && errno == EINTR { continue }
    if n == 0 { return nil }
    guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    data.append(contentsOf: buffer[0..<n])
    if let newline = data.firstIndex(of: 0x0A) {
      return data[..<newline]
    }
  }
  return nil
}

private func connectNoSigPipe(socketPath: String) throws -> Int32 {
  let fd = try ControlUDSClient.connect(socketPath: socketPath)
  try ControlFD.setNoSigPipe(fd)
  return fd
}

private func readAvailable(fd: Int32, timeout: TimeInterval) throws -> Data {
  var buffer = [UInt8](repeating: 0, count: 4096)
  var data = Data()
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let remaining = deadline.timeIntervalSinceNow
    let milliseconds = max(0, Int32(remaining * 1000))
    let ready = poll(&pfd, 1, milliseconds)
    if ready < 0 {
      if errno == EINTR { continue }
      break
    }
    if ready == 0 { break }

    let n = recv(fd, &buffer, buffer.count, 0)
    if n < 0 {
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { continue }
      break
    }
    if n == 0 { break }
    data.append(contentsOf: buffer[0..<n])
  }
  return data
}

/// Minimal HTTP/1.1 server that accepts one connection and returns a fixed
/// response for every request. Used as a fake upstream for proxy tests.
private final class FakeUpstreamServer {
  let response: (status: Int, body: Data)
  private var socketPath: String?
  private var listenerFD: Int32 = -1
  private var thread: Thread?
  private let requestLock = NSLock()

  var clientFD: Int32 = -1
  private(set) var requestCount = 0
  private(set) var requestPaths: [String] = []

  init(response: (status: Int, body: Data) = (200, Data())) {
    self.response = response
  }

  func start() throws -> FakeUpstreamServer {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "laban-fake-upstream-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let path = tempDir.appendingPathComponent("upstream.sock").path
    self.socketPath = path

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    self.listenerFD = listener

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (index, byte) in pathBytes.enumerated() where index < dest.count {
        dest[index] = UInt8(bitPattern: byte)
      }
    }
    let _ = unlink(path)
    guard
      Darwin.bind(
        listener,
        withUnsafePointer(to: &addr) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        },
        socklen_t(MemoryLayout<sockaddr_un>.size)) == 0,
      Darwin.listen(listener, 1) == 0
    else {
      Darwin.close(listener)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let thread = Thread { [weak self] in self?.acceptLoop() }
    thread.start()
    self.thread = thread

    self.clientFD = try ControlUDSClient.connect(socketPath: path)
    return self
  }

  func stop() {
    if clientFD >= 0 {
      Darwin.close(clientFD)
      clientFD = -1
    }
    if listenerFD >= 0 {
      let fd = listenerFD
      listenerFD = -1
      Darwin.close(fd)
    }
    if let socketPath { unlink(socketPath) }
    thread = nil
  }

  private func acceptLoop() {
    var clientAddr = sockaddr_un()
    var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
      Darwin.accept(
        listenerFD,
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 },
        &clientLen)
    }
    guard fd >= 0 else { return }
    defer { Darwin.close(fd) }
    try? ControlFD.setNoSigPipe(fd)

    let http = """
      HTTP/1.1 \(response.status) OK\r\n\
      Content-Type: application/json\r\n\
      Content-Length: \(response.body.count)\r\n\
      Connection: keep-alive\r\n\r\n
      """

    while true {
      // Drain the HTTP request until the blank line.
      var buffer = [UInt8](repeating: 0, count: 4096)
      var header = Data()
      while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { return }
        header.append(contentsOf: buffer[0..<n])
        if header.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil { break }
      }

      if let newline = header.firstIndex(of: 0x0A),
        let line = String(data: header[..<newline], encoding: .utf8)
      {
        let parts = line.split(separator: " ")
        if parts.count >= 2 {
          requestLock.withLock {
            requestPaths.append(String(parts[1]))
            requestCount += 1
          }
        }
      }

      var payload = Data(http.utf8)
      payload.append(response.body)
      payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
          let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
          if n < 0 && errno == EINTR { continue }
          guard n > 0 else { return }
          sent += n
        }
      }
    }
  }
}
