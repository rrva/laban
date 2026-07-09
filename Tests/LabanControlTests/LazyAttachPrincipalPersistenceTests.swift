import CryptoKit
import Foundation
import LabanControl
import LabanCore
import XCTest

/// Covers review-gate finding 4 (persisted records must be keyed to the
/// resolved principal, not an intermediate helper in the chain) and finding 5
/// (a malicious or overreaching delegate cannot force persistence for a
/// principal that is not persistable; the server degrades the effective
/// decision to allowOnce-or-deny and never writes a record).
final class LazyAttachPrincipalPersistenceTests: XCTestCase {

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

  func testPersistedRecordIsKeyedToPrincipalNotHelperPeer() throws {
    // Chain: shell(zsh, registered) -> agent (Codex, signed non-generic, the
    // principal) -> laban helper (the immediate peer making the request).
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let agentPID: pid_t = 60
    let shellPID: pid_t = 50
    let shellIdentity = ControlProcessIdentity(
      pid: shellPID, startTime: Date(timeIntervalSince1970: 1000), executablePath: "/bin/zsh")
    let agentIdentity = ControlProcessIdentity(
      pid: agentPID,
      startTime: Date(timeIntervalSince1970: 1500),
      executablePath: "/Applications/Codex.app/Contents/MacOS/Codex")
    let peerIdentity = ControlProcessIdentity(
      pid: peerPID,
      startTime: Date(timeIntervalSince1970: 2000),
      executablePath: "/Applications/Laban.app/Contents/MacOS/laban")
    let tree = FakeProcessTreeInspector(tree: [
      peerPID: (parent: agentPID, identity: peerIdentity),
      agentPID: (parent: shellPID, identity: agentIdentity),
      shellPID: (parent: 1, identity: shellIdentity),
    ])

    // The live code-signing lookup is what actually populates `.signing` on
    // the resolved principal during the request; mirror that onto a local
    // copy so the expected fingerprint matches what the server computes,
    // rather than the signing-less identity used to seed the fake tree.
    let agentSigning = ControlCodeSigningIdentity(
      bundleIdentifier: "com.example.codex",
      signingIdentifier: "com.example.codex",
      designatedRequirement: "anchor apple generic and identifier \"com.example.codex\"",
      isAdHocOrUnsigned: false)
    var agentIdentityWithSigning = agentIdentity
    agentIdentityWithSigning.signing = agentSigning

    let (server, socketPath, token) = try makeServer(
      tree: tree,
      codeSigning: SigningByPIDInspector(signingByPID: [agentPID: agentSigning]))
    defer { server.stop() }
    server.registerAttachShellPID(sessionID: "s1", shellPID: shellPID)

    let delegate = FakeApprovalDelegate(decision: .alwaysAllowSignedIdentity)
    server.setApprovalDelegate(delegate)

    let (status, _) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    XCTAssertEqual(status, 200)

    let records = server.approvalStore.loadAll()
    XCTAssertEqual(records.count, 1, "exactly one record should be persisted")
    guard let record = records.first else { return }

    // The stored identity must describe the Codex agent (the principal),
    // never the laban helper that made the actual lazy-attach request.
    XCTAssertEqual(record.displayName, "com.example.codex")
    XCTAssertEqual(record.bundleIdentifier, "com.example.codex")
    XCTAssertEqual(
      record.principalIdentityFingerprint, agentIdentityWithSigning.stablePrincipalFingerprint)
    XCTAssertNotEqual(
      record.principalIdentityFingerprint, peerIdentity.stablePrincipalFingerprint)
    XCTAssertFalse(
      record.displayName.lowercased().contains("laban"),
      "persisted record must not describe the laban helper peer")
  }

  func testMaliciousDelegateCannotPersistForGenericOrUnsignedPrincipals() throws {
    let cases: [(name: String, path: String, signing: ControlCodeSigningIdentity?)] = [
      ("node", "/usr/local/bin/node", nil),
      ("python", "/usr/bin/python", nil),
      ("zsh", "/bin/zsh", nil),
      ("bash", "/bin/bash", nil),
      (
        "laban",
        "/Applications/Laban.app/Contents/MacOS/laban",
        ControlCodeSigningIdentity(designatedRequirement: "anchor laban", isAdHocOrUnsigned: false)
      ),
      (
        "laban-agent",
        "/Applications/Laban.app/Contents/MacOS/laban-agent",
        ControlCodeSigningIdentity(designatedRequirement: "anchor laban", isAdHocOrUnsigned: false)
      ),
      (
        "unsigned-binary", "/usr/local/bin/myagent",
        ControlCodeSigningIdentity(isAdHocOrUnsigned: true)
      ),
      (
        "adhoc-binary", "/usr/local/bin/adhocagent",
        ControlCodeSigningIdentity(designatedRequirement: "", isAdHocOrUnsigned: true)
      ),
    ]

    for testCase in cases {
      let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
      let shellPID: pid_t = 50
      let shellIdentity = ControlProcessIdentity(
        pid: shellPID, startTime: Date(timeIntervalSince1970: 1000), executablePath: "/bin/zsh")
      var peerIdentity = ControlProcessIdentity(
        pid: peerPID, startTime: Date(timeIntervalSince1970: 2000), executablePath: testCase.path)
      peerIdentity.signing = testCase.signing
      let tree = FakeProcessTreeInspector(tree: [
        peerPID: (parent: shellPID, identity: peerIdentity),
        shellPID: (parent: 1, identity: shellIdentity),
      ])
      var signingByPID: [pid_t: ControlCodeSigningIdentity] = [:]
      if let signing = testCase.signing {
        signingByPID[peerPID] = signing
      }
      let (server, socketPath, token) = try makeServer(
        tree: tree, codeSigning: SigningByPIDInspector(signingByPID: signingByPID))
      defer { server.stop() }
      server.registerAttachShellPID(sessionID: "s1", shellPID: shellPID)

      let delegate = FakeApprovalDelegate(decision: .alwaysAllowSignedIdentity)
      server.setApprovalDelegate(delegate)

      let (status, body) = try lazyAttach(
        server: server,
        socketPath: socketPath,
        appObserveToken: token,
        cliCommand: "session.state",
        method: "GET",
        path: "/debug/state")

      let records = server.approvalStore.loadAll()
      XCTAssertTrue(
        records.isEmpty,
        "\(testCase.name): a malicious alwaysAllowSignedIdentity decision must not persist a record"
      )

      // The request must still degrade to allowOnce (200, approval "once") or
      // deny (403); it must never be silently rejected for an unrelated
      // reason that would mask the persistence guard not having been hit.
      if status == 200 {
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(
          json?["approval"] as? String, "once",
          "\(testCase.name): non-persistable alwaysAllow must degrade to allowOnce")
      } else {
        XCTAssertEqual(status, 403, "\(testCase.name): expected allowOnce (200) or deny (403)")
      }
    }
  }

  func testMaliciousDelegateCannotPersistForRawSessionRequestRoute() throws {
    // session.request is the raw/generic route; even a signed non-generic
    // principal must not be able to persist an alwaysAllow grant on it.
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let shellPID: pid_t = 50
    let shellIdentity = ControlProcessIdentity(
      pid: shellPID, startTime: Date(timeIntervalSince1970: 1000), executablePath: "/bin/zsh")
    let peerIdentity = ControlProcessIdentity(
      pid: peerPID,
      startTime: Date(timeIntervalSince1970: 2000),
      executablePath: "/Applications/Codex.app/Contents/MacOS/Codex")
    let tree = FakeProcessTreeInspector(tree: [
      peerPID: (parent: shellPID, identity: peerIdentity),
      shellPID: (parent: 1, identity: shellIdentity),
    ])
    let (server, socketPath, token) = try makeServer(
      tree: tree,
      codeSigning: SigningByPIDInspector(signingByPID: [
        peerPID: ControlCodeSigningIdentity(
          bundleIdentifier: "com.example.codex",
          designatedRequirement: "anchor apple generic and identifier \"com.example.codex\"",
          isAdHocOrUnsigned: false)
      ]))
    defer { server.stop() }
    server.registerAttachShellPID(sessionID: "s1", shellPID: shellPID)

    let delegate = FakeApprovalDelegate(decision: .alwaysAllowSignedIdentity)
    server.setApprovalDelegate(delegate)

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: socketPath,
      appObserveToken: token,
      cliCommand: "session.request",
      method: "GET",
      path: "/debug/state")

    XCTAssertTrue(server.approvalStore.loadAll().isEmpty)
    if status == 200 {
      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      XCTAssertEqual(json?["approval"] as? String, "once")
    } else {
      XCTAssertEqual(status, 403)
    }
  }

  // MARK: - Helpers

  private func makeServer(
    tree: FakeProcessTreeInspector,
    codeSigning: ControlCodeSigningInspecting
  ) throws -> (LabanControlServer, String, String) {
    let router = PrincipalPersistenceSpyRouter()
    let suiteName = "test-laban-principal-persistence-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    self.cleanupDefaults = defaults
    self.cleanupSuiteName = suiteName
    let approvalStore = ControlAttachApprovalStore(
      defaults: defaults,
      signer: ControlAttachApprovalRecordHMACSigner(key: Data("test-approval-key".utf8)))
    let server = LabanControlServer(
      router: router,
      surface: .headless,
      processTreeInspector: tree,
      codeSigningInspector: codeSigning,
      approvalStore: approvalStore)
    let start = try server.start()
    return (server, start.socketPath, start.appObserveToken)
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

/// A `ControlCodeSigningInspecting` that returns a canned signing identity for
/// a fixed set of PIDs (the "live code signature" the server would otherwise
/// fetch from the OS), and leaves any other PID's identity signing untouched
/// (returns nil, so the caller falls back to whatever the fake process tree
/// already attached to that identity).
private struct SigningByPIDInspector: ControlCodeSigningInspecting {
  let signingByPID: [pid_t: ControlCodeSigningIdentity]

  func signingIdentity(
    forLivePID pid: pid_t, startTime: Date, auditToken: Data?
  ) -> ControlCodeSigningIdentity? {
    signingByPID[pid]
  }

  func validatesLivePID(
    _ pid: pid_t, startTime: Date, auditToken: Data?, against requirement: String
  ) -> Bool {
    signingByPID[pid]?.designatedRequirement == requirement
  }
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

private final class PrincipalPersistenceSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
