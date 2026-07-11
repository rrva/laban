import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanCLI

final class LazyAttachCLITests: XCTestCase {

  func testBrokerPresentPathStillUsesProxy() {
    var proxyCalled = false
    let agentProxyRequest: (String, AgentProxyEnvelope) throws -> (Int, String) = { _, _ in
      proxyCalled = true
      return (200, "{\"ok\":true}")
    }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      agentProxyRequest: agentProxyRequest,
      agentProxyURL: "unix:///tmp/proxy.sock")
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(proxyCalled)
  }

  func testBrokerMissingFallsBackToLazyAttach() {
    var lazyCalled = false
    let lazyAttachRequest:
      (String, String, String, [String: String], String?) throws -> (Int, String) = {
        cliCommand, method, path, _, _ in
        lazyCalled = true
        XCTAssertEqual(cliCommand, "session.state")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(path, "/debug/state")
        return (
          200,
          "{\"ok\":true,\"sessionID\":\"s1\",\"approval\":\"once\",\"downstreamStatus\":200,\"downstreamBody\":\"{\\\"ok\\\":true}\"}"
        )
      }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      lazyAttachRequest: lazyAttachRequest)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(lazyCalled)
    XCTAssertFalse(result.stderr.contains("LABAN_AGENT_CONTROL_URL"))
  }

  func testSessionProxyRequiresBroker() {
    let result = LabanCLI.run(command: .sessionProxy)
    XCTAssertEqual(result.exitCode, 3)
    XCTAssertTrue(result.stderr.contains("broker"))
  }

  func testDenialMapsToExitCode5() {
    let lazyAttachRequest:
      (String, String, String, [String: String], String?) throws -> (Int, String) = {
        _, _, _, _, _ in
        throw LazyAttachClientError.denied("user denied")
      }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      lazyAttachRequest: lazyAttachRequest)
    XCTAssertEqual(result.exitCode, 5)
  }

  func testTimeoutMapsToExitCode4() {
    let lazyAttachRequest:
      (String, String, String, [String: String], String?) throws -> (Int, String) = {
        _, _, _, _, _ in
        throw LazyAttachClientError.timeout("approval timed out")
      }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      lazyAttachRequest: lazyAttachRequest)
    XCTAssertEqual(result.exitCode, 4)
  }

  func testSessionChangedMapsToExitCode5() {
    let lazyAttachRequest:
      (String, String, String, [String: String], String?) throws -> (Int, String) = {
        _, _, _, _, _ in
        throw LazyAttachClientError.sessionChanged("identity swapped mid-approval")
      }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      lazyAttachRequest: lazyAttachRequest)
    XCTAssertEqual(result.exitCode, 5)
  }

  func testRateLimitedMapsToExitCode5() {
    let lazyAttachRequest:
      (String, String, String, [String: String], String?) throws -> (Int, String) = {
        _, _, _, _, _ in
        throw LazyAttachClientError.rateLimited("too many pending requests")
      }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      lazyAttachRequest: lazyAttachRequest)
    XCTAssertEqual(result.exitCode, 5)
  }

  func testSessionCommandsIgnoreLABANSessionAttach() {
    let lazyAttachRequest:
      (String, String, String, [String: String], String?) throws -> (Int, String) = {
        _, _, _, _, _ in
        return (
          200,
          "{\"ok\":true,\"sessionID\":\"s1\",\"approval\":\"once\",\"downstreamStatus\":200,\"downstreamBody\":\"{}\"}"
        )
      }
    setenv("LABAN_SESSION_ATTACH", "bootstrap-secret", 1)
    defer { unsetenv("LABAN_SESSION_ATTACH") }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      lazyAttachRequest: lazyAttachRequest)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains("bootstrap-secret"))
    XCTAssertFalse(result.stderr.contains("bootstrap-secret"))
  }

  // MARK: - splitPathAndQuery

  func testSplitPathAndQueryWithNoQuery() {
    let (path, query) = LabanCLI.splitPathAndQuery("/debug/text")
    XCTAssertEqual(path, "/debug/text")
    XCTAssertEqual(query, [:])
  }

  func testSplitPathAndQueryWithSinglePair() {
    let (path, query) = LabanCLI.splitPathAndQuery("/debug/text?source=screen")
    XCTAssertEqual(path, "/debug/text")
    XCTAssertEqual(query, ["source": "screen"])
  }

  func testSplitPathAndQueryWithMultiplePairs() {
    let (path, query) = LabanCLI.splitPathAndQuery(
      "/debug/text?source=scrollback&startLine=0&endLine=9&maxLines=50")
    XCTAssertEqual(path, "/debug/text")
    XCTAssertEqual(
      query,
      ["source": "scrollback", "startLine": "0", "endLine": "9", "maxLines": "50"])
  }

  func testSplitPathAndQueryWithPairMissingEquals() {
    // Total: a malformed pair with no "=" maps to an empty-string value
    // rather than crashing or dropping the key.
    let (path, query) = LabanCLI.splitPathAndQuery("/debug/text?source=screen&malformed")
    XCTAssertEqual(path, "/debug/text")
    XCTAssertEqual(query, ["source": "screen", "malformed": ""])
  }

  func testSessionGetTextLazyLegSplitsQueryFromPath() {
    var capturedPath: String?
    var capturedQuery: [String: String]?
    let result = LabanCLI.run(
      command: .sessionGetText(
        source: "scrollback", startLine: 0, endLine: 9, maxLines: 50, json: true),
      lazyAttachRequest: { _, _, path, query, _ in
        capturedPath = path
        capturedQuery = query
        return (200, "{\"ok\":true}")
      })

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(capturedPath, "/debug/text")
    XCTAssertEqual(
      capturedQuery,
      ["source": "scrollback", "startLine": "0", "endLine": "9", "maxLines": "50"])
  }

  func testNoTokenInStderr() {
    let lazyAttachRequest:
      (String, String, String, [String: String], String?) throws -> (Int, String) = {
        _, _, _, _, _ in
        throw LazyAttachClientError.denied("denied")
      }
    setenv("LABAN_SESSION_ATTACH", "secret-token", 1)
    defer { unsetenv("LABAN_SESSION_ATTACH") }
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      lazyAttachRequest: lazyAttachRequest)
    XCTAssertFalse(result.stderr.contains("secret-token"))
    XCTAssertFalse(result.stdout.contains("secret-token"))
  }
}
