import Foundation
import LabanCore
import XCTest

final class CommandProposalRoutingTests: XCTestCase {
  override func setUp() {
    super.setUp()
    CommandProposalStore.shared.resetForTesting()
  }

  func testScopedSessionRequestForDifferentTargetReturns403() throws {
    let response = CommandProposalRouting.handle(
      body: body(targetSessionID: "B", command: "echo hi"),
      scopedSessionID: "A",
      sessionExists: { _ in true },
      activeSessionID: { "A" })
    XCTAssertEqual(response.status, 403)
  }

  func testScopedSessionRequestWithOmittedTargetUsesScopedSessionNotActive() throws {
    let response = CommandProposalRouting.handle(
      body: body(targetSessionID: nil, command: "echo hi"),
      scopedSessionID: "A",
      sessionExists: { sessionID in sessionID == "A" },
      // Deliberately different from scopedSessionID to prove the scoped
      // caller does not fall back to the app-wide active session.
      activeSessionID: { "OTHER" })
    XCTAssertEqual(response.status, 200)
    let decoded = try JSONDecoder().decode(CommandProposeResponse.self, from: response.body)
    XCTAssertEqual(decoded.targetSessionID, "A")
  }

  func testScopedSessionRequestForSameTargetSucceeds() throws {
    let response = CommandProposalRouting.handle(
      body: body(targetSessionID: "A", command: "echo hi"),
      scopedSessionID: "A",
      sessionExists: { sessionID in sessionID == "A" },
      activeSessionID: { "A" })
    XCTAssertEqual(response.status, 200)
    let decoded = try JSONDecoder().decode(CommandProposeResponse.self, from: response.body)
    XCTAssertEqual(decoded.targetSessionID, "A")
  }

  func testUnscopedRequestBehaviorIsUnchanged() throws {
    // scopedSessionID nil (whole-app/fixture surface): explicit target is
    // honored, and omitted target still falls back to activeSessionID.
    let explicit = CommandProposalRouting.handle(
      body: body(targetSessionID: "B", command: "echo hi"),
      scopedSessionID: nil,
      sessionExists: { sessionID in sessionID == "B" },
      activeSessionID: { "A" })
    XCTAssertEqual(explicit.status, 200)
    let explicitDecoded = try JSONDecoder().decode(
      CommandProposeResponse.self, from: explicit.body)
    XCTAssertEqual(explicitDecoded.targetSessionID, "B")

    let fallback = CommandProposalRouting.handle(
      body: body(targetSessionID: nil, command: "echo hi"),
      scopedSessionID: nil,
      sessionExists: { sessionID in sessionID == "A" },
      activeSessionID: { "A" })
    XCTAssertEqual(fallback.status, 200)
    let fallbackDecoded = try JSONDecoder().decode(
      CommandProposeResponse.self, from: fallback.body)
    XCTAssertEqual(fallbackDecoded.targetSessionID, "A")
  }

  private func body(targetSessionID: String?, command: String) -> Data {
    var payload: [String: Any] = ["action": "propose", "command": command, "purpose": "test"]
    if let targetSessionID {
      payload["targetSessionID"] = targetSessionID
    }
    return try! JSONSerialization.data(withJSONObject: payload)
  }
}
