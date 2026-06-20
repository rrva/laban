import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class ControlServerPhase0Tests: XCTestCase {
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

  func testLiveRouterSelectTabChangesActiveTab() throws {
    let (model, router) = try makeModelAndRouter()
    let initial = router.snapshotState()
    XCTAssertEqual(initial.tabs.count, 2)

    let target = try XCTUnwrap(initial.tabs.first { !$0.active })
    let result = router.selectTab(index: target.index)

    XCTAssertTrue(result.ok)
    XCTAssertEqual(result.activeTabId, model.tabs[target.index].id)
    XCTAssertEqual(router.snapshotState().activeTabId, model.tabs[target.index].id)
  }

  func testLiveRouterRejectsOutOfRange() throws {
    let (_, router) = try makeModelAndRouter()
    let before = router.snapshotState().activeTabId

    let result = router.selectTab(index: 99)

    XCTAssertFalse(result.ok)
    XCTAssertNotNil(result.error)
    XCTAssertEqual(result.activeTabId, before)
    XCTAssertEqual(router.snapshotState().activeTabId, before)
  }

  func testEndToEndOverLoopback() async throws {
    let (model, router) = try makeModelAndRouter()
    let server = LabanControlServer(router: router)
    let info = try server.start()
    defer { server.stop() }

    let (stateStatus, stateData) = try await request(
      url: "\(info.url)/debug/state",
      token: info.token)
    XCTAssertEqual(stateStatus, 200)
    let state = try JSONDecoder().decode(ControlState.self, from: stateData)
    XCTAssertEqual(state.tabs.count, 2)

    let (unauthorizedStatus, _) = try await request(url: "\(info.url)/debug/state")
    XCTAssertEqual(unauthorizedStatus, 401)

    let (actionStatus, actionData) = try await request(
      url: "\(info.url)/debug/actions",
      method: "POST",
      token: info.token,
      body: Data(#"{"action":"selectTab","index":0}"#.utf8))
    XCTAssertEqual(actionStatus, 200)
    let action = try JSONDecoder().decode(ControlActionResult.self, from: actionData)
    XCTAssertTrue(action.ok)
    XCTAssertEqual(action.activeTabId, model.tabs[0].id)

    let (_, finalData) = try await request(url: "\(info.url)/debug/state", token: info.token)
    let final = try JSONDecoder().decode(ControlState.self, from: finalData)
    XCTAssertEqual(final.activeTabId, model.tabs[0].id)
  }

  func testServerStartStopStartReleasesListener() throws {
    let (_, router) = try makeModelAndRouter()
    let server = LabanControlServer(router: router)

    let first = try server.start()
    XCTAssertTrue(first.url.hasPrefix("http://127.0.0.1:"))
    server.stop()

    let second = try server.start()
    XCTAssertTrue(second.url.hasPrefix("http://127.0.0.1:"))
    server.stop()
  }

  private func makeModelAndRouter() throws -> (AppModel, LiveIntentRouter) {
    let model = try AppModel()
    _ = try model.createTab()
    return (model, LiveIntentRouter(model: model))
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
