import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanControl

final class ApprovedSessionTokenTierSwitchTests: XCTestCase {

  func testApprovedSessionGrantsOnlyItsCapabilities() {
    let granted = LabanControlPolicy.grants(
      for: .approvedSession(
        sessionID: "s1",
        approvalID: "a1",
        capabilities: [.observe, .navigate],
        constraint: ControlTokenConstraint(
          method: "GET",
          path: "/debug/state",
          query: "",
          bodySHA256: nil,
          resolvedRouteID: "GET /debug/state",
          resolvedIntentID: "app.state")))
    XCTAssertEqual(granted, Set([.observe, .navigate]))
  }

  func testApprovedSessionTokenScopeIsSession() {
    let scope = LabanControlPolicy.tokenScope(
      for: .approvedSession(
        sessionID: "s1",
        approvalID: "a1",
        capabilities: [.observe],
        constraint: ControlTokenConstraint(
          method: "GET",
          path: "/debug/state",
          query: "",
          bodySHA256: nil,
          resolvedRouteID: "GET /debug/state",
          resolvedIntentID: "app.state")))
    XCTAssertEqual(scope, .session("s1"))
  }

  func testApprovedSessionAuthorizeRequiresMatchingConstraint() {
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
    XCTAssertTrue(
      LabanControlPolicy.authorize(
        intentID: "app.state",
        catalog: catalog,
        granted: [.observe],
        targetSession: "s1",
        tokenScope: .session("s1"),
        tokenTier: tier,
        method: "GET",
        path: "/debug/state",
        query: "",
        bodySHA256: nil))
    XCTAssertFalse(
      LabanControlPolicy.authorize(
        intentID: "app.state",
        catalog: catalog,
        granted: [.observe],
        targetSession: "s1",
        tokenScope: .session("s1"),
        tokenTier: tier,
        method: "GET",
        path: "/debug/accessibility",
        query: "",
        bodySHA256: nil))
  }

  func testApprovedSessionResolvesDebugStateRoute() {
    let request = ControlHTTPRequest(
      method: "GET",
      path: "/debug/state",
      query: [:],
      pathParameters: [:],
      body: Data())
    let routes = ControlRouteCatalog.routes.filter {
      $0.match(method: "GET", path: "/debug/state") != nil
    }
    guard let route = routes.first else {
      XCTFail("missing /debug/state route")
      return
    }
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
    switch route.resolveIntentID(request, tier) {
    case .resolved("app.state"):
      break
    default:
      XCTFail("expected app.state for approvedSession")
    }
  }
}
