import Foundation
import XCTest

@testable import LabanCLI

final class AgentProxyClientTests: XCTestCase {
  func testStateRequestEnvelope() {
    let envelope = AgentProxyClient.stateRequest()
    XCTAssertEqual(envelope.method, "GET")
    XCTAssertEqual(envelope.path, "/debug/state")
    XCTAssertNil(envelope.body)
  }

  func testScrollRequestEnvelope() {
    let envelope = AgentProxyClient.scrollRequest(rows: -40)
    XCTAssertEqual(envelope.method, "POST")
    XCTAssertEqual(envelope.path, "/debug/actions")
    XCTAssertEqual(envelope.body, "{\"action\":\"scrollViewport\",\"deltaRows\":-40}")
  }

  func testProposeSingleArgumentUsesExactCommand() {
    let envelope = AgentProxyClient.proposeRequest(
      purpose: "Inspect repository state",
      command: ["git status --short"])
    XCTAssertEqual(envelope.method, "POST")
    XCTAssertEqual(envelope.path, "/debug/actions")
    XCTAssertTrue(envelope.body?.contains("\"action\":\"propose\"") ?? false)
    XCTAssertTrue(envelope.body?.contains("\"command\":\"git status --short\"") ?? false)
    XCTAssertTrue(envelope.body?.contains("\"purpose\":\"Inspect repository state\"") ?? false)
  }

  func testProposeMultipleArgumentsJoinsWithSingleQuoteEscaping() {
    let envelope = AgentProxyClient.proposeRequest(
      purpose: "Echo with space",
      command: ["echo", "a b", "it's"])
    XCTAssertTrue(envelope.body?.contains("\"command\":\"echo 'a b' 'it'\\\\''s'\"") ?? false)
  }

  func testParseProxyResponse() throws {
    let json = #"{"path":"/debug/state","status":200,"body":"{\"ok\":true}"}"#
    let response = try JSONDecoder().decode(AgentProxyResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.path, "/debug/state")
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, "{\"ok\":true}")
  }

  /// The proxy rejects a forbidden peer, a busy proxy, or an oversized line by
  /// writing one error line and closing without reading the rest of the
  /// request. The client's send then fails with EPIPE, but the proxy's answer
  /// is already in the receive buffer and is what the caller needs to see.
  func testSendReturnsProxyRejectionWhenProxyClosesBeforeReadingRequest() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-proxy-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("p.sock").path
    let listener = try bindListener(path: path)
    defer { Darwin.close(listener) }

    let served = expectation(description: "proxy rejected the peer")
    Thread.detachNewThread {
      defer { served.fulfill() }
      let fd = Darwin.accept(listener, nil, nil)
      guard fd >= 0 else { return }
      let line = Array(#"{"body":"forbidden","path":"","status":403}"#.utf8) + [0x0A]
      _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      Darwin.close(fd)
    }

    // A request far larger than the socket buffers, so the client is still
    // sending when the proxy closes: EPIPE is certain, not a race.
    let request = AgentProxyEnvelope(
      method: "POST", path: "/debug/actions", body: String(repeating: "x", count: 1 << 20))
    let response = try AgentProxyClient.send(proxyURL: path, request: request)
    wait(for: [served], timeout: 5)

    XCTAssertEqual(response.status, 403)
    XCTAssertEqual(response.body, "forbidden")
  }

  private func bindListener(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (index, byte) in bytes.enumerated() where index < dest.count {
        dest[index] = UInt8(bitPattern: byte)
      }
    }
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(fd, 1) == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return fd
  }
}
