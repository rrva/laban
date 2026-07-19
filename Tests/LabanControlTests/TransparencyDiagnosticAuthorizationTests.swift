import Foundation
import LabanCore
import XCTest

@testable import LabanControl

final class TransparencyDiagnosticAuthorizationTests: XCTestCase {
  func testOnlyFixtureTierGrantsDiagnosticControl() {
    XCTAssertTrue(LabanControlPolicy.grants(for: .fixture).contains(.diagnosticControl))
    XCTAssertFalse(LabanControlPolicy.grants(for: .appObserve).contains(.diagnosticControl))
    XCTAssertFalse(
      LabanControlPolicy.grants(for: .sessionObserve(sessionID: "s"))
        .contains(.diagnosticControl))

    let constraint = ControlTokenConstraint(
      method: "POST",
      path: "/debug/actions",
      query: "",
      bodySHA256: nil,
      resolvedRouteID: "POST /debug/actions",
      resolvedIntentID: "transparency.setBackground")
    let forged = ControlTokenTier.approvedSession(
      sessionID: "s",
      approvalID: "forged",
      capabilities: [.diagnosticControl],
      constraint: constraint)
    XCTAssertFalse(LabanControlPolicy.grants(for: forged).contains(.diagnosticControl))
  }

  func testDiagnosticDescriptorsAreGUIAvailableWithoutBroadeningFixtureDescriptors() throws {
    for id in [
      "profile.capture",
      "transparency.setBackground",
      "transparency.diagnostics.reset",
      "transparency.reduceTransparencyOverride.set",
      "transparency.nativeFullScreen.set",
      "transparency.backgroundSource.set",
      "transparency.backgroundImageScaling.set",
      "transparency.backgroundImage.import",
      "transparency.backgroundImage.remove",
    ] {
      let descriptor = try XCTUnwrap(IntentCatalog.shared.descriptor(id: id))
      XCTAssertEqual(descriptor.requiredCapability, .diagnosticControl)
      XCTAssertTrue(descriptor.availability.gui)
    }
    XCTAssertFalse(
      ControlLazyAttachAllowlist.entries.contains { entry in
        entry.intentID.hasPrefix("transparency.")
      })
    XCTAssertFalse(ControlSessionObserveFamily.capabilities.contains(.diagnosticControl))
    XCTAssertFalse(
      ControlLazyAttachAllowlist.entries.contains { $0.intentID == "profile.capture" })
    XCTAssertFalse(ControlSessionObserveFamily.intentIDs.contains { $0.hasPrefix("transparency.") })
    XCTAssertNoThrow(
      try IntentCatalog.all.validate(endpointDescriptors: ControlRouteCatalog.endpoints))
  }

  func testGUIFixtureTokenRoutesProfileAndTransparencyActionsAndProjection() throws {
    let router = TransparencySpyRouter()
    let socketPath = "/tmp/laban-transparency-auth-\(UUID().uuidString.prefix(8)).sock"
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let bodies = [
      #"{"action":"captureProfile","samples":1,"intervalMilliseconds":1}"#,
      #"{"action":"setBackgroundTransparency","opacity":0.7,"applyToExplicitCellBackgrounds":false,"backdropStyle":"systemBlur"}"#,
      #"{"action":"resetTransparencyDiagnostics"}"#,
      #"{"action":"setReduceTransparencyOverride","enabled":true}"#,
      #"{"action":"setNativeFullScreen","enabled":true}"#,
      #"{"action":"setBackgroundSource","source":"image"}"#,
      #"{"action":"setBackgroundImageScaling","scaling":"fit"}"#,
      #"{"action":"importBackgroundImage","path":"fixtures/background.svg","scaling":"fill"}"#,
      #"{"action":"removeBackgroundImage"}"#,
    ]
    for body in bodies {
      let response = try ControlUDSClient.request(
        socketPath: socketPath,
        method: "POST",
        path: "/debug/actions",
        token: readiness.debugToken,
        body: Data(body.utf8))
      XCTAssertEqual(response.0, 200)
    }
    let state = try ControlUDSClient.request(
      socketPath: socketPath,
      method: "GET",
      path: "/debug/transparency",
      token: readiness.debugToken)
    XCTAssertEqual(state.0, 200)
    XCTAssertEqual(
      router.intentIDs,
      [
        "profile.capture",
        "transparency.setBackground",
        "transparency.diagnostics.reset",
        "transparency.reduceTransparencyOverride.set",
        "transparency.nativeFullScreen.set",
        "transparency.backgroundSource.set",
        "transparency.backgroundImageScaling.set",
        "transparency.backgroundImage.import",
        "transparency.backgroundImage.remove",
      ])
    XCTAssertEqual(router.queryIDs, ["transparency.state"])
  }

  func testLiveControlDeniesProfileCaptureToNonFixtureTiers() throws {
    let router = TransparencySpyRouter()
    let socketPath = "/tmp/laban-profile-auth-\(UUID().uuidString.prefix(8)).sock"
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let body = Data(
      #"{"action":"captureProfile","samples":1,"intervalMilliseconds":1}"#.utf8)
    let constraint = ControlTokenConstraint(
      method: "POST",
      path: "/debug/actions",
      query: "",
      bodySHA256: nil,
      resolvedRouteID: "POST /debug/actions",
      resolvedIntentID: "profile.capture")
    let deniedTokens: [(String, ControlTokenTier)] = [
      ("app-observe", .appObserve),
      ("session-observe", .sessionObserve(sessionID: "s")),
      (
        "forged-approved",
        .approvedSession(
          sessionID: "s",
          approvalID: "forged",
          capabilities: [.diagnosticControl],
          constraint: constraint)
      ),
    ]
    for (token, tier) in deniedTokens {
      server.registerToken(token, tier: tier)
      let response = try ControlUDSClient.request(
        socketPath: socketPath,
        method: "POST",
        path: "/debug/actions",
        token: token,
        body: body)
      XCTAssertEqual(response.0, 403, token)
    }

    let fixtureResponse = try ControlUDSClient.request(
      socketPath: socketPath,
      method: "POST",
      path: "/debug/actions",
      token: readiness.debugToken,
      body: body)
    XCTAssertEqual(fixtureResponse.0, 200)
    XCTAssertEqual(router.intentIDs, ["profile.capture"])
  }

  func testNativeFullScreenActionIsUnavailableHeadlessly() throws {
    let socketPath = "/tmp/laban-transparency-headless-\(UUID().uuidString.prefix(8)).sock"
    let server = LabanControlServer(router: TransparencySpyRouter(), surface: .headless)
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }
    let response = try ControlUDSClient.request(
      socketPath: socketPath,
      method: "POST",
      path: "/debug/actions",
      token: readiness.debugToken,
      body: Data(#"{"action":"setNativeFullScreen","enabled":true}"#.utf8))
    XCTAssertEqual(response.0, 404)
  }
}

private final class TransparencySpyRouter: IntentRouter {
  private(set) var intentIDs: [String] = []
  private(set) var queryIDs: [String] = []

  func route(_ intent: Intent) -> ControlResponse {
    intentIDs.append(intent.id)
    return ControlResponse(
      status: 200, contentType: "application/json", body: Data(#"{"ok":true}"#.utf8))
  }

  func query(_ query: Query) -> ControlResponse {
    .error(501, "unused")
  }

  func query(_ input: LegacyDebugQueryInput) -> ControlResponse {
    queryIDs.append(input.intentID)
    return ControlResponse(
      status: 200, contentType: "application/json", body: Data(#"{"ok":true}"#.utf8))
  }

  func control(_ input: LegacyDebugControlInput) -> ControlResponse {
    .error(501, "unused")
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
