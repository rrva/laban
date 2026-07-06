import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanApp

final class LiveControlObserveTests: XCTestCase {
  func testSessionObserveTokenReadsOwnSessionDetail200() throws {
    let (model, router, ownSessionID, _) = try makeModelRouterAndSessions()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: ownSessionID)
    let (status, _) = try request(
      socketPath: socketPath,
      path: "/debug/sessions/\(ownSessionID)",
      token: sessionToken)

    XCTAssertEqual(status, 200)
  }

  func testSessionObserveTokenDeniesOtherSessionDetail403() throws {
    let (model, router, ownSessionID, otherSessionID) = try makeModelRouterAndSessions()
    let server = LabanControlServer(router: router, surface: .gui)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: ownSessionID)
    let (status, _) = try request(
      socketPath: socketPath,
      path: "/debug/sessions/\(otherSessionID)",
      token: sessionToken)

    XCTAssertEqual(status, 403)
  }

  func testAppObserveTokenDeniesSelectionRead403() throws {
    let (model, router, _, _) = try makeModelRouterAndSessions()
    _ = model
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (status, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/selection",
      token: start.appObserveToken)

    XCTAssertEqual(status, 403)
  }

  func testAppObserveTokenAllowsTerminalModes200() throws {
    let (model, router, _, _) = try makeModelRouterAndSessions()
    _ = model
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: start.socketPath,
      path: "/debug/terminal-modes",
      token: start.appObserveToken)

    XCTAssertEqual(status, 200)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertNotNil(json["grapheme_cluster_2027"])
  }

  func testGuiInputActuationRoutes404() throws {
    let (model, router, _, _) = try makeModelRouterAndSessions()
    _ = model
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let typeText = try request(
      socketPath: start.socketPath,
      path: "/debug/actions",
      method: "POST",
      token: start.appObserveToken,
      body: Data(#"{"action":"typeText","text":"hi"}"#.utf8))
    XCTAssertEqual(typeText.0, 404)

    let selectTab = try request(
      socketPath: start.socketPath,
      path: "/debug/actions",
      method: "POST",
      token: start.appObserveToken,
      body: Data(#"{"action":"selectTab","index":0}"#.utf8))
    XCTAssertEqual(selectTab.0, 404)
  }

  private func makeModelRouterAndSessions() throws -> (
    AppModel, LiveIntentRouter, String, String
  ) {
    let model = try AppModel()
    _ = try model.createTab()
    let tabs = model.tabs
    XCTAssertGreaterThanOrEqual(tabs.count, 2)
    let ownSessionID = tabs[0].sessionId
    let otherSessionID = tabs[1].sessionId
    let router = LiveIntentRouter(model: model)
    return (model, router, ownSessionID, otherSessionID)
  }

  private func makeTempSocketPath() throws -> String {
    "/tmp/laban-live-observe-\(UUID().uuidString.prefix(8)).sock"
  }

  private func request(
    socketPath: String,
    path: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) throws -> (Int, Data) {
    try DispatchQueue.global(qos: .userInitiated).sync {
      try ControlUDSClient.request(
        socketPath: socketPath,
        method: method,
        path: path,
        token: token,
        body: body)
    }
  }
}
