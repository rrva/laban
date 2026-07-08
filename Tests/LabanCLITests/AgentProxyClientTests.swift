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
}
