import Foundation
import LabanControl
import LabanCore
import XCTest

final class LazyAttachApprovedRequestTests: XCTestCase {

  func testAllowOnceDispatchesAndReturnsDownstream() throws {
    let (server, socketPath, token) = try makeServer()
    defer { server.stop() }

    let delegate = FakeApprovalDelegate(decision: .allowOnce)
    server.setApprovalDelegate(delegate)

    let (_, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    XCTAssertEqual(json["ok"] as? Bool, true)
    XCTAssertEqual(json["approval"] as? String, "once")
    XCTAssertEqual(json["downstreamStatus"] as? Int, 200)
  }

  func testDenyReturns403WithoutDispatch() throws {
    let (server, socketPath, token) = try makeServer()
    defer { server.stop() }

    let delegate = FakeApprovalDelegate(decision: .deny)
    server.setApprovalDelegate(delegate)

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    XCTAssertEqual(status, 403)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("userDenied"))
  }

  func testNonAllowlistedRouteReturns403BeforeUI() throws {
    let (server, socketPath, token) = try makeServer()
    defer { server.stop() }

    let delegate = FakeApprovalDelegate(decision: .allowOnce)
    server.setApprovalDelegate(delegate)

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.request",
      method: "GET",
      path: "/debug/clipboard")

    XCTAssertEqual(status, 403)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("lazyRouteNotAllowed"))
    XCTAssertFalse(delegate.prompted)
  }

  func testRateLimitedDuplicateRequest() throws {
    let (server, socketPath, token) = try makeServer()
    defer { server.stop() }

    let delegate = FakeApprovalDelegate(decision: .allowOnce)
    server.setApprovalDelegate(delegate)
    delegate.slow = true

    _ = try? lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state",
      clientRequestID: "req1")

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state",
      clientRequestID: "req2")

    XCTAssertEqual(status, 429)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("approvalRateLimited"))
  }

  // MARK: - Helpers

  private func makeServer() throws -> (LabanControlServer, String, String) {
    let router = LazyAttachSpyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let start = try server.start()
    return (server, start.socketPath, start.appObserveToken)
  }

  private func lazyAttach(
    server: LabanControlServer,
    socketPath: String,
    appObserveToken: String,
    cliCommand: String,
    method: String,
    path: String,
    clientRequestID: String = "req-1",
    body: String? = nil
  ) throws -> (Int, Data) {
    let intendedRequest: [String: Any] = [
      "clientRequestID": clientRequestID,
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

private final class FakeApprovalDelegate: ControlAttachApprovalDelegate {
  let decision: ControlAttachApprovalDecision
  var prompted = false
  var slow = false

  init(decision: ControlAttachApprovalDecision) {
    self.decision = decision
  }

  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    prompted = true
    if slow {
      // Never complete, simulating a slow approval.
      return
    }
    completion(decision)
  }
}

private final class LazyAttachSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
