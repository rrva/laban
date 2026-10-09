import Darwin
import Foundation
import LabanControl
import XCTest

@testable import LabanAgent

/// Regression tests for issue #37: an upstream that closes, resets, or answers
/// too late must surface as a lost upstream, never as a `status: -1` response
/// and never as a late response handed to the next request on the shared fd.
final class ControlAttachProxyUpstreamLossTests: XCTestCase {

  func testClientThrowsConnectionClosedWhenUpstreamClosesBeforeResponding() throws {
    let upstream = try ScriptedUpstream { _, _ in .close }
    defer { upstream.stop() }

    XCTAssertThrowsError(
      try ControlUDSClient.request(
        fd: upstream.clientFD, path: "/debug/state", timeout: 2, keepConnectionOpen: true)
    ) { error in
      XCTAssertEqual(error as? ControlUDSClientError, .connectionClosedBeforeResponse)
    }
  }

  func testClientThrowsTimedOutAndNeverReadsTheLateResponseOnTheNextRequest() throws {
    let upstream = try ScriptedUpstream { _, path in
      .respond(delay: path == "/first" ? 0.8 : 0, body: #"{"answer":"\#(path)"}"#)
    }
    defer { upstream.stop() }

    XCTAssertThrowsError(
      try ControlUDSClient.request(
        fd: upstream.clientFD, path: "/first", timeout: 0.3, keepConnectionOpen: true)
    ) { error in
      XCTAssertEqual(error as? ControlUDSClientError, .responseTimedOut)
    }

    // Let the late /first response land in the socket buffer.
    Thread.sleep(forTimeInterval: 0.8)

    do {
      let second = try ControlUDSClient.request(
        fd: upstream.clientFD, path: "/second", timeout: 1, keepConnectionOpen: true)
      XCTFail("a timed-out connection must not be reused; got \(second)")
    } catch {
      // Expected: the timeout poisoned the connection.
    }
  }

  func testProxyAnswers502AndFiresOnUpstreamLostWhenUpstreamCloses() throws {
    let upstream = try ScriptedUpstream { _, _ in .close }
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(upstreamFD: upstream.clientFD, allowedRootPID: nil)
    defer { proxy.stop() }
    let lost = LockedFlag()
    proxy.onUpstreamLost = { lost.set() }

    let response = try proxyRoundTrip(proxy: proxy, path: "/debug/state", timeout: 3)

    XCTAssertEqual(response?.status, 502, "a dead upstream must be reported as 502")
    XCTAssertTrue(lost.value, "onUpstreamLost must fire when the upstream closes")
  }

  func testProductionUpstreamTimeoutOutlastsTheSlowestLegitimateHandler() {
    // A timeout loses the upstream and terminates the agent child, so it must
    // only fire on a dead app. `/debug/window-screenshot` may wait 5 s on each
    // of two ScreenCaptureKit bridges before answering 503 on its own.
    let slowestLegitimateHandlerSeconds: TimeInterval = 2 * 5
    XCTAssertGreaterThan(
      ProxyLimits.production.upstreamResponseTimeoutSeconds,
      slowestLegitimateHandlerSeconds * 2)
  }

  func testProxyNeverHandsALateUpstreamResponseToTheNextClient() throws {
    let upstream = try ScriptedUpstream { index, path in
      .respond(delay: index == 0 ? 0.8 : 0, body: #"{"answer":"\#(path)"}"#)
    }
    defer { upstream.stop() }

    let limits = ProxyLimits(
      maxLineBytes: 64 * 1024,
      maxBodyBytes: 32 * 1024,
      maxConcurrentClients: 16,
      maxQueueDepth: 64,
      clientIdleSeconds: 60,
      heartbeatIntervalSeconds: 30,
      upstreamResponseTimeoutSeconds: 0.3)
    let proxy = try ControlAttachProxyServer(
      upstreamFD: upstream.clientFD, allowedRootPID: nil, limits: limits)
    defer { proxy.stop() }
    let lost = LockedFlag()
    proxy.onUpstreamLost = { lost.set() }

    let first = try proxyRoundTrip(proxy: proxy, path: "/first", timeout: 3)
    // Let the late /first response land in the upstream socket buffer.
    Thread.sleep(forTimeInterval: 0.8)
    let second = try proxyRoundTrip(proxy: proxy, path: "/second", timeout: 3)

    XCTAssertEqual(first?.status, 502, "a timed-out upstream request must be reported as 502")
    XCTAssertTrue(lost.value, "an upstream timeout must fire onUpstreamLost")
    XCTAssertEqual(
      second?.status, 502,
      "the /second client got \(second?.body ?? "nil") (status \(second?.status ?? 0))")
    XCTAssertNotEqual(second?.body, #"{"answer":"/first"}"#)
  }

  // MARK: - Helpers

  private func proxyRoundTrip(
    proxy: ControlAttachProxyServer, path: String, timeout: TimeInterval
  ) throws -> LiveControlAttachResponse? {
    let fd = try ControlUDSClient.connect(socketPath: proxy.socketPath)
    defer { Darwin.close(fd) }
    try ControlFD.setNoSigPipe(fd)
    let line = Data(#"{"method":"GET","path":"\#(path)"}"#.utf8) + Data([0x0A])
    _ = line.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    var data = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, data.firstIndex(of: 0x0A) == nil {
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pfd, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000))
      if ready <= 0 { break }
      let n = recv(fd, &buffer, buffer.count, 0)
      if n <= 0 { break }
      data.append(contentsOf: buffer[0..<n])
    }
    guard let newline = data.firstIndex(of: 0x0A) else { return nil }
    return try JSONDecoder().decode(LiveControlAttachResponse.self, from: data[..<newline])
  }
}

private final class LockedFlag {
  private let lock = NSLock()
  private var flag = false
  func set() { lock.withLock { flag = true } }
  var value: Bool { lock.withLock { flag } }
}

/// A socketpair-backed fake upstream that scripts a reply per request.
private final class ScriptedUpstream {
  enum Action {
    case close
    case respond(delay: TimeInterval, body: String)
  }

  let clientFD: Int32
  private let peerFD: Int32
  private let thread: Thread

  init(script: @escaping (_ index: Int, _ path: String) -> Action) throws {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    clientFD = fds[0]
    peerFD = fds[1]
    try ControlFD.setNoSigPipe(fds[0])
    try ControlFD.setNoSigPipe(fds[1])
    let peer = fds[1]
    thread = Thread {
      let headerEnd = Data([0x0D, 0x0A, 0x0D, 0x0A])
      var index = 0
      var pending = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        while pending.range(of: headerEnd) == nil {
          let n = recv(peer, &buffer, buffer.count, 0)
          if n <= 0 { return }
          pending.append(contentsOf: buffer[0..<n])
        }
        guard let end = pending.range(of: headerEnd)?.upperBound else { return }
        let head = String(data: pending[..<end], encoding: .utf8) ?? ""
        pending.removeSubrange(..<end)
        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        switch script(index, path) {
        case .close:
          Darwin.shutdown(peer, SHUT_RDWR)
          return
        case .respond(let delay, let body):
          if delay > 0 { Thread.sleep(forTimeInterval: delay) }
          let bytes = Data(body.utf8)
          var payload = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: keep-alive\r\n\r\n"
              .utf8)
          payload.append(bytes)
          _ = payload.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
        }
        index += 1
      }
    }
    thread.start()
  }

  func stop() {
    Darwin.shutdown(peerFD, SHUT_RDWR)
    Darwin.close(peerFD)
    Darwin.close(clientFD)
  }
}
