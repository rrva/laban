import Foundation
import LabanControl
import LabanCore
import XCTest

final class LazyAttachPersistedApprovalScopeTests: XCTestCase {

  func testStateApprovalDoesNotAutoApproveScroll() throws {
    let (server, socketPath, token) = try makeServerWithRecord()
    defer { server.stop() }

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.scroll",
      method: "POST",
      path: "/debug/actions",
      body: #"{"action":"scrollViewport","deltaRows":-40}"#)

    XCTAssertEqual(status, 403)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("lazyRouteNotAllowed") || text.contains("userDenied"))
  }

  func testStateApprovalDoesNotAutoApproveOtherSession() throws {
    let (server, socketPath, token) = try makeServerWithRecord()
    defer { server.stop() }

    // Register a different session shell and request state for it.
    server.registerAttachShellPID(sessionID: "s2", shellPID: 999)
    let (status, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state",
      body: nil)

    XCTAssertEqual(status, 403)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("notDescendant") || text.contains("lazyRouteNotAllowed"))
  }

  // MARK: - Helpers

  private func makeServerWithRecord() throws -> (LabanControlServer, String, String) {
    let router = PersistedScopeSpyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let start = try server.start()
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let record = ControlAttachApprovalRecord(
      id: "persisted-state",
      displayName: "Codex",
      signing: ControlCodeSigningIdentity(
        designatedRequirement: "req",
        isAdHocOrUnsigned: false),
      sessionID: "s1",
      shellIdentityFingerprint: "session=s1;pid=50;start=1000000",
      allowedRouteIDs: ["GET /debug/state"],
      allowedIntentIDs: ["app.state"],
      capabilities: [.observe],
      maxDataSensitivity: "nonSensitiveState",
      allowedSideEffectClasses: ["read"])
    server.approvalStore.add(record)

    return (server, start.socketPath, start.appObserveToken)
  }

  private func lazyAttach(
    server: LabanControlServer,
    socketPath: String,
    appObserveToken: String,
    cliCommand: String,
    method: String,
    path: String,
    body: String?
  ) throws -> (Int, Data) {
    let intendedRequest: [String: Any] = [
      "clientRequestID": "req-persisted",
      "cliCommand": cliCommand,
      "intendedRequest": [
        "method": method,
        "path": path,
        "query": "",
        "body": body,
        "bodySHA256": NSNull(),
      ],
    ]
    let payload = try JSONSerialization.data(withJSONObject: intendedRequest, options: [])
    return try ControlUDSClient.request(
      socketPath: socketPath,
      method: "POST",
      path: LabanControlServer.lazyAttachRequestPath,
      token: appObserveToken,
      body: payload,
      timeout: 0.5)
  }
}

private final class PersistedScopeSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
