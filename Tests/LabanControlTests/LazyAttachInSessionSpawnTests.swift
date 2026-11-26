import CryptoKit
import Foundation
import LabanControl
import LabanCore
import XCTest

/// ADR 0024, Amendment (2026-11-26): a process proven to run inside a Laban
/// session may open a tab or split its own pane with no dialog. Everything
/// else keeps its approval dialog, and a process outside every session is
/// refused before anything is routed.
final class LazyAttachInSessionSpawnTests: XCTestCase {

  func testSpawnTabFromInsideASessionNeedsNoDialog() throws {
    let router = SpawnSpyRouter()
    let (server, socketPath, token) = try makeServer(router: router, registerShell: true)
    defer { server.stop() }
    let delegate = CountingApprovalDelegate()
    server.setApprovalDelegate(delegate)

    let (status, body) = try lazyAttach(
      socketPath: socketPath, appObserveToken: token, cliCommand: "session.spawnTab",
      body: #"{"action":"spawnTab","argv":["make","test"]}"#)

    XCTAssertEqual(status, 200)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["approval"] as? String, "inSession")
    XCTAssertEqual(json["downstreamStatus"] as? Int, 200)
    XCTAssertEqual(delegate.promptCount, 0, "an in-session spawn must not show a dialog")
    let routed = try XCTUnwrap(router.lastAction)
    XCTAssertEqual(routed.intentID, "session.spawnTab")
    XCTAssertEqual(routed.scopedSessionID, "s1", "the spawn is scoped to the caller's session")
  }

  func testSpawnSplitFromInsideASessionNeedsNoDialog() throws {
    let router = SpawnSpyRouter()
    let (server, socketPath, token) = try makeServer(router: router, registerShell: true)
    defer { server.stop() }
    let delegate = CountingApprovalDelegate()
    server.setApprovalDelegate(delegate)

    let (status, _) = try lazyAttach(
      socketPath: socketPath, appObserveToken: token, cliCommand: "session.spawnSplit",
      body: #"{"action":"spawnSplit","direction":"down"}"#)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(delegate.promptCount, 0)
    XCTAssertEqual(router.lastAction?.intentID, "session.spawnSplit")
    XCTAssertEqual(router.lastAction?.scopedSessionID, "s1")
  }

  func testSpawnFromOutsideEverySessionIsRefusedWithoutRouting() throws {
    let router = SpawnSpyRouter()
    let (server, socketPath, token) = try makeServer(router: router, registerShell: false)
    defer { server.stop() }
    let delegate = CountingApprovalDelegate()
    server.setApprovalDelegate(delegate)

    let (status, body) = try lazyAttach(
      socketPath: socketPath, appObserveToken: token, cliCommand: "session.spawnTab",
      body: #"{"action":"spawnTab"}"#)

    XCTAssertEqual(status, 403)
    XCTAssertTrue((String(data: body, encoding: .utf8) ?? "").contains("notDescendant"))
    XCTAssertNil(router.lastAction)
    XCTAssertEqual(delegate.promptCount, 0)
  }

  func testSandboxedCallerGetsTheDialogInstead() throws {
    let router = SpawnSpyRouter()
    let (server, socketPath, token) = try makeServer(router: router, registerShell: true)
    defer { server.stop() }
    server.isSandboxed = { _ in true }
    let delegate = CountingApprovalDelegate()
    server.setApprovalDelegate(delegate)

    let (status, _) = try lazyAttach(
      socketPath: socketPath, appObserveToken: token, cliCommand: "session.spawnTab",
      body: #"{"action":"spawnTab","argv":["/bin/sh"]}"#)

    XCTAssertEqual(delegate.promptCount, 1, "a sandboxed agent must not open a terminal silently")
    XCTAssertEqual(delegate.lastRequest?.spawnCommand, "/bin/sh", "the dialog shows the command")
    XCTAssertEqual(status, 403, "the fake delegate denies")
    XCTAssertNil(router.lastAction)
  }

  func testASandboxedProcessBetweenCallerAndShellAlsoGetsTheDialog() throws {
    let router = SpawnSpyRouter()
    let (server, socketPath, token) = try makeServer(router: router, registerShell: true)
    defer { server.stop() }
    server.isSandboxed = { $0 == 60 }
    let delegate = CountingApprovalDelegate()
    server.setApprovalDelegate(delegate)

    _ = try lazyAttach(
      socketPath: socketPath, appObserveToken: token, cliCommand: "session.spawnTab",
      body: #"{"action":"spawnTab"}"#)

    XCTAssertEqual(delegate.promptCount, 1)
    XCTAssertNil(router.lastAction)
  }

  func testInSessionSpawnCannotNameAnotherSession() throws {
    let router = SpawnSpyRouter()
    let (server, socketPath, token) = try makeServer(router: router, registerShell: true)
    defer { server.stop() }
    server.setApprovalDelegate(CountingApprovalDelegate())

    let (status, body) = try lazyAttach(
      socketPath: socketPath, appObserveToken: token, cliCommand: "session.spawnSplit",
      body: #"{"action":"spawnSplit","sessionID":"other","targetSessionID":"other"}"#)

    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let downstream = json?["downstreamStatus"] as? Int
    XCTAssertTrue(
      status == 403 || downstream == 403,
      "naming another session is refused: \(status) \(String(decoding: body, as: UTF8.self))")
    if router.lastAction != nil {
      XCTAssertEqual(router.lastAction?.scopedSessionID, "s1")
    }
  }

  func testReadsStillAskForApproval() throws {
    let router = SpawnSpyRouter()
    let (server, socketPath, token) = try makeServer(router: router, registerShell: true)
    defer { server.stop() }
    let delegate = CountingApprovalDelegate()
    server.setApprovalDelegate(delegate)

    _ = try lazyAttach(
      socketPath: socketPath, appObserveToken: token, cliCommand: "session.state",
      method: "GET", path: "/debug/state", body: nil)

    XCTAssertEqual(delegate.promptCount, 1, "only spawn intents skip the dialog")
  }

  func testOnlySpawnIntentsSkipApproval() {
    let skipping = ControlLazyAttachAllowlist.entries.filter { !$0.requiresApproval }
    XCTAssertEqual(
      Set(skipping.map(\.intentID)), ["session.spawnTab", "session.spawnSplit"])
    for entry in skipping {
      let descriptor = IntentCatalog.all.descriptor(id: entry.intentID)
      XCTAssertEqual(descriptor?.requiredCapability, .spawn)
      XCTAssertEqual(descriptor?.sideEffects.ptyInput, false, "spawn never writes PTY input")
      XCTAssertFalse(entry.persistable, "there is no approval to remember")
    }
  }

  // MARK: - Helpers

  private func makeServer(router: SpawnSpyRouter, registerShell: Bool) throws
    -> (LabanControlServer, String, String)
  {
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let tree = SpawnFakeProcessTree(tree: [
      peerPID: (
        parent: 60,
        identity: ControlProcessIdentity(
          pid: peerPID, startTime: Date(), executablePath: "/usr/local/bin/laban")
      ),
      60: (
        parent: 50,
        identity: ControlProcessIdentity(
          pid: 60, startTime: Date(), executablePath: "/usr/local/bin/codex")
      ),
      50: (
        parent: 1,
        identity: ControlProcessIdentity(pid: 50, startTime: Date(), executablePath: "/bin/zsh")
      ),
    ])
    let server = LabanControlServer(router: router, surface: .headless, processTreeInspector: tree)
    server.isSandboxed = { _ in false }
    let start = try server.start()
    if registerShell { server.registerAttachShellPID(sessionID: "s1", shellPID: 50) }
    return (server, start.socketPath, start.appObserveToken)
  }

  private func lazyAttach(
    socketPath: String,
    appObserveToken: String,
    cliCommand: String,
    method: String = "POST",
    path: String = "/debug/actions",
    body: String?
  ) throws -> (Int, Data) {
    let bodyData = Data((body ?? "").utf8)
    let intended: [String: Any] = [
      "method": method,
      "path": path,
      "query": "",
      "bodyBase64": bodyData.isEmpty ? NSNull() : bodyData.base64EncodedString(),
      "bodySHA256": bodyData.isEmpty
        ? NSNull() : SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined(),
    ]
    let payload = try JSONSerialization.data(withJSONObject: [
      "clientRequestID": UUID().uuidString,
      "cliCommand": cliCommand,
      "intendedRequest": intended,
    ])
    return try ControlUDSClient.request(
      socketPath: socketPath,
      method: "POST",
      path: LabanControlServer.lazyAttachRequestPath,
      token: appObserveToken,
      body: payload,
      timeout: 0.5)
  }
}

private final class CountingApprovalDelegate: ControlAttachApprovalDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var _last: ControlAttachApprovalRequest?

  var promptCount: Int { lock.withLock { count } }
  var lastRequest: ControlAttachApprovalRequest? { lock.withLock { _last } }

  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    lock.withLock {
      count += 1
      _last = request
    }
    completion(.deny)
  }
}

private final class SpawnSpyRouter: IntentRouter, @unchecked Sendable {
  private let lock = NSLock()
  private var _lastAction: LegacyDebugActionInput?

  var lastAction: LegacyDebugActionInput? { lock.withLock { _lastAction } }

  func route(_ intent: Intent) -> ControlResponse {
    if case .legacyDebugAction(let input) = intent {
      lock.withLock { _lastAction = input }
    }
    return .json(["ok": true])
  }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}

private struct SpawnFakeProcessTree: ControlProcessTreeInspecting {
  let tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]

  func parentPID(of pid: pid_t) -> pid_t? { tree[pid]?.parent }

  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}
