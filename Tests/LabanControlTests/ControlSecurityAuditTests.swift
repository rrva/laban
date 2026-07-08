import Foundation
import LabanControl
import LabanCore
import XCTest

final class ControlSecurityAuditTests: XCTestCase {

  func testLazyAttachApprovalEmitsRequestedAndApprovedEvents() throws {
    let (server, socketPath, token, observer) = try makeServer()
    defer { server.stop() }

    _ = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    let events = observer.eventNames()
    XCTAssertTrue(events.contains("control.attach.requested"))
    XCTAssertTrue(events.contains("control.attach.approved"))
    XCTAssertFalse(events.contains("control.attach.denied"))
  }

  func testLazyAttachDenialEmitsDeniedEvent() throws {
    let (server, socketPath, token, observer) = try makeServer(decision: .deny)
    defer { server.stop() }

    _ = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    let events = observer.eventNames()
    XCTAssertTrue(events.contains("control.attach.denied"))
    XCTAssertFalse(events.contains("control.attach.approved"))
  }

  func testAuditPayloadsContainNoTokens() throws {
    let (server, socketPath, token, observer) = try makeServer()
    defer { server.stop() }

    _ = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    for payload in observer.payloads() {
      let json = jsonString(payload)
      XCTAssertFalse(json.contains("token"))
      XCTAssertFalse(json.contains("LABAN_SESSION_ATTACH"))
      XCTAssertFalse(json.contains("Authorization"))
    }
  }

  // MARK: - Helpers

  private func makeServer(
    decision: ControlAttachApprovalDecision = .allowOnce
  ) throws -> (LabanControlServer, String, String, SpySecurityObserver) {
    let observer = SpySecurityObserver()
    let router = AuditSpyRouter()
    let tree = FakeAuditProcessTreeInspector(tree: [
      100: (
        parent: 50,
        identity: makeIdentity(100, path: "/Applications/Laban.app/Contents/MacOS/laban")
      ),
      50: (parent: 1, identity: makeIdentity(50, path: "/bin/zsh")),
    ])
    let server = LabanControlServer(
      router: router,
      surface: .headless,
      securityObserver: observer,
      processTreeInspector: tree,
      codeSigningInspector: FakeAuditCodeSigningInspector())
    let start = try server.start()
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)
    server.setApprovalDelegate(FakeAuditApprovalDelegate(decision: decision))
    return (server, start.socketPath, start.appObserveToken, observer)
  }

  private func lazyAttach(
    server: LabanControlServer,
    socketPath: String,
    appObserveToken: String,
    cliCommand: String,
    method: String,
    path: String
  ) throws -> (Int, Data) {
    let intendedRequest: [String: Any] = [
      "clientRequestID": "550e8400-e29b-41d4-a716-446655440000",
      "cliCommand": cliCommand,
      "intendedRequest": [
        "method": method,
        "path": path,
        "query": "",
        "bodyBase64": NSNull(),
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

  private func jsonString(_ dict: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: dict, options: []))
      .flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  private func makeIdentity(_ pid: pid_t, path: String) -> ControlProcessIdentity {
    ControlProcessIdentity(
      pid: pid,
      parentPID: nil,
      startTime: Date(timeIntervalSince1970: 1000),
      uid: getuid(),
      executablePath: path,
      arguments: [],
      signing: nil)
  }
}

private struct AuditEvent {
  let name: String
  let payload: [String: Any]
}

private final class SpySecurityObserver: ControlSecurityObserver, @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [AuditEvent] = []

  func eventNames() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return _events.map(\.name)
  }

  func payloads() -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return _events.map(\.payload)
  }

  func didAuthorize(_ context: ControlSecurityContext) {}
  func didDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason) {}
  func didPrivilegedActivity(_ context: ControlSecurityContext) {}
  func didAttachAuthorize(_ context: ControlSecurityContext) {}

  func didAttachRequest(_ context: ControlSecurityContext) {
    append("control.attach.requested", context)
  }
  func didAttachApprove(_ context: ControlSecurityContext, mode: String) {
    append("control.attach.approved", context)
  }
  func didAttachDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason) {
    append("control.attach.denied", context)
  }
  func didAttachRevoke(_ context: ControlSecurityContext) {
    append("control.attach.revoked", context)
  }
  func didAttachAutoApprove(_ context: ControlSecurityContext, approvalID: String) {
    append("control.attach.autoApproved", context)
  }

  private func append(_ name: String, _ context: ControlSecurityContext) {
    lock.lock()
    _events.append(
      AuditEvent(
        name: name,
        payload: [
          "intent": context.intentID ?? "",
          "capability": context.capability?.rawValue ?? "",
          "surface": context.surface == .gui ? "gui" : "headless",
          "session": context.sessionID ?? "",
        ]))
    lock.unlock()
  }
}

private final class FakeAuditApprovalDelegate: ControlAttachApprovalDelegate, @unchecked Sendable {
  let decision: ControlAttachApprovalDecision
  init(decision: ControlAttachApprovalDecision) { self.decision = decision }
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    completion(decision)
  }
}

private struct FakeAuditProcessTreeInspector: ControlProcessTreeInspecting {
  let tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]
  func parentPID(of pid: pid_t) -> pid_t? { tree[pid]?.parent }
  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}

private struct FakeAuditCodeSigningInspector: ControlCodeSigningInspecting {
  func signingIdentity(forLivePID pid: pid_t, startTime: Date) -> ControlCodeSigningIdentity? {
    nil
  }
  func validatesLivePID(_ pid: pid_t, startTime: Date, against requirement: String) -> Bool {
    false
  }
}

private final class AuditSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
