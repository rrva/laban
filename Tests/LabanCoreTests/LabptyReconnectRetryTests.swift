import Darwin
import XCTest

@testable import LabanCore

/// Regression coverage for the labpty control client surviving a daemon that
/// force-closes an established connection mid-response. The daemon does this
/// when its single-threaded event loop stalls past the 250 ms idle deadline
/// while a response is staged but unflushed (`force-expiring established client
/// … write_total>0 write_sent=0`), which reaches the client as ECONNRESET even
/// though the daemon is alive and the socket is still bound. The client must
/// reconnect and replay idempotent control RPCs rather than surfacing the drop
/// (which, on the launch path, aborts the whole app), while never replaying a
/// mutating op like openSession (that would duplicate a session).
final class LabptyReconnectRetryTests: XCTestCase {
  /// An AF_UNIX server that hands each accepted connection to a per-connection
  /// handler (1-based index, fd), counting accepts so a test can prove how many
  /// times the client reconnected. The handler speaks just enough of the wire
  /// protocol to either drop the connection or answer a HELLO.
  private final class FakeLabptyServer {
    let path: String
    private let listenFd: Int32
    private let queue = DispatchQueue(label: "labpty.test.fake-daemon")
    private let lock = NSLock()
    private var accepts = 0
    private let handle: (Int, Int32) -> Void

    init(handle: @escaping (Int, Int32) -> Void) throws {
      self.handle = handle
      // Stay well under sockaddr_un.sun_path (104 bytes on macOS).
      path = "/tmp/lbt-\(UUID().uuidString.prefix(8)).sock"
      unlink(path)
      listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard listenFd >= 0 else { throw POSIXError(.EIO) }
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
        path.withCString { strcpy(dst, $0) }
      }
      let len = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFd, $0, len) }
      }
      guard bound == 0, listen(listenFd, 16) == 0 else {
        close(listenFd)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      queue.async { [self] in acceptLoop() }
    }

    private func acceptLoop() {
      while true {
        let fd = accept(listenFd, nil, nil)
        if fd < 0 { break }  // listen fd closed at teardown → stop
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        accepts += 1
        let index = accepts
        lock.unlock()
        handle(index, fd)
        close(fd)  // closing flushes any written response, then signals EOF
      }
    }

    var acceptCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return accepts
    }

    func stop() {
      close(listenFd)  // unblocks acceptLoop
      unlink(path)
    }

    /// Read one full client request frame from `fd`, or nil on EOF/short read.
    static func readRequestFrame(_ fd: Int32) -> LabptyFrame? {
      guard let header = readExact(fd, LabptyFrameHeader.headerByteCount) else { return nil }
      let bytes = [UInt8](header)
      let frameLen =
        Int(bytes[8]) | (Int(bytes[9]) << 8) | (Int(bytes[10]) << 16) | (Int(bytes[11]) << 24)
      guard frameLen >= LabptyFrameHeader.headerByteCount,
        frameLen <= LabptyFrameHeader.maxFrameBytes
      else { return nil }
      var full = header
      if frameLen > LabptyFrameHeader.headerByteCount {
        guard let rest = readExact(fd, frameLen - LabptyFrameHeader.headerByteCount) else {
          return nil
        }
        full.append(rest)
      }
      return try? LabptyFraming.decode(full)
    }

    /// Answer a request with a valid OK response echoing `seq`.
    static func sendOK(_ fd: Int32, sequence: UInt64, payload: Data = Data()) {
      guard
        let frame = try? LabptyFraming.encodeResponse(
          sequence: sequence, code: .ok, payload: payload)
      else { return }
      _ = writeAll(fd, frame)
    }

    /// Answer a HELLO with a valid, capability-complete response echoing `seq`.
    static func sendHelloOK(_ fd: Int32, sequence: UInt64) {
      guard let payload = try? LabptyHelloResponse().encode() else { return }
      sendOK(fd, sequence: sequence, payload: payload)
    }

    private static func readExact(_ fd: Int32, _ count: Int) -> Data? {
      var buf = [UInt8](repeating: 0, count: count)
      var got = 0
      while got < count {
        let n = buf.withUnsafeMutableBytes { raw -> Int in
          read(fd, raw.baseAddress!.advanced(by: got), count - got)
        }
        if n <= 0 { return nil }
        got += n
      }
      return Data(buf)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
      let bytes = [UInt8](data)
      var off = 0
      while off < bytes.count {
        let n = bytes.withUnsafeBytes { raw -> Int in
          write(fd, raw.baseAddress!.advanced(by: off), bytes.count - off)
        }
        if n <= 0 { return false }
        off += n
      }
      return true
    }
  }

  /// Minimal thread-safe counter shared between the server's background accept
  /// queue and the test thread.
  private final class AtomicInt {
    private let lock = NSLock()
    private var count = 0
    func increment() {
      lock.lock()
      count += 1
      lock.unlock()
    }
    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  func testIdempotentHelloReconnectsAndRetriesOnForceClose() throws {
    // Every connection is force-closed, so hello ultimately fails — but only
    // after exhausting reconnects, proving it did not give up on the first drop.
    let server = try FakeLabptyServer { _, fd in
      _ = FakeLabptyServer.readRequestFrame(fd)  // read, then close without answering
    }
    defer { server.stop() }
    let client = try LabptyTerminalSessionClient(
      socketPath: server.path, rpcTimeoutMilliseconds: 200)
    defer { client.close() }

    XCTAssertThrowsError(try client.hello())
    XCTAssertGreaterThan(
      server.acceptCount, 1,
      "hello must reconnect and retry on a force-close, not fail on the first drop")
  }

  func testHelloRecoversAfterOneForceCloseMidResponse() throws {
    // First connection drops after reading the request (the daemon's staged-but-
    // unsent force-expire); the second returns a valid HELLO. hello() must
    // recover — proving the client survives a reset and succeeds on the retry,
    // not merely that it tries again.
    let server = try FakeLabptyServer { index, fd in
      guard let req = FakeLabptyServer.readRequestFrame(fd) else { return }
      if index == 1 { return }  // force-close mid-response
      FakeLabptyServer.sendHelloOK(fd, sequence: req.header.sequence)
    }
    defer { server.stop() }
    let client = try LabptyTerminalSessionClient(
      socketPath: server.path, rpcTimeoutMilliseconds: 500)
    defer { client.close() }

    let response = try client.hello()
    XCTAssertEqual(response.protocolMajor, LabptyFrameHeader.abiMajor)
    XCTAssertEqual(
      server.acceptCount, 2,
      "hello must recover on the clean response after exactly one reconnect")
  }

  func testParkOutputWakeReconnectsAndRetriesOnForceClose() throws {
    let parks = AtomicInt()
    let server = try FakeLabptyServer { _, fd in
      while let req = FakeLabptyServer.readRequestFrame(fd) {
        switch req.header.operation {
        case .hello:
          FakeLabptyServer.sendHelloOK(fd, sequence: req.header.sequence)
        case .parkOutputWake:
          parks.increment()
          if parks.value == 1 { return }  // force-close mid-response
          let payload = LabptyOutputWakeParkResponse(parked: true).encode()
          FakeLabptyServer.sendOK(fd, sequence: req.header.sequence, payload: payload)
        default:
          return
        }
      }
    }
    defer { server.stop() }
    let client = try LabptyTerminalSessionClient(
      socketPath: server.path, rpcTimeoutMilliseconds: 500)
    defer { client.close() }

    let response = try client.parkOutputWake(entries: [])
    XCTAssertTrue(response.parked)
    XCTAssertEqual(parks.value, 2, "parkOutputWake is idempotent and must replay after a drop")
    XCTAssertGreaterThan(server.acceptCount, 1)
  }

  func testOpenSessionDoesNotReplayOnForceClose() throws {
    // The daemon completes the hello, then force-closes the openSession. Count
    // openSession frames on the wire directly (not accepts, which would conflate
    // a hello reconnect with an op replay): a non-idempotent op must reach the
    // daemon exactly once and never be replayed — replaying could spawn a
    // duplicate shell.
    let opens = AtomicInt()
    let server = try FakeLabptyServer { _, fd in
      while let req = FakeLabptyServer.readRequestFrame(fd) {
        switch req.header.operation {
        case .hello:
          FakeLabptyServer.sendHelloOK(fd, sequence: req.header.sequence)
        case .openSession:
          opens.increment()
          return  // drop after counting; must never be replayed
        default:
          return
        }
      }
    }
    defer { server.stop() }
    let client = try LabptyTerminalSessionClient(
      socketPath: server.path, rpcTimeoutMilliseconds: 200)
    defer { client.close() }

    let request = LabptyOpenSessionRequest(
      rows: 24, cols: 80, argv: ["/bin/zsh"], envp: [], cwd: "", logicalSessionId: "")
    XCTAssertThrowsError(try client.openSession(request))
    XCTAssertEqual(
      opens.value, 1,
      "openSession must reach the daemon exactly once — never replayed after a drop")
    XCTAssertEqual(
      server.acceptCount, 1,
      "with the hello completing on the first connection, openSession needs no reconnect")
  }

  func testOpenSessionRecoversImplicitHelloButDoesNotReplayTheOpen() throws {
    // Connection 1 drops during the *implicit* hello negotiation that precedes
    // openSession. Connection 2 completes the hello, then the openSession is
    // dropped. The negotiation hello must be retried (we must reach connection
    // 2), while the openSession itself must never replay. Before the fix the
    // implicit hello ran under .openSession's non-retryable policy, so the
    // connection-1 negotiation drop was fatal and acceptCount stayed at 1.
    let opens = AtomicInt()
    let server = try FakeLabptyServer { index, fd in
      guard let req = FakeLabptyServer.readRequestFrame(fd) else { return }
      if index == 1 { return }  // drop during negotiation
      guard req.header.operation == .hello else { return }
      FakeLabptyServer.sendHelloOK(fd, sequence: req.header.sequence)
      let next = FakeLabptyServer.readRequestFrame(fd)
      if next?.header.operation == .openSession {
        opens.increment()  // count the open, then drop it (must not be replayed)
      }
    }
    defer { server.stop() }
    let client = try LabptyTerminalSessionClient(
      socketPath: server.path, rpcTimeoutMilliseconds: 500)
    defer { client.close() }

    let request = LabptyOpenSessionRequest(
      rows: 24, cols: 80, argv: ["/bin/zsh"], envp: [], cwd: "", logicalSessionId: "")
    XCTAssertThrowsError(try client.openSession(request))
    XCTAssertEqual(
      server.acceptCount, 2,
      "the implicit hello must be retried across the negotiation drop")
    XCTAssertEqual(
      opens.value, 1,
      "openSession itself must reach the daemon exactly once — never replayed")
  }
}
