import Darwin
import Foundation
import LabanControl
import XCTest

@testable import LabanAgent

/// Bug-hunt 2026-10-05 finding #8: `ControlUDSClient.request(fd:)` maps every
/// recv failure (peer EOF, SO_RCVTIMEO expiry) to `(-1, Data())` instead of
/// throwing, so `ControlAttachProxyServer.forwardRequest` never throws on a
/// dead or slow upstream. Each test below wraps the correct-behavior assertion
/// in `XCTExpectFailure` so the suite stays green while the defect exists and
/// turns red ("expected failure but none recorded") once it is fixed.
final class BugHuntBug8ProxyUpstreamLossTests: XCTestCase {

  /// The client must not report an upstream EOF as a parsed HTTP response.
  func testBug8_ControlUDSClientReturnsMinusOneInsteadOfThrowingOnUpstreamEOF() throws {
    let upstream = try ScriptedUpstream { _, _ in .close }
    defer { upstream.stop() }

    var result: (status: Int, body: Data)?
    var thrown: Error?
    do {
      result = try ControlUDSClient.request(
        fd: upstream.clientFD, path: "/debug/state", timeout: 2, keepConnectionOpen: true)
    } catch {
      thrown = error
    }
    XCTExpectFailure("bug #8: upstream EOF is reported as status -1, not thrown")
    XCTAssertNotNil(
      thrown,
      "upstream EOF must throw; got status \(String(describing: result?.status))")
  }

  /// A dead upstream must surface as 502 to the proxy client and fire
  /// `onUpstreamLost` (which `laban-agent run` wires to child termination).
  func testBug8_ProxyNeverFiresOnUpstreamLostWhenUpstreamEOFs() throws {
    let upstream = try ScriptedUpstream { _, _ in .close }
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(upstreamFD: upstream.clientFD, allowedRootPID: nil)
    defer { proxy.stop() }
    let lost = LockedFlag()
    proxy.onUpstreamLost = { lost.set() }

    let response = try roundTrip(proxy: proxy, path: "/debug/state", timeout: 3)

    XCTExpectFailure("bug #8: EOF yields a status:-1 response and onUpstreamLost never fires")
    XCTAssertEqual(response?.status, 502, "dead upstream must be reported as 502")
    XCTAssertTrue(lost.value, "onUpstreamLost must fire when the upstream hits EOF")
  }

  /// An upstream slower than the 5 s recv timeout must not leak its late
  /// response to the NEXT proxied request on the shared upstream fd.
  func testBug8_SlowUpstreamResponseIsDeliveredToTheNextClient() throws {
    let upstream = try ScriptedUpstream { index, path in
      index == 0
        ? .respond(delay: 5.6, body: #"{"answer":"\#(path)"}"#)
        : .respond(delay: 0, body: #"{"answer":"\#(path)"}"#)
    }
    defer { upstream.stop() }

    let proxy = try ControlAttachProxyServer(upstreamFD: upstream.clientFD, allowedRootPID: nil)
    defer { proxy.stop() }

    let first = try roundTrip(proxy: proxy, path: "/first", timeout: 8)
    // Let the late response for /first land in the upstream socket buffer.
    Thread.sleep(forTimeInterval: 1.0)
    let second = try roundTrip(proxy: proxy, path: "/second", timeout: 3)

    XCTAssertEqual(first?.status, -1, "precondition: the slow request timed out as status -1")
    XCTExpectFailure("bug #8: the next client receives the previous request's late response")
    XCTAssertEqual(
      second?.body, #"{"answer":"/second"}"#,
      "the /second client got \(second?.body ?? "nil") (status \(second?.status ?? 0))")
  }

  // MARK: - Helpers

  private func roundTrip(
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
      var index = 0
      var pending = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        while pending.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) == nil {
          let n = recv(peer, &buffer, buffer.count, 0)
          if n <= 0 { return }
          pending.append(contentsOf: buffer[0..<n])
        }
        let end = pending.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))!.upperBound
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
  }
}
