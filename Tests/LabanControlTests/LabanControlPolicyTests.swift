import Foundation
import LabanControl
import LabanCore
import XCTest

final class LabanControlPolicyTests: XCTestCase {
  func testAppObserveTokenAllowsObserveAndDeniesSensitiveWithoutRouterCall() throws {
    let router = SpyPolicyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let start = try server.start()
    defer { server.stop() }

    let allowed = try request(
      socketPath: start.socketPath, path: "/debug/health", token: start.appObserveToken)
    XCTAssertEqual(allowed.0, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [
        LegacyDebugQueryInput(
          intentID: "debug.health",
          readRedaction: .appObserveSummary)
      ])

    router.reset()
    let denied = try request(
      socketPath: start.socketPath, path: "/debug/selection", token: start.appObserveToken)
    XCTAssertEqual(denied.0, 403)
    XCTAssertEqual(router.legacyQueries(), [])
  }

  func testSessionObserveTokenAllowsOwnSessionAndDeniesOtherSession() throws {
    let router = SpyPolicyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let ownSession = "session-a"
    let otherSession = "session-b"
    let sessionToken = server.mintSessionObserveToken(sessionID: ownSession)

    let own = try request(
      socketPath: socketPath,
      path: "/debug/sessions/\(ownSession)",
      token: sessionToken)
    XCTAssertEqual(own.0, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [
        LegacyDebugQueryInput(
          intentID: "session.detail",
          params: ["sessionId": ownSession],
          scopedSessionID: ownSession,
          readRedaction: .sessionObserveSummary)
      ])

    router.reset()
    let other = try request(
      socketPath: socketPath,
      path: "/debug/sessions/\(otherSession)",
      token: sessionToken)
    XCTAssertEqual(other.0, 403)
    XCTAssertEqual(router.legacyQueries(), [])
  }

  func testSessionObserveTokenAllowsOwnSessionGetTextAndDeniesOtherSession() throws {
    let router = SpyPolicyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let ownSession = "session-a"
    let otherSession = "session-b"
    let sessionToken = server.mintSessionObserveToken(sessionID: ownSession)

    let omitted = try request(
      socketPath: socketPath,
      path: "/debug/text",
      token: sessionToken)
    XCTAssertEqual(omitted.0, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [
        LegacyDebugQueryInput(
          intentID: "terminal.getText",
          scopedSessionID: ownSession,
          readRedaction: .sessionObserveSummary)
      ])

    router.reset()
    let own = try request(
      socketPath: socketPath,
      path: "/debug/text?sessionId=\(ownSession)",
      token: sessionToken)
    XCTAssertEqual(own.0, 200)

    router.reset()
    let other = try request(
      socketPath: socketPath,
      path: "/debug/text?sessionId=\(otherSession)",
      token: sessionToken)
    XCTAssertEqual(other.0, 403)
    XCTAssertEqual(router.legacyQueries(), [])
  }

  func testSessionObserveTokenDeniesNavigateOnOtherSession() throws {
    let router = SpyPolicyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: "session-a")
    let body = Data(#"{"action":"scrollViewport","sessionId":"session-b","deltaRows":1}"#.utf8)
    let (status, _) = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: sessionToken,
      body: body)

    XCTAssertEqual(status, 403)
    XCTAssertEqual(router.intents(), [])
  }

  func testAppObserveTokenDeniesInputWithoutRouterCall() throws {
    let router = SpyPolicyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let start = try server.start()
    defer { server.stop() }

    let body = Data(#"{"action":"typeText","text":"hello"}"#.utf8)
    let (status, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/actions",
      method: "POST",
      token: start.appObserveToken,
      body: body)

    XCTAssertEqual(status, 403)
    XCTAssertEqual(router.intents(), [])
  }

  func testFixtureTokenAllowsInputAndClipboardFamilies() throws {
    let router = SpyPolicyRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let paste = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"paste"}"#.utf8))
    XCTAssertEqual(paste.0, 200)
    XCTAssertEqual(router.intents().count, 1)

    router.reset()
    let clipboard = try request(
      socketPath: socketPath,
      path: "/debug/clipboard",
      token: readiness.debugToken)
    XCTAssertEqual(clipboard.0, 200)
    XCTAssertEqual(router.legacyQueries(), [LegacyDebugQueryInput(intentID: "clipboard.read")])
  }

  func testGUIWindowFocusIsAuthorizedOnlyByFixtureTier() throws {
    let descriptor = try XCTUnwrap(IntentCatalog.all.descriptor(id: "fixture.windowFocus"))
    XCTAssertTrue(descriptor.availability.gui)
    XCTAssertEqual(descriptor.requiredCapability, .diagnosticControl)
    XCTAssertFalse(
      LabanControlPolicy.authorize(
        intentID: descriptor.id,
        catalog: .all,
        granted: LabanControlPolicy.grants(for: .appObserve),
        targetSession: nil,
        tokenScope: .wholeApp,
        tokenTier: .appObserve))
    XCTAssertFalse(
      LabanControlPolicy.authorize(
        intentID: descriptor.id,
        catalog: .all,
        granted: LabanControlPolicy.grants(for: .sessionObserve(sessionID: "session")),
        targetSession: nil,
        tokenScope: .session("session"),
        tokenTier: .sessionObserve(sessionID: "session")))
    XCTAssertTrue(
      LabanControlPolicy.authorize(
        intentID: descriptor.id,
        catalog: .all,
        granted: LabanControlPolicy.grants(for: .fixture),
        targetSession: nil,
        tokenScope: .wholeApp,
        tokenTier: .fixture))

    let router = SpyPolicyRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let response = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"windowFocus","focused":true}"#.utf8))
    XCTAssertEqual(response.0, 200)
    guard case .legacyDebugAction(let input) = try XCTUnwrap(router.intents().first) else {
      return XCTFail("GUI fixture windowFocus did not reach the legacy action router")
    }
    XCTAssertEqual(input.intentID, "fixture.windowFocus")
    XCTAssertEqual(input.action, "windowFocus")
  }

  func testSessionObserveTokenDeniesOtherSessionForPlainObserveTarget() throws {
    let catalog = IntentCatalog.all
    let granted = LabanControlPolicy.grants(for: .sessionObserve(sessionID: "own"))
    let scope = LabanControlPolicy.tokenScope(for: .sessionObserve(sessionID: "own"))

    XCTAssertFalse(
      LabanControlPolicy.authorize(
        intentID: "scrollIndicator.state",
        catalog: catalog,
        granted: granted,
        targetSession: "other",
        tokenScope: scope))

    XCTAssertTrue(
      LabanControlPolicy.authorize(
        intentID: "scrollIndicator.state",
        catalog: catalog,
        granted: granted,
        targetSession: nil,
        tokenScope: scope))
  }

  func testPolicyGrantsMatchCatalogTiers() {
    XCTAssertEqual(LabanControlPolicy.grants(for: .appObserve), [.observe])
    XCTAssertEqual(
      LabanControlPolicy.grants(for: .sessionObserve(sessionID: "s1")),
      [.observe, .observeSensitive, .navigate, .propose])
    XCTAssertEqual(
      LabanControlPolicy.grants(for: .fixture),
      [.fixture, .observe, .observeSensitive, .navigate, .propose, .diagnosticControl, .input])
  }

  func testNoDescriptorRequiresClipboardCapability() {
    for descriptor in IntentCatalog.all.descriptors {
      XCTAssertNotEqual(
        descriptor.requiredCapability,
        .clipboard,
        "descriptor \(descriptor.id) must not require .clipboard")
    }
  }

  func testControlAdvertisementWritesSocketPathAsURLField() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-control-ad-\(UUID().uuidString)", isDirectory: true)
    setenv("LABAN_CONTROL_DIR", dir.path, 1)
    defer {
      unsetenv("LABAN_CONTROL_DIR")
      try? FileManager.default.removeItem(at: dir)
    }

    let socketPath = dir.appendingPathComponent("control.sock").path
    try ControlAdvertisement.write(
      url: socketPath,
      token: "app-observe-token",
      pid: 42,
      runId: "run-test")

    let data = try Data(contentsOf: dir.appendingPathComponent("control.json"))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["url"] as? String, socketPath)
    XCTAssertEqual(json["token"] as? String, "app-observe-token")
    XCTAssertEqual(json["pid"] as? Int, 42)
    XCTAssertEqual(json["runId"] as? String, "run-test")
    XCTAssertNil(json["diagnosticControlToken"])
    XCTAssertNil(json["diagnosticSessionObserveToken"])

    try ControlAdvertisement.write(
      url: socketPath,
      token: "app-observe-token",
      pid: 42,
      runId: "run-test",
      diagnosticControlToken: "fixture-token",
      diagnosticSessionObserveToken: "session-token")
    let fixtureData = try Data(contentsOf: dir.appendingPathComponent("control.json"))
    let fixtureJSON = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
    XCTAssertEqual(fixtureJSON["diagnosticControlToken"] as? String, "fixture-token")
    XCTAssertEqual(fixtureJSON["diagnosticSessionObserveToken"] as? String, "session-token")

    let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
    XCTAssertEqual(permissions, 0o700)
  }

  private func makeTempSocketPath() throws -> String {
    "/tmp/laban-ctl-policy-\(UUID().uuidString.prefix(8)).sock"
  }

  private func request(
    socketPath: String,
    path: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) throws -> (Int, Data) {
    try ControlUDSClient.request(
      socketPath: socketPath,
      method: method,
      path: path,
      token: token,
      body: body)
  }
}

private struct SpyPolicyActionResult: Encodable {
  let ok: Bool
}

private struct SpyPolicyQueryResult: Encodable {
  let intentID: String
  let params: [String: String]
}

private final class SpyPolicyRouter: IntentRouter {
  private let lock = NSLock()
  private var routedIntents: [Intent] = []
  private var routedLegacyQueries: [LegacyDebugQueryInput] = []

  func route(_ intent: Intent) -> ControlResponse {
    lock.lock()
    routedIntents.append(intent)
    lock.unlock()
    return .json(SpyPolicyActionResult(ok: true))
  }

  func query(_ query: Query) -> ControlResponse {
    .error(501, "not expected")
  }

  func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    lock.lock()
    routedLegacyQueries.append(query)
    lock.unlock()
    return .json(SpyPolicyQueryResult(intentID: query.intentID, params: query.params))
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    nil
  }

  func intents() -> [Intent] {
    lock.lock()
    defer { lock.unlock() }
    return routedIntents
  }

  func legacyQueries() -> [LegacyDebugQueryInput] {
    lock.lock()
    defer { lock.unlock() }
    return routedLegacyQueries
  }

  func reset() {
    lock.lock()
    routedIntents = []
    routedLegacyQueries = []
    lock.unlock()
  }
}
