import Foundation
import LabanControl
import LabanCore
import XCTest

final class LabanControlServerTests: XCTestCase {
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

  func testStartHostPortReturnsReadiness() throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    XCTAssertTrue(readiness.debugServer.hasPrefix("http://127.0.0.1:"))
    XCTAssertFalse(readiness.debugToken.isEmpty)
    XCTAssertEqual(readiness.pid, ProcessInfo.processInfo.processIdentifier)
    XCTAssertFalse(readiness.runId.isEmpty)
  }

  func testStateRouteDispatchesQuery() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/state",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(router.queries(), [.state])
    let state = try JSONDecoder().decode(SpyState.self, from: data)
    XCTAssertEqual(state.tabs, ["spy"])
  }

  func testLegacyReadRoutePreservesQueryParameters() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/events?since=7",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [LegacyDebugQueryInput(intentID: "log.events", params: ["since": "7"])])
    let result = try JSONDecoder().decode(SpyLegacyQueryResult.self, from: data)
    XCTAssertEqual(result.intentID, "log.events")
    XCTAssertEqual(result.params, ["since": "7"])
  }

  func testSessionDetailRouteDecodesPathAndPreservesQueryParameters() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/sessions/session%201?includeGrid=true",
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

  func testLegacyBodyRouteDispatchesRawBodyAndIntentID() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let body = Data(#"{"needle":"apple"}"#.utf8)
    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/find/start?mode=literal",
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

  func testLegacyNoBodyRouteDispatchesEmptyBody() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/persistence/flush",
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

  func testCaptureStatusRouteDispatchesLegacyQuery() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/capture/status",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.legacyQueries(),
      [LegacyDebugQueryInput(intentID: "capture.status")])
    let result = try JSONDecoder().decode(SpyLegacyQueryResult.self, from: data)
    XCTAssertEqual(result.intentID, "capture.status")
  }

  func testScreenshotArtifactRouteDispatchesArtifactRequestAndPreservesHeaders() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .headless)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data, response) = try await requestWithResponse(
      url: "\(readiness.debugServer)/debug/screenshot?target=active",
      token: readiness.debugToken)

    XCTAssertEqual(status, 200)
    XCTAssertEqual(data, SpyIntentRouter.pngBytes)
    XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/png")
    XCTAssertEqual(response.value(forHTTPHeaderField: "X-App-Frame"), "12")
    XCTAssertEqual(response.value(forHTTPHeaderField: "X-App-Size"), "80x24")
    let artifacts = router.artifacts()
    XCTAssertEqual(artifacts.count, 1)
    XCTAssertEqual(artifacts.first?.id, "artifact.screenshot")
    XCTAssertEqual(artifacts.first?.params, ["target": "active"])
  }

  func testSelectTabRouteDispatchesIntent() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"selectTab","index":7}"#.utf8))

    XCTAssertEqual(status, 200)
    XCTAssertEqual(router.intents(), [.tabSelect(TabSelectInput(index: 7))])
    let result = try JSONDecoder().decode(SpyActionResult.self, from: data)
    XCTAssertTrue(result.ok)
  }

  func testUnavailableIntentReturns404WithoutRouterCall() async throws {
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
        errorSchema: tabSelect.errorSchema)
    ])
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui, catalog: catalog)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"selectTab","index":1}"#.utf8))

    XCTAssertEqual(status, 404)
    XCTAssertEqual(router.intents(), [])
    XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"unavailable on gui"}"#)
  }

  func testFixtureActionIsKnownButUnavailableOnGUIWithoutRouterCall() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, data) = try await request(
      url: "\(readiness.debugServer)/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"feedOutput","text":"abc"}"#.utf8))

    XCTAssertEqual(status, 404)
    XCTAssertEqual(router.intents(), [])
    XCTAssertEqual(String(data: data, encoding: .utf8), #"{"error":"unavailable on gui"}"#)
  }

  func testUnknownActionDispatchesUnsupportedIntentInsteadOfUnavailable404() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let (status, _) = try await request(
      url: "\(readiness.debugServer)/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"future.action"}"#.utf8))

    XCTAssertEqual(status, 200)
    XCTAssertEqual(
      router.intents(),
      [.unsupportedDebugAction(UnsupportedDebugActionInput(action: "future.action"))])
  }

  func testMalformedAndMissingActionsRemainBadRequest() async throws {
    let router = SpyIntentRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let missing = try await request(
      url: "\(readiness.debugServer)/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"text":"abc"}"#.utf8))
    XCTAssertEqual(missing.0, 400)
    XCTAssertEqual(String(data: missing.1, encoding: .utf8), #"{"error":"bad request"}"#)

    let malformed = try await request(
      url: "\(readiness.debugServer)/debug/actions",
      method: "POST",
      token: readiness.debugToken,
      body: Data(#"{"action":"selectTab""#.utf8))
    XCTAssertEqual(malformed.0, 400)
    XCTAssertEqual(String(data: malformed.1, encoding: .utf8), #"{"error":"bad request"}"#)
    XCTAssertEqual(router.intents(), [])
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
    XCTAssertEqual(endpoints.count, 45)
    XCTAssertEqual(Set(endpoints.map { "\($0.binding.method) \($0.binding.path)" }).count, 45)
    XCTAssertNotNil(
      endpoints.first { $0.binding.method == "GET" && $0.binding.path == "/debug/sessions/<id>" })

    for endpoint in endpoints {
      guard let intentID = endpoint.fixedIntentId else {
        continue
      }
      XCTAssertNotNil(IntentCatalog.all.descriptor(id: intentID), intentID)
    }
  }

  private func request(
    url: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) async throws -> (Int, Data) {
    let (status, data, _) = try await requestWithResponse(
      url: url,
      method: method,
      token: token,
      body: body)
    return (status, data)
  }

  private func requestWithResponse(
    url: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) async throws -> (Int, Data, HTTPURLResponse) {
    var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
    request.httpMethod = method
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return (http.statusCode, data, http)
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
