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

  func testAppObserveStateRedactsCrossTabFindNeedles() throws {
    let (model, router, ownSessionID, otherSessionID) = try makeModelRouterAndSessions()
    _ = model.startFind(sessionID: otherSessionID, needle: "secret-needle")
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (status, data) = try request(
      socketPath: start.socketPath,
      path: "/debug/state",
      token: start.appObserveToken)
    XCTAssertEqual(status, 200)

    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let findStates = try XCTUnwrap(json["findStateBySession"] as? [String: Any])
    XCTAssertTrue(findStates.isEmpty)
    let tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
    XCTAssertFalse(tabs.isEmpty)
    for tab in tabs {
      XCTAssertNil(tab["progress"])
      XCTAssertNil(tab["terminalTitle"])
      XCTAssertNil(tab["userTitle"])
      let agent = try XCTUnwrap(tab["agent"] as? [String: Any])
      XCTAssertNil(agent["agentName"])
      XCTAssertNil(agent["taskLabel"])
      XCTAssertNil(agent["sessionName"])
    }
    let raw = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(raw.contains("secret-needle"))
    _ = ownSessionID
  }

  func testSessionObserveSelectionUsesEnvironmentProvider() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let sessionID = try XCTUnwrap(model.tabs.first?.sessionId)
    let selection = TerminalSelection(
      sessionId: sessionID,
      anchor: TerminalCellCoordinate(row: 0, col: 0),
      focus: TerminalCellCoordinate(row: 0, col: 3))
    var environment = LiveControlEnvironment.default(model: model)
    environment.selectionProvider = { _ in selection }
    let router = LiveIntentRouter(model: model, environment: environment)

    let response = router.query(
      LegacyDebugQueryInput(
        intentID: "selection.read",
        scopedSessionID: sessionID))
    XCTAssertEqual(response.status, 200)
    let json = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    XCTAssertEqual(json["active"] as? Bool, true)
    XCTAssertEqual(json["sessionId"] as? String, sessionID)
  }

  func testSessionObserveTerminalModesUsesScopedTabNotActiveTab() throws {
    let model = try AppModel()
    _ = try model.createTab()
    _ = try model.createTab()
    let ownSessionID = model.tabs[0].sessionId
    let otherSessionID = model.tabs[1].sessionId
    model.selectTab(model.tabs[1].id)
    let router = LiveIntentRouter(model: model)

    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: ownSessionID)
    let (status, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/terminal-modes",
      token: sessionToken)
    XCTAssertEqual(status, 200)
    _ = otherSessionID
  }

  func testSessionObserveStateOmitsOtherTabNotifications() throws {
    let (model, router, ownSessionID, otherSessionID) = try makeModelRouterAndSessions()
    let otherTabId = try XCTUnwrap(model.tabs.first { $0.sessionId == otherSessionID }?.id)
    model.recordAttentionNotificationDecision(
      AttentionNotificationDecision(
        event: AttentionNotificationEvent(
          tabId: otherTabId,
          source: .tabAttention,
          category: .needsAction,
          title: "other-tab-secret",
          body: "cross-session leak",
          dedupeKey: "other-tab-secret"),
        action: .posted))

    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: ownSessionID)
    let (status, data) = try request(
      socketPath: start.socketPath,
      path: "/debug/state",
      token: sessionToken)
    XCTAssertEqual(status, 200)

    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let notifications = try XCTUnwrap(json["attentionNotifications"] as? [[String: Any]])
    XCTAssertTrue(notifications.isEmpty)
    let raw = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(raw.contains("other-tab-secret"))
    XCTAssertFalse(raw.contains("cross-session leak"))
    _ = otherSessionID
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
    try ControlUDSTestSupport.requestFromBackgroundThread(
      socketPath: socketPath,
      path: path,
      method: method,
      token: token,
      body: body)
  }
}
