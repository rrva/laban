import CryptoKit
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
      clientRequestID: "550e8400-e29b-41d4-a716-446655440001")

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state",
      clientRequestID: "550e8400-e29b-41d4-a716-446655440002")

    XCTAssertEqual(status, 429)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("approvalRateLimited"))
  }

  // MARK: - Helpers

  private func makeServer() throws -> (LabanControlServer, String, String) {
    let router = LazyAttachSpyRouter()
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let tree = FakeProcessTreeInspector(tree: [
      peerPID: (
        parent: 50,
        identity: ControlProcessIdentity(
          pid: peerPID,
          startTime: Date(),
          executablePath: "/Applications/Codex.app/Contents/MacOS/Codex"
        )
      ),
      50: (
        parent: 1,
        identity: ControlProcessIdentity(
          pid: 50,
          startTime: Date(),
          executablePath: "/bin/zsh"
        )
      ),
    ])
    let server = LabanControlServer(
      router: router,
      surface: .headless,
      processTreeInspector: tree)
    let start = try server.start()
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)
    return (server, start.socketPath, start.appObserveToken)
  }

  private func lazyAttach(
    server: LabanControlServer,
    socketPath: String,
    appObserveToken: String,
    cliCommand: String,
    method: String,
    path: String,
    clientRequestID: String = "550e8400-e29b-41d4-a716-446655440000",
    body: String? = nil
  ) throws -> (Int, Data) {
    let bodyString = body ?? ""
    let bodyData = Data(bodyString.utf8)
    let bodyBase64: Any = bodyData.isEmpty ? NSNull() : bodyData.base64EncodedString()
    let bodySHA256: Any = bodyData.isEmpty ? NSNull() : computeSHA256(bodyData)
    let intendedRequest: [String: Any] = [
      "clientRequestID": clientRequestID,
      "cliCommand": cliCommand,
      "intendedRequest": [
        "method": method,
        "path": path,
        "query": "",
        "bodyBase64": bodyBase64,
        "bodySHA256": bodySHA256,
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

  private func computeSHA256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

private final class FakeApprovalDelegate: ControlAttachApprovalDelegate, @unchecked Sendable {
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

private struct FakeProcessTreeInspector: ControlProcessTreeInspecting {
  let tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]

  func parentPID(of pid: pid_t) -> pid_t? {
    tree[pid]?.parent
  }

  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}
