import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanControl

final class ApprovedSessionStateRedactionTests: XCTestCase {

  func testApprovedSessionStateUsesSessionRedaction() {
    let server = LabanControlServer(router: RedactionSpyRouter(), surface: .headless)
    let tier: ControlTokenTier = .approvedSession(
      sessionID: "s1",
      approvalID: "a1",
      capabilities: [.observe],
      constraint: ControlTokenConstraint(
        method: "GET",
        path: "/debug/state",
        query: "",
        bodySHA256: nil,
        resolvedRouteID: "GET /debug/state",
        resolvedIntentID: "app.state"))
    let input = server.legacyQueryInput(
      intentID: "app.state",
      params: ["sessionID": "s1"],
      tokenTier: tier)
    XCTAssertEqual(input.scopedSessionID, "s1")
    XCTAssertEqual(input.readRedaction, .sessionObserveSummary)
  }

  func testApprovedSessionDifferentSessionIDIsRejectedByPolicy() {
    let catalog = IntentCatalog.all
    let tier: ControlTokenTier = .approvedSession(
      sessionID: "s1",
      approvalID: "a1",
      capabilities: [.observe],
      constraint: ControlTokenConstraint(
        method: "GET",
        path: "/debug/state",
        query: "",
        bodySHA256: nil,
        resolvedRouteID: "GET /debug/state",
        resolvedIntentID: "app.state"))
    XCTAssertFalse(
      LabanControlPolicy.authorize(
        intentID: "app.state",
        catalog: catalog,
        granted: [.observe],
        targetSession: "s2",
        tokenScope: .session("s1"),
        tokenTier: tier,
        method: "GET",
        path: "/debug/state",
        query: "",
        bodySHA256: nil))
  }
}

private final class RedactionSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
