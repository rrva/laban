import Foundation
import LabanControl
import LabanCore
import XCTest

final class ControlSecurityAuditTests: XCTestCase {
  private var retainedApprovalDelegates: [FakeAuditApprovalDelegate] = []

  override func tearDown() {
    retainedApprovalDelegates.removeAll()
    super.tearDown()
  }

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

    let contextStrings = observer.contexts().map { contextString($0) }
    let payloadStrings = observer.payloads().map { jsonString($0) }
    let allStrings = contextStrings + payloadStrings

    for text in allStrings {
      XCTAssertFalse(text.contains("token"), "audit payload contains 'token': \(text)")
      XCTAssertFalse(
        text.contains("LABAN_SESSION_ATTACH"), "audit payload contains bootstrap: \(text)")
      XCTAssertFalse(
        text.contains("Authorization"), "audit payload contains Authorization header: \(text)")
      XCTAssertFalse(text.contains(token), "audit payload contains app-observe token: \(text)")
    }
  }

  func testApprovedTokenNeverLeaksIntoResponseOrAudit() throws {
    let (server, socketPath, token, observer) = try makeServer()
    defer { server.stop() }

    let mintedTokens = MintedTokenBox()
    #if DEBUG
      server.onApprovedTokenMintedForTesting = { minted in
        mintedTokens.append(minted)
      }
    #endif

    let (_, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    #if DEBUG
      let tokensToCheck = mintedTokens.all()
      XCTAssertFalse(tokensToCheck.isEmpty, "expected the debug seam to capture a minted token")

      let responseText = String(data: body, encoding: .utf8) ?? ""
      let contextStrings = observer.contexts().map { contextString($0) }
      let payloadStrings = observer.payloads().map { jsonString($0) }
      let allAuditStrings = contextStrings + payloadStrings

      for mintedToken in tokensToCheck {
        XCTAssertFalse(
          responseText.contains(mintedToken),
          "approved-dispatch token leaked into the HTTP response body")
        for text in allAuditStrings {
          XCTAssertFalse(
            text.contains(mintedToken),
            "approved-dispatch token leaked into an audit payload: \(text)")
        }
      }
    #endif
  }

  func testDownstreamResponseSentinelDoesNotLeakIntoAuditPayloads() throws {
    // The downstream response body (what the routed handler returns) flows
    // back to the CLI inside `downstreamBody`, but must never be copied into
    // an audit event. Plant a terminal-text sentinel in the router's response
    // and confirm it reaches the CLI-facing body but not the audit payloads.
    let sentinel = "TERMINAL-TEXT-SENTINEL-4f8b2c1a"
    let observer = SpySecurityObserver()
    let router = SentinelBodyRouter(sentinel: sentinel)
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let tree = FakeAuditProcessTreeInspector(tree: [
      peerPID: (
        parent: 50,
        identity: makeIdentity(peerPID, path: "/Applications/Laban.app/Contents/MacOS/laban")
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
    defer { server.stop() }
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)
    let delegate = FakeAuditApprovalDelegate(decision: .allowOnce)
    retainedApprovalDelegates.append(delegate)
    server.setApprovalDelegate(delegate)

    let (_, body) = try lazyAttach(
      server: server,
      socketPath: start.socketPath,
      appObserveToken: start.appObserveToken,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    let responseText = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(
      responseText.contains(sentinel),
      "downstream body sentinel should reach the CLI-facing response")

    let contextStrings = observer.contexts().map { contextString($0) }
    let payloadStrings = observer.payloads().map { jsonString($0) }
    for text in contextStrings + payloadStrings {
      XCTAssertFalse(
        text.contains(sentinel),
        "downstream terminal-text sentinel leaked into an audit payload: \(text)")
    }
  }

  // MARK: - Helpers

  private func makeServer(
    decision: ControlAttachApprovalDecision = .allowOnce
  ) throws -> (LabanControlServer, String, String, SpySecurityObserver) {
    let observer = SpySecurityObserver()
    let router = AuditSpyRouter()
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let tree = FakeAuditProcessTreeInspector(tree: [
      peerPID: (
        parent: 50,
        identity: makeIdentity(peerPID, path: "/Applications/Laban.app/Contents/MacOS/laban")
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
    let delegate = FakeAuditApprovalDelegate(decision: decision)
    retainedApprovalDelegates.append(delegate)
    server.setApprovalDelegate(delegate)
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

  private func contextString(_ context: ControlSecurityContext) -> String {
    let surface = context.surface == .gui ? "gui" : "headless"
    let capability = context.capability?.rawValue ?? ""
    return [
      "intent:\(context.intentID ?? "")",
      "capability:\(capability)",
      "surface:\(surface)",
      "session:\(context.sessionID ?? "")",
      "timestamp:\(context.timestamp.timeIntervalSince1970)",
    ].joined(separator: ";")
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
  let context: ControlSecurityContext
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

  func contexts() -> [ControlSecurityContext] {
    lock.lock()
    defer { lock.unlock() }
    return _events.map(\.context)
  }

  func didAuthorize(_ context: ControlSecurityContext) {}
  func didDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason) {}
  func didPrivilegedActivity(_ context: ControlSecurityContext) {}
  func didAttachAuthorize(_ context: ControlSecurityContext) {}

  func didAttachRequest(_ context: ControlSecurityContext) {
    append("control.attach.requested", context)
  }
  func didAttachApprove(_ context: ControlSecurityContext, mode: String) {
    append("control.attach.approved", context, extra: ["mode": mode])
  }
  func didAttachDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason) {
    append("control.attach.denied", context, extra: ["reason": reason.rawValue])
  }
  func didAttachRevoke(_ context: ControlSecurityContext) {
    append("control.attach.revoked", context)
  }
  func didAttachAutoApprove(_ context: ControlSecurityContext, approvalID: String) {
    append("control.attach.autoApproved", context, extra: ["approvalID": approvalID])
  }

  private func append(
    _ name: String,
    _ context: ControlSecurityContext,
    extra: [String: Any] = [:]
  ) {
    lock.lock()
    var payload: [String: Any] = [
      "intent": context.intentID ?? "",
      "capability": context.capability?.rawValue ?? "",
      "surface": context.surface == .gui ? "gui" : "headless",
      "session": context.sessionID ?? "",
      "timestamp": ISO8601DateFormatter().string(from: context.timestamp),
    ]
    for (key, value) in extra {
      payload[key] = value
    }
    _events.append(
      AuditEvent(
        name: name,
        context: context,
        payload: payload))
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
  func signingIdentity(
    forLivePID pid: pid_t, startTime: Date, auditToken: Data?
  ) -> ControlCodeSigningIdentity? {
    nil
  }
  func validatesLivePID(
    _ pid: pid_t,
    startTime: Date,
    auditToken: Data?,
    against requirement: String
  ) -> Bool {
    false
  }
}

private final class AuditSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}

/// Thread-safe accumulator for tokens captured via
/// `LabanControlServer.onApprovedTokenMintedForTesting`.
private final class MintedTokenBox: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String] = []

  func append(_ token: String) {
    lock.lock()
    tokens.append(token)
    lock.unlock()
  }

  func all() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return tokens
  }
}

/// A router whose downstream response body always contains a fixed sentinel
/// string, regardless of which dispatch method the server routes through.
private final class SentinelBodyRouter: IntentRouter {
  let sentinel: String
  init(sentinel: String) { self.sentinel = sentinel }
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": "true", "text": sentinel]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": "true", "text": sentinel]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    .json(["ok": "true", "text": sentinel])
  }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
