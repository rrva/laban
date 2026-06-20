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

  private func request(
    url: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) async throws -> (Int, Data) {
    var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
    request.httpMethod = method
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return (http.statusCode, data)
  }
}

private struct SpyState: Codable, Equatable {
  var tabs: [String]
}

private struct SpyActionResult: Codable, Equatable {
  var ok: Bool
}

private final class SpyIntentRouter: IntentRouter {
  private let lock = NSLock()
  private var routedIntents: [Intent] = []
  private var routedQueries: [Query] = []

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

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    nil
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
}
