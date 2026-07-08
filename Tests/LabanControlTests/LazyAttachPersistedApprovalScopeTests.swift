import CryptoKit
import Foundation
import LabanControl
import LabanCore
import XCTest

final class LazyAttachPersistedApprovalScopeTests: XCTestCase {

  private var cleanupDefaults: UserDefaults?
  private var cleanupSuiteName: String?

  override func tearDown() {
    if let cleanupDefaults, let cleanupSuiteName {
      cleanupDefaults.removePersistentDomain(forName: cleanupSuiteName)
      cleanupDefaults.removeSuite(named: cleanupSuiteName)
      self.cleanupDefaults = nil
      self.cleanupSuiteName = nil
    }
    super.tearDown()
  }

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
    let (server, socketPath, token) = try makeServerWithRecord(peerParent: 999)
    defer { server.stop() }

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
    XCTAssertTrue(
      text.contains("userDenied")
        || text.contains("notDescendant")
        || text.contains("lazyRouteNotAllowed"))
  }

  // MARK: - Helpers

  private func makeServerWithRecord(
    peerParent: pid_t = 50
  ) throws -> (LabanControlServer, String, String) {
    let router = PersistedScopeSpyRouter()
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let shellStartTime = Date(timeIntervalSince1970: 1000)
    let shellIdentity = ControlProcessIdentity(
      pid: 50,
      startTime: shellStartTime,
      executablePath: "/bin/zsh")
    let peerIdentity = ControlProcessIdentity(
      pid: peerPID,
      startTime: Date(timeIntervalSince1970: 2000),
      executablePath: "/Applications/Codex.app/Contents/MacOS/Codex")
    var tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)] = [
      peerPID: (parent: peerParent, identity: peerIdentity),
      50: (parent: 1, identity: shellIdentity),
    ]
    if peerParent != 50 {
      tree[peerParent] = (
        parent: 1,
        identity: ControlProcessIdentity(
          pid: peerParent,
          startTime: Date(timeIntervalSince1970: 3000),
          executablePath: "/bin/zsh"
        )
      )
    }
    let processTree = FakeProcessTreeInspector(tree: tree)
    let suiteName = "test-laban-persisted-scope-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    self.cleanupDefaults = defaults
    self.cleanupSuiteName = suiteName
    let approvalStore = ControlAttachApprovalStore(
      defaults: defaults,
      signer: ControlAttachApprovalRecordHMACSigner(key: Data("test-approval-key".utf8)))
    let server = LabanControlServer(
      router: router,
      surface: .headless,
      processTreeInspector: processTree,
      codeSigningInspector: FakeCodeSigningInspector(),
      approvalStore: approvalStore)
    let start = try server.start()
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)
    server.setApprovalDelegate(FakeApprovalDelegate(decision: .deny))

    let record = ControlAttachApprovalRecord(
      id: "persisted-state",
      displayName: "Codex",
      signing: ControlCodeSigningIdentity(
        designatedRequirement: "req",
        isAdHocOrUnsigned: false),
      sessionID: "s1",
      shellIdentityFingerprint: shellIdentity.fingerprint,
      allowedRouteIDs: ["GET /debug/state"],
      allowedIntentIDs: ["app.state"],
      capabilities: [.observeSensitive],
      maxDataSensitivity: "sensitivePrivate",
      allowedSideEffectClasses: ["none"],
      principalIdentityFingerprint: peerIdentity.stablePrincipalFingerprint)
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
    let bodyString = body ?? ""
    let bodyData = Data(bodyString.utf8)
    let bodyBase64: Any = bodyData.isEmpty ? NSNull() : bodyData.base64EncodedString()
    let bodySHA256: Any = bodyData.isEmpty ? NSNull() : computeSHA256(bodyData)
    let intendedRequest: [String: Any] = [
      "clientRequestID": "550e8400-e29b-41d4-a716-446655440000",
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

private final class PersistedScopeSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}

private final class FakeApprovalDelegate: ControlAttachApprovalDelegate, @unchecked Sendable {
  let decision: ControlAttachApprovalDecision
  init(decision: ControlAttachApprovalDecision) { self.decision = decision }
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    completion(decision)
  }
}

private struct FakeProcessTreeInspector: ControlProcessTreeInspecting {
  let tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]

  func parentPID(of pid: pid_t) -> pid_t? { tree[pid]?.parent }
  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}

private struct FakeCodeSigningInspector: ControlCodeSigningInspecting {
  func signingIdentity(
    forLivePID pid: pid_t, startTime: Date, auditToken: Data?
  ) -> ControlCodeSigningIdentity? {
    ControlCodeSigningIdentity(
      designatedRequirement: "req",
      isAdHocOrUnsigned: false)
  }
  func validatesLivePID(
    _ pid: pid_t,
    startTime: Date,
    auditToken: Data?,
    against requirement: String
  ) -> Bool {
    requirement == "req"
  }
}
