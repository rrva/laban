import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanApp

final class ControlServerPhase0Tests: XCTestCase {
  func testLiveRouterSnapshotStateListsTabs() throws {
    let (model, router) = try makeModelAndRouter()
    let state = router.query(LegacyDebugQueryInput(intentID: "app.state"))
    XCTAssertEqual(state.status, 200)
    let decoded = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = try XCTUnwrap(decoded["tabs"] as? [[String: Any]])
    XCTAssertEqual(tabs.count, model.tabs.count)
  }

  func testEndToEndAppStateOverUDS() throws {
    let (model, router) = try makeModelAndRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (stateStatus, stateData) = try request(
      socketPath: start.socketPath,
      path: "/debug/state",
      token: start.appObserveToken)
    XCTAssertEqual(stateStatus, 200)
    let state = try JSONSerialization.jsonObject(with: stateData) as! [String: Any]
    let tabs = try XCTUnwrap(state["tabs"] as? [[String: Any]])
    XCTAssertEqual(tabs.count, model.tabs.count)

    let (unauthorizedStatus, _) = try request(socketPath: start.socketPath, path: "/debug/state")
    XCTAssertEqual(unauthorizedStatus, 401)
  }

  func testGuiInputActuationUnavailable() throws {
    let (_, router) = try makeModelAndRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (status, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/actions",
      method: "POST",
      token: start.appObserveToken,
      body: Data(#"{"action":"selectTab","index":0}"#.utf8))
    XCTAssertEqual(status, 403)
  }

  func testServerStartStopStartReleasesListener() throws {
    let (_, router) = try makeModelAndRouter()
    let server = LabanControlServer(router: router, surface: .gui)

    let first = try server.start()
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.socketPath))
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.socketPath))

    let second = try server.start()
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.socketPath))
    server.stop()
  }

  private func makeModelAndRouter() throws -> (AppModel, LiveIntentRouter) {
    let model = try AppModel()
    _ = try model.createTab()
    return (model, LiveIntentRouter(model: model))
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
