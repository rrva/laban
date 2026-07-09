import CryptoKit
import Foundation
import LabanControl
import LabanCore
import XCTest

/// Covers review-gate finding 1 (a swapped peer identity must fail
/// pre-dispatch revalidation) and finding 6 (408 approvalTimeout / 409
/// sessionChanged server-level statuses).
final class LazyAttachServerRevalidationTests: XCTestCase {

  func testSwappedPeerIdentityDuringApprovalFailsPreDispatchRevalidationWith409() throws {
    let router = RevalidationSpyRouter()
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let peerStartTimeOriginal = Date(timeIntervalSince1970: 1000)
    let tree = MutableFakeProcessTreeInspector(tree: [
      peerPID: (
        parent: 50,
        identity: ControlProcessIdentity(
          pid: peerPID,
          startTime: peerStartTimeOriginal,
          executablePath: "/Applications/Codex.app/Contents/MacOS/Codex")
      ),
      50: (
        parent: 1,
        identity: ControlProcessIdentity(pid: 50, startTime: Date(), executablePath: "/bin/zsh")
      ),
    ])
    let server = LabanControlServer(
      router: router,
      surface: .headless,
      processTreeInspector: tree)
    let start = try server.start()
    defer { server.stop() }
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let delegate = SwapOnApprovalDelegate(decision: .allowOnce) {
      // Simulate PID reuse mid-approval: a different process now occupies the
      // peer's PID (same PID, different start time) before the approval
      // completion is delivered back to the server.
      tree.setIdentity(
        ControlProcessIdentity(
          pid: peerPID,
          startTime: Date(timeIntervalSince1970: 2000),
          executablePath: "/Applications/Codex.app/Contents/MacOS/Codex"),
        parent: 50,
        for: peerPID)
    }
    server.setApprovalDelegate(delegate)

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: start.socketPath,
      appObserveToken: start.appObserveToken,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state")

    XCTAssertEqual(status, 409)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("sessionChanged"), "expected sessionChanged, got: \(text)")
    XCTAssertFalse(router.wasDispatched, "downstream route must not run after failed revalidation")
  }

  func testApprovalTimeoutIsInjectableAndProduces408() throws {
    let router = RevalidationSpyRouter()
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let tree = MutableFakeProcessTreeInspector(tree: [
      peerPID: (
        parent: 50,
        identity: ControlProcessIdentity(
          pid: peerPID,
          startTime: Date(),
          executablePath: "/Applications/Codex.app/Contents/MacOS/Codex")
      ),
      50: (
        parent: 1,
        identity: ControlProcessIdentity(pid: 50, startTime: Date(), executablePath: "/bin/zsh")
      ),
    ])
    let server = LabanControlServer(
      router: router,
      surface: .headless,
      processTreeInspector: tree,
      lazyAttachApprovalTimeout: 0.2)
    let start = try server.start()
    defer { server.stop() }
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let delegate = NeverCompletingApprovalDelegate()
    server.setApprovalDelegate(delegate)

    let (status, body) = try lazyAttach(
      server: server,
      socketPath: start.socketPath,
      appObserveToken: start.appObserveToken,
      cliCommand: "session.state",
      method: "GET",
      path: "/debug/state",
      timeout: 2.0)

    XCTAssertEqual(status, 408)
    let text = String(data: body, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("approvalTimeout"), "expected approvalTimeout, got: \(text)")
    XCTAssertFalse(router.wasDispatched)
  }

  // MARK: - Helpers

  private func lazyAttach(
    server: LabanControlServer,
    socketPath: String,
    appObserveToken: String,
    cliCommand: String,
    method: String,
    path: String,
    timeout: TimeInterval = 0.5
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
      timeout: timeout)
  }
}

/// A `ControlProcessTreeInspecting` whose backing tree can be mutated after
/// construction, so a test can swap the identity behind a live PID between
/// approval-context capture and completion (simulating PID reuse mid-flow).
private final class MutableFakeProcessTreeInspector: ControlProcessTreeInspecting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]

  init(tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]) {
    self.tree = tree
  }

  func setIdentity(_ identity: ControlProcessIdentity, parent: pid_t?, for pid: pid_t) {
    lock.lock()
    tree[pid] = (parent: parent, identity: identity)
    lock.unlock()
  }

  func parentPID(of pid: pid_t) -> pid_t? {
    lock.lock()
    defer { lock.unlock() }
    return tree[pid]?.parent
  }

  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    lock.lock()
    defer { lock.unlock() }
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}

/// Invokes `beforeCompletion` synchronously just before delivering the
/// decision, so a test can mutate shared fake state (e.g. swap an identity)
/// between when the server captured the approval context and when the
/// decision comes back.
private final class SwapOnApprovalDelegate: ControlAttachApprovalDelegate, @unchecked Sendable {
  let decision: ControlAttachApprovalDecision
  let beforeCompletion: () -> Void

  init(decision: ControlAttachApprovalDecision, beforeCompletion: @escaping () -> Void) {
    self.decision = decision
    self.beforeCompletion = beforeCompletion
  }

  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    beforeCompletion()
    completion(decision)
  }
}

private final class NeverCompletingApprovalDelegate: ControlAttachApprovalDelegate,
  @unchecked Sendable
{
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    // Never call completion, simulating an approval prompt nobody answers.
  }
}

private final class RevalidationSpyRouter: IntentRouter, @unchecked Sendable {
  private let lock = NSLock()
  private var _wasDispatched = false

  var wasDispatched: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _wasDispatched
  }

  func route(_ intent: Intent) -> ControlResponse {
    lock.lock()
    _wasDispatched = true
    lock.unlock()
    return .json(["ok": true])
  }
  func query(_ query: Query) -> ControlResponse {
    lock.lock()
    _wasDispatched = true
    lock.unlock()
    return .json(["ok": true])
  }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    lock.lock()
    _wasDispatched = true
    lock.unlock()
    return .json(["ok": true])
  }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
