import Darwin
import Foundation
import LabanControl
import LabanCore
import XCTest

final class LabanControlServerTests: XCTestCase {
  override func setUp() {
    super.setUp()
    LabanControlServer.skipExecutableVerificationForTests = true
  }

  override func tearDown() {
    LabanControlServer.skipExecutableVerificationForTests = false
    super.tearDown()
  }

  func testGuardMatrix() {
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "127.0.0.1:5", origin: nil, authorization: "Bearer T", token: "T"),
      .ok)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "127.0.0.1:5", origin: nil, authorization: nil, token: "T"),
      .unauthorized)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "127.0.0.1:5", origin: nil, authorization: "Bearer X", token: "T"),
      .unauthorized)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "evil.com", origin: nil, authorization: "Bearer T", token: "T"),
      .forbidden)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: nil, origin: nil, authorization: "Bearer T", token: "T"),
      .forbidden)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "127.0.0.1:5", origin: "http://evil.com",
        authorization: "Bearer T", token: "T"),
      .forbidden)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "[::1]:1234", origin: nil, authorization: "Bearer T", token: "T"),
      .ok)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "[::1]", origin: nil, authorization: "Bearer T", token: "T"),
      .ok)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "[::1]evil", origin: nil, authorization: "Bearer T", token: "T"),
      .forbidden)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "localhost:1234", origin: nil, authorization: "Bearer T", token: "T"),
      .ok)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "localhost.evil.com", origin: nil, authorization: "Bearer T", token: "T"),
      .forbidden)
    XCTAssertEqual(
      LabanControlServer.evaluateGuard(
        host: "127.0.0.1.evil.com", origin: nil, authorization: "Bearer T", token: "T"),
      .forbidden)
  }

  func testStartSocketPathReturnsReadiness() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    XCTAssertEqual(readiness.debugServer, socketPath)
    XCTAssertFalse(readiness.debugToken.isEmpty)
    XCTAssertEqual(readiness.pid, ProcessInfo.processInfo.processIdentifier)
    XCTAssertFalse(readiness.runId.isEmpty)
  }

  func testSecondServerCannotDisplaceLiveSocketListener() throws {
    let socketPath = try makeTempSocketPath()
    let first = LabanControlServer(router: SpyIntentRouter(), surface: .headless)
    let second = LabanControlServer(router: SpyIntentRouter(), surface: .headless)
    _ = try first.start(socketPath: socketPath)
    defer {
      first.stop()
      second.stop()
    }

    XCTAssertThrowsError(try second.start(socketPath: socketPath)) { error in
      XCTAssertEqual(error as? ControlDirectorySecurityError, .socketPathInUse)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

    let clientFD = try ControlUDSClient.connect(socketPath: socketPath)
    Darwin.close(clientFD)
  }

  func testAcceptedSocketConfigurationSetsNoSigPipe() throws {
    var fds: [Int32] = [-1, -1]
    let pairResult = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
      socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
    }
    XCTAssertEqual(pairResult, 0)
    let clientFD = fds[0]
    let peerFD = fds[1]
    defer {
      Darwin.close(clientFD)
      Darwin.close(peerFD)
    }

    var before: Int32 = 0
    var beforeLen = socklen_t(MemoryLayout<Int32>.size)
    XCTAssertEqual(getsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &before, &beforeLen), 0)
    XCTAssertEqual(before, 0, "precondition: SO_NOSIGPIPE should default to unset")

    try LabanControlServer.configureAcceptedSocket(clientFD)

    var after: Int32 = 0
    var afterLen = socklen_t(MemoryLayout<Int32>.size)
    XCTAssertEqual(getsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &after, &afterLen), 0)
    XCTAssertNotEqual(after, 0, "accepted control sockets must set SO_NOSIGPIPE")

    // Also prove close-on-exec was preserved by the shared configuration path.
    let flags = fcntl(clientFD, F_GETFD)
    XCTAssertGreaterThanOrEqual(flags, 0)
    XCTAssertEqual(flags & FD_CLOEXEC, FD_CLOEXEC)

    // With SO_NOSIGPIPE set, closing the peer's read side and sending must
    // surface EPIPE instead of raising SIGPIPE (which would otherwise
    // terminate the process on the default disposition).
    Darwin.close(peerFD)
    var byte: UInt8 = 0
    let sendResult = Darwin.send(clientFD, &byte, 1, 0)
    XCTAssertEqual(sendResult, -1)
    XCTAssertEqual(errno, EPIPE)
  }

  func testStateRouteDispatchesQuery() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/state",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(router.legacyQueries(), [LegacyDebugQueryInput(intentID: "app.state")])
    let state = try JSONDecoder().decode(SpyLegacyQueryResult.self, from: data)
    XCTAssertEqual(state.intentID, "app.state")
  }

  func testLegacyReadRoutePreservesQueryParameters() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/events?since=7",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [LegacyDebugQueryInput(intentID: "log.events", params: ["since": "7"])])
    let result = try JSONDecoder().decode(SpyLegacyQueryResult.self, from: data)
    XCTAssertEqual(result.intentID, "log.events")
    XCTAssertEqual(result.params, ["since": "7"])
  }

  func testGetTextRoutePreservesQueryParameters() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/text?source=scrollback&startLine=1&endLine=5&maxLines=100",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [
        LegacyDebugQueryInput(
          intentID: "terminal.getText",
          params: [
            "source": "scrollback", "startLine": "1", "endLine": "5", "maxLines": "100",
          ])
      ])
    let result = try JSONDecoder().decode(SpyLegacyQueryResult.self, from: data)
    XCTAssertEqual(result.intentID, "terminal.getText")
    XCTAssertEqual(
      result.params,
      ["source": "scrollback", "startLine": "1", "endLine": "5", "maxLines": "100"])
  }

  func testSessionDetailRouteDecodesPathAndPreservesQueryParameters() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/sessions/session%201?includeGrid=true",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [
        LegacyDebugQueryInput(
          intentID: "session.detail",
          params: ["includeGrid": "true", "sessionId": "session 1"])
      ])
    let result = try JSONDecoder().decode(SpyLegacyQueryResult.self, from: data)
    XCTAssertEqual(result.intentID, "session.detail")
    XCTAssertEqual(result.params, ["includeGrid": "true", "sessionId": "session 1"])
  }

  func testLegacyBodyRouteDispatchesRawBodyAndIntentID() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let body = Data(#"{"needle":"apple"}"#.utf8)
    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/find/start?mode=literal",
      method: "POST",
      token: readiness.debugToken,
      body: body)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyControls(),
      [LegacyDebugControlInput(intentID: "find.start", body: body, params: ["mode": "literal"])])
    let result = try JSONDecoder().decode(SpyLegacyControlResult.self, from: data)
    XCTAssertEqual(result.intentID, "find.start")
    XCTAssertEqual(result.body, #"{"needle":"apple"}"#)
    XCTAssertEqual(result.params, ["mode": "literal"])
  }

  func testLegacyNoBodyRouteDispatchesEmptyBody() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/persistence/flush",
      method: "POST",
      token: readiness.debugToken,
      body: Data())

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyControls(),
      [LegacyDebugControlInput(intentID: "persistence.flush")])
    let result = try JSONDecoder().decode(SpyLegacyControlResult.self, from: data)
    XCTAssertEqual(result.intentID, "persistence.flush")
    XCTAssertEqual(result.body, "")
    XCTAssertEqual(result.params, [:])
  }

  func testCaptureStatusRouteDispatchesLegacyQuery() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/capture/status",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [LegacyDebugQueryInput(intentID: "capture.status")])
    let result = try JSONDecoder().decode(SpyLegacyQueryResult.self, from: data)
    XCTAssertEqual(result.intentID, "capture.status")
  }

  func testScreenshotArtifactRouteDispatchesArtifactRequestAndPreservesHeaders() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/screenshot?target=active",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(data, SpyIntentRouter.pngBytes)
    let artifacts = router.artifacts()
    XCTAssertEqual(artifacts.count, 1)
    XCTAssertEqual(artifacts.first?.id, "artifact.screenshot")
    XCTAssertEqual(artifacts.first?.params, ["target": "active"])
  }

  func testTabSelectReturns404OnGuiSurfaceWithoutRouterCall() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"selectTab","index":7}"#.utf8))

    XCTAssertEqual(status, 404)
    XCTAssertEqual(router.intents(), [])
    XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"unavailable on gui"}"#)
  }

  func testUnavailableIntentReturns404WithoutRouterCall() throws {
    let tabSelect = try XCTUnwrap(IntentCatalog.all.descriptor(id: "tab.select"))
    let catalog = IntentCatalog([
      IntentDescriptor(
        id: tabSelect.id,
        kind: tabSelect.kind,
        category: tabSelect.category,
        summary: tabSelect.summary,
        requiredCapability: tabSelect.requiredCapability,
        dataSensitivity: tabSelect.dataSensitivity,
        sideEffects: tabSelect.sideEffects,
        risk: tabSelect.risk,
        audit: tabSelect.audit,
        availability: .init(gui: false, headless: true),
        transports: tabSelect.transports,
        inputSchema: tabSelect.inputSchema,
        outputSchema: tabSelect.outputSchema,
        errorSchema: tabSelect.errorSchema,
        classificationExplicit: true)
    ])
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui, catalog: catalog)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"selectTab","index":1}"#.utf8))

    XCTAssertEqual(status, 404)
    XCTAssertEqual(router.intents(), [])
    XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"unavailable on gui"}"#)
  }

  func testFixtureActionIsKnownButUnavailableOnGUIWithoutRouterCall() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"feedOutput","text":"abc"}"#.utf8))

    XCTAssertEqual(status, 404)
    XCTAssertEqual(router.intents(), [])
    XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"unavailable on gui"}"#)
  }

  func testUnknownActionDispatchesUnsupportedIntentInsteadOfUnavailable404() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, _) = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"future.action"}"#.utf8))

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.intents(),
      [.unsupportedDebugAction(UnsupportedDebugActionInput(action: "future.action"))])
  }

  func testMalformedAndMissingActionsRemainBadRequest() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let missing = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"text":"abc"}"#.utf8))
    XCTAssertEqual(missing.0, 400)
    XCTAssertEqual(String(data: missing.1, encoding: .utf8), #"{"error":"bad request"}"#)

    let malformed = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"selectTab""#.utf8))
    XCTAssertEqual(malformed.0, 400)
    XCTAssertEqual(String(data: malformed.1, encoding: .utf8), #"{"error":"bad request"}"#)
    XCTAssertEqual(router.intents(), [])
  }

  func testHeadlessActionRoutesRawBodyAsLegacyDebugAction() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let body = Data(#"{"action":"mouseWheel","x":300,"y":200,"deltaY":3}"#.utf8)
    let (status, _) = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: body)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.intents(),
      [
        .legacyDebugAction(
          LegacyDebugActionInput(intentID: "terminal.mouseWheel", action: "mouseWheel", body: body))
      ])
  }

  func testHeadlessSharedActionRoutesRawBodyNotTypedIntent() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    let readiness = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let body = Data(#"{"action":"selectTab","tabId":"tab-7"}"#.utf8)
    let (status, _) = try request(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: body)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.intents(),
      [
        .legacyDebugAction(
          LegacyDebugActionInput(intentID: "tab.select", action: "selectTab", body: body))
      ])
  }

  func testRouteMetadataCarriesRepresentativeLegacySchemas() throws {
    let bindings = ControlRouteCatalog.bindings

    let actions = try XCTUnwrap(
      bindings.first { $0.method == "POST" && $0.path == "/debug/actions" })
    XCTAssertEqual(actions.legacyRequestSchemaPath, "schemas/debug/action.schema.json")
    XCTAssertEqual(actions.legacyResponseSchemaPath, "schemas/debug/action-result.schema.json")

    let wait = try XCTUnwrap(bindings.first { $0.method == "POST" && $0.path == "/debug/wait" })
    XCTAssertEqual(wait.legacyRequestSchemaPath, "schemas/debug/wait.schema.json")
    XCTAssertEqual(wait.legacyResponseSchemaPath, "schemas/debug/wait-result.schema.json")

    let state = try XCTUnwrap(bindings.first { $0.method == "GET" && $0.path == "/debug/state" })
    XCTAssertNil(state.legacyRequestSchemaPath)
    XCTAssertEqual(state.legacyResponseSchemaPath, "schemas/debug/state.schema.json")
  }

  func testRouteCatalogCoversLegacyDebugSurfaceAndDescriptors() throws {
    let endpoints = ControlRouteCatalog.endpoints
    XCTAssertEqual(endpoints.count, 52)
    XCTAssertEqual(Set(endpoints.map { "\($0.binding.method) \($0.binding.path)" }).count, 52)
    XCTAssertNotNil(
      endpoints.first { $0.binding.method == "GET" && $0.binding.path == "/debug/sessions/<id>" })

    for endpoint in endpoints {
      guard let intentID = endpoint.fixedIntentId else {
        continue
      }
      XCTAssertNotNil(IntentCatalog.all.descriptor(id: intentID), intentID)
    }
  }

  func testMissingTokenReturns401() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (status, _) = try request(socketPath: socketPath, path: "/debug/health")
    XCTAssertEqual(status, 401)
    XCTAssertEqual(router.legacyQueries(), [])
  }

  func testAttachRedeemRequiresRegisteredShellPID() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let bootstrap = server.mintSessionAttachBootstrap(sessionID: "sess-1")
    let (unregisteredStatus, _) = try request(
      socketPath: socketPath,
      path: LabanControlServer.sessionAttachPath,
      method: "POST",
      body: Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8))
    XCTAssertEqual(unregisteredStatus, 425)

    server.registerAttachShellPID(
      sessionID: "sess-1",
      shellPID: getppid())
    let (registeredStatus, body) = try request(
      socketPath: socketPath,
      path: LabanControlServer.sessionAttachPath,
      method: "POST",
      body: Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8))
    XCTAssertEqual(registeredStatus, 200)
    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    XCTAssertEqual(json["sessionID"] as? String, "sess-1")
    XCTAssertNil(json["token"] as? String)
  }

  func testAttachRedeemBindsSessionToConnectionNotReplayableBearer() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let bootstrap = server.mintSessionAttachBootstrap(sessionID: "sess-bound")
    server.registerAttachShellPID(
      sessionID: "sess-bound",
      shellPID: getppid())

    let (fd, sessionID) = try ControlUDSClient.redeemAttachBootstrap(
      socketPath: socketPath,
      bootstrap: bootstrap)
    defer { Darwin.close(fd) }
    XCTAssertEqual(sessionID, "sess-bound")

    let (boundStatus, _) = try ControlUDSClient.request(
      fd: fd,
      path: "/debug/state",
      keepConnectionOpen: true)
    XCTAssertEqual(boundStatus, 200)
    XCTAssertEqual(router.legacyQueries().last?.scopedSessionID, "sess-bound")

    Darwin.close(fd)
    let (unauthStatus, _) = try request(socketPath: socketPath, path: "/debug/state")
    XCTAssertEqual(unauthStatus, 401)
  }

  func testAttachRedeemAllowsOnlyDirectShellChild() {
    LabanControlServer.skipExecutableVerificationForTests = false
    defer { LabanControlServer.skipExecutableVerificationForTests = true }
    let selfPID = ProcessInfo.processInfo.processIdentifier
    XCTAssertFalse(
      LabanControlServer.isAllowedAttachRedeemer(peerPID: selfPID, shellPID: selfPID))
    XCTAssertFalse(
      LabanControlServer.isAllowedAttachRedeemer(
        peerPID: selfPID, shellPID: getppid()))
  }

  func testLabanAgentExecutablePathIsRecognized() {
    let bundledPath = "/Applications/Laban.app/Contents/MacOS/laban-agent"
    XCTAssertTrue(
      ControlProcessInfo.isLabanAgentExecutable(
        bundledPath,
        expectedExecutablePath: bundledPath))
    XCTAssertFalse(ControlProcessInfo.isLabanAgentExecutable("/usr/bin/zsh"))
  }

  func testAppObserveQuerySetsReadRedaction() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (status, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/state",
      token: start.appObserveToken)
    XCTAssertEqual(status, 200)
    let queries = router.legacyQueries()
    XCTAssertEqual(queries.count, 1)
    XCTAssertEqual(queries[0].readRedaction, .appObserveSummary)
  }

  func testMalformedRequestReturns400Or405() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let (methodStatus, _) = try request(
      socketPath: socketPath,
      path: "/debug/health",
      method: "INVALID",
      token: nil)
    XCTAssertEqual(methodStatus, 405)

    let fd = try ControlUDSClient.connect(socketPath: socketPath)
    defer { Darwin.close(fd) }
    let duplicateAuth =
      "GET /debug/health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n"
    try sendRaw(fd, Data(duplicateAuth.utf8))
    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n < 0 && errno == EINTR { continue }
      if n <= 0 { break }
      raw.append(contentsOf: buffer[0..<n])
    }
    XCTAssertTrue(raw.prefix(9).elementsEqual(Data("HTTP/1.1 ".utf8)))
    XCTAssertNotNil(raw.range(of: Data("400".utf8)))
  }

  func testOversizedBodyReturns413() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let fd = try ControlUDSClient.connect(socketPath: socketPath)
    defer { Darwin.close(fd) }
    let request =
      "POST /debug/actions HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5000000\r\n\r\n"
    try sendRaw(fd, Data(request.utf8))

    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n < 0 && errno == EINTR { continue }
      if n <= 0 { break }
      raw.append(contentsOf: buffer[0..<n])
    }
    XCTAssertTrue(raw.prefix(9).elementsEqual(Data("HTTP/1.1 ".utf8)))
    XCTAssertNotNil(raw.range(of: Data("413".utf8)))
  }

  func testAcceptedClientFdsAreCloseOnExec() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let bootstrap = server.mintSessionAttachBootstrap(sessionID: "sess-fd")
    server.registerAttachShellPID(sessionID: "sess-fd", shellPID: getppid())

    let (fd, _) = try ControlUDSClient.redeemAttachBootstrap(
      socketPath: socketPath,
      bootstrap: bootstrap)
    defer { Darwin.close(fd) }

    let listenerFD = server.testListenerFD
    let script =
      "for fd in \(listenerFD) \(fd); do if [ -e /dev/fd/${fd} ]; then exit 1; fi; done; exit 0"
    var pid = pid_t(0)
    let args: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sh"), strdup("-c"), strdup(script), nil,
    ]
    defer { for arg in args { free(arg) } }
    let result = posix_spawn(&pid, "/bin/sh", nil, nil, args, environ)
    XCTAssertEqual(result, 0)

    var status: Int32 = 0
    waitpid(pid, &status, 0)
    XCTAssertEqual(
      status, 0,
      "child inherited control listener fd \(listenerFD) or client fd \(fd)")
  }

  func testUnauthorizedRequestProducesExactlyOneResponse() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let fd = try ControlUDSClient.connect(socketPath: socketPath)
    defer { Darwin.close(fd) }

    let request = "GET /debug/health HTTP/1.1\r\nHost: localhost\r\n\r\n"
    try sendRaw(fd, Data(request.utf8))

    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n < 0 && errno == EINTR { continue }
      if n <= 0 { break }
      raw.append(contentsOf: buffer[0..<n])
    }

    XCTAssertTrue(raw.prefix(9).elementsEqual(Data("HTTP/1.1 ".utf8)))
    XCTAssertNotNil(raw.range(of: Data("401".utf8)))
    let text = String(data: raw, encoding: .utf8) ?? ""
    XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 ").count - 1, 1)
  }

  private func makeTempSocketPath() throws -> String {
    "/tmp/laban-ctl-\(UUID().uuidString.prefix(8)).sock"
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

  private func sendRaw(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var sent = 0
      while sent < rawBuffer.count {
        let n = Darwin.send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw POSIXError(.EIO) }
        sent += n
      }
    }
  }
}

private struct SpyState: Codable, Equatable {
  var tabs: [String]
}

private struct SpyActionResult: Codable, Equatable {
  var ok: Bool
}

private struct SpyLegacyQueryResult: Codable, Equatable {
  var intentID: String
  var params: [String: String]
}

private struct SpyLegacyControlResult: Codable, Equatable {
  var intentID: String
  var body: String
  var params: [String: String]
}

private final class SpyIntentRouter: IntentRouter {
  static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])

  private let lock = NSLock()
  private var routedIntents: [Intent] = []
  private var routedQueries: [Query] = []
  private var routedLegacyQueries: [LegacyDebugQueryInput] = []
  private var routedLegacyControls: [LegacyDebugControlInput] = []
  private var routedArtifacts: [ArtifactRequest] = []

  func route(_ intent: Intent) -> ControlResponse {
    lock.lock()
    routedIntents.append(intent)
    lock.unlock()
    return .json(SpyActionResult(ok: true))
  }

  func query(_ query: Query) -> ControlResponse {
    lock.lock()
    routedQueries.append(query)
    lock.unlock()
    return .json(SpyState(tabs: ["spy"]))
  }

  func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    lock.lock()
    routedLegacyQueries.append(query)
    lock.unlock()
    return .json(SpyLegacyQueryResult(intentID: query.intentID, params: query.params))
  }

  func control(_ input: LegacyDebugControlInput) -> ControlResponse {
    lock.lock()
    routedLegacyControls.append(input)
    lock.unlock()
    return .json(
      SpyLegacyControlResult(
        intentID: input.intentID,
        body: String(data: input.body, encoding: .utf8) ?? "",
        params: input.params))
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    lock.lock()
    routedArtifacts.append(request)
    lock.unlock()
    return .binary(
      Self.pngBytes,
      contentType: "image/png",
      headers: [
        "X-App-Frame": "12",
        "X-App-Size": "80x24",
      ])
  }

  func intents() -> [Intent] {
    lock.lock()
    defer { lock.unlock() }
    return routedIntents
  }

  func queries() -> [Query] {
    lock.lock()
    defer { lock.unlock() }
    return routedQueries
  }

  func legacyQueries() -> [LegacyDebugQueryInput] {
    lock.lock()
    defer { lock.unlock() }
    return routedLegacyQueries
  }

  func legacyControls() -> [LegacyDebugControlInput] {
    lock.lock()
    defer { lock.unlock() }
    return routedLegacyControls
  }

  func artifacts() -> [ArtifactRequest] {
    lock.lock()
    defer { lock.unlock() }
    return routedArtifacts
  }
}

final class ControlProcessInfoTests: XCTestCase {
  func testRejectsArbitraryPathNamedLabanAgent() {
    XCTAssertFalse(ControlProcessInfo.isLabanAgentExecutable("/tmp/laban-agent"))
    XCTAssertFalse(ControlProcessInfo.isLabanAgentExecutable("/usr/local/bin/laban-agent"))
    XCTAssertFalse(ControlProcessInfo.isLabanAgentExecutable("/Users/rrj/bin/laban-agent"))
  }

  func testRejectsSymlinkToWrongPath() throws {
    let tmp = FileManager.default.temporaryDirectory
    let fakeAgent = tmp.appendingPathComponent(UUID().uuidString + "-laban-agent")
    let symlink = tmp.appendingPathComponent(UUID().uuidString + "-laban-agent-link")
    try Data().write(to: fakeAgent)
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: fakeAgent)
    defer {
      try? FileManager.default.removeItem(at: fakeAgent)
      try? FileManager.default.removeItem(at: symlink)
    }

    XCTAssertFalse(ControlProcessInfo.isLabanAgentExecutable(symlink.path))
  }

  func testRejectsWrongBaseName() {
    let expected = "/Applications/Laban.app/Contents/MacOS/laban-agent"
    XCTAssertFalse(
      ControlProcessInfo.isLabanAgentExecutable(
        "/Applications/Laban.app/Contents/MacOS/laban-agent-evil",
        expectedExecutablePath: expected))
    XCTAssertFalse(
      ControlProcessInfo.isLabanAgentExecutable(
        "/Applications/Laban.app/Contents/MacOS/laband",
        expectedExecutablePath: expected))
  }

  func testRejectsSpoofedAppBundlePathsWhenExpectedPathDiffers() {
    let expected = "/Applications/Laban.app/Contents/MacOS/laban-agent"
    XCTAssertFalse(
      ControlProcessInfo.isLabanAgentExecutable(
        "/tmp/Evil.app/Contents/MacOS/laban-agent",
        expectedExecutablePath: expected))
    XCTAssertFalse(
      ControlProcessInfo.isLabanAgentExecutable(
        "/Users/rrj/Downloads/Laban.app/Contents/MacOS/laban-agent",
        expectedExecutablePath: expected))
  }

  func testAcceptsDevBuildPathOnlyWhenAllowed() {
    let devPath =
      "/Users/rrj/.cursor/worktrees/laban/c2yt/.build/arm64-apple-macosx/debug/laban-agent"
    XCTAssertTrue(
      ControlProcessInfo.isLabanAgentExecutable(
        devPath,
        expectedExecutablePath: devPath,
        allowDevBuildPath: true))
    XCTAssertFalse(
      ControlProcessInfo.isLabanAgentExecutable(
        devPath,
        expectedExecutablePath: devPath,
        allowDevBuildPath: false))
    XCTAssertFalse(
      ControlProcessInfo.isLabanAgentExecutable(
        "/tmp/fake-laban/.build/debug/laban-agent",
        expectedExecutablePath: devPath,
        allowDevBuildPath: true))
  }
}
