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

  func testWindowScreenshotReturnsTypedPNGForVisibleScopedSession() throws {
    let model = try AppModel()
    let sessionID = try XCTUnwrap(model.activeTab?.sessionId)
    let router = LiveIntentRouter(model: model)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 4, 2])
    router.bindWindowScreenshotProvider {
      LabanWindowScreenshot(pngData: png, width: 1200, height: 800)
    }

    let response = router.query(
      LegacyDebugQueryInput(
        intentID: "window.screenshot",
        scopedSessionID: sessionID))

    XCTAssertEqual(response.status, 200)
    let decoded = try JSONDecoder().decode(WindowScreenshotResponse.self, from: response.body)
    XCTAssertEqual(Data(base64Encoded: decoded.pngBase64), png)
    XCTAssertEqual(decoded.width, 1200)
    XCTAssertEqual(decoded.height, 800)
    XCTAssertEqual(decoded.byteCount, png.count)
    XCTAssertTrue(decoded.includesDialogs)
  }

  func testWindowScreenshotRejectsWhenScopedSessionIsNotVisible() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let hiddenSessionID = model.tabs[0].sessionId
    model.selectTab(model.tabs[1].id)
    var captureCalled = false
    let router = LiveIntentRouter(model: model)
    router.bindWindowScreenshotProvider {
      captureCalled = true
      return nil
    }

    let response = router.query(
      LegacyDebugQueryInput(
        intentID: "window.screenshot",
        scopedSessionID: hiddenSessionID))

    XCTAssertEqual(response.status, 409)
    XCTAssertFalse(captureCalled)
    XCTAssertTrue(
      String(data: response.body, encoding: .utf8)?.contains("sessionNotVisible") == true)
  }

  func testAppObserveTokenDeniesWindowScreenshot() throws {
    let model = try AppModel()
    let router = LiveIntentRouter(model: model)
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (status, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/window-screenshot",
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

  func testScrollViewportScopedCallerNeverUsesActiveTab() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let scopedSessionID = model.tabs[0].sessionId
    let activeSessionID = model.tabs[1].sessionId
    model.selectTab(model.tabs[1].id)
    XCTAssertEqual(model.activeTab?.sessionId, activeSessionID)

    let router = LiveIntentRouter(model: model)
    let body = Data(#"{"deltaRows":1}"#.utf8)
    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "terminal.scrollViewport",
          action: "scrollViewport",
          body: body,
          scopedSessionID: scopedSessionID)))

    XCTAssertEqual(response.status, 200)
    let json = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    // A session-scoped caller with an omitted request.sessionId must resolve
    // to its own scoped session, never the model's active tab (C12).
    XCTAssertEqual(json["activeSessionId"] as? String, scopedSessionID)
    XCTAssertNotEqual(json["activeSessionId"] as? String, activeSessionID)
  }

  func testScrollViewportRejectsMismatchedExplicitTarget() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let scopedSessionID = model.tabs[0].sessionId
    let otherSessionID = model.tabs[1].sessionId

    let router = LiveIntentRouter(model: model)
    let body = Data(#"{"sessionId":"\#(otherSessionID)","deltaRows":1}"#.utf8)
    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "terminal.scrollViewport",
          action: "scrollViewport",
          body: body,
          scopedSessionID: scopedSessionID)))

    XCTAssertEqual(response.status, 403)
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

  func testSessionObserveStateRedactsTitlesAndMetadata() throws {
    let (model, router, ownSessionID, _) = try makeModelRouterAndSessions()
    let tab = model.tabs.first { $0.sessionId == ownSessionID }!
    try model.renameTab(tab.id, title: "secret-own-title")
    try model.updateTitleMetadata(
      forTab: tab.id,
      workspace: TabWorkspaceMetadata(cwd: "/secret/path"),
      process: TabProcessMetadata(foregroundProcess: "secret-process"))

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
    let tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
    XCTAssertEqual(tabs.count, 1)
    let ownTab = tabs[0]
    XCTAssertEqual(ownTab["sessionId"] as? String, ownSessionID)
    XCTAssertEqual(ownTab["title"] as? String, "")
    XCTAssertEqual(ownTab["displayTitle"] as? String, "")
    XCTAssertNil(ownTab["terminalTitle"])
    XCTAssertNil(ownTab["userTitle"])
    let workspace = try XCTUnwrap(ownTab["workspace"] as? [String: Any])
    XCTAssertNil(workspace["cwd"])
    let process = try XCTUnwrap(ownTab["process"] as? [String: Any])
    XCTAssertNil(process["foregroundProcess"])
    let agent = try XCTUnwrap(ownTab["agent"] as? [String: Any])
    XCTAssertNil(agent["agentName"])
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

  func testSessionObserveUnknownGuiActionReturns404WithoutActiveIDs() throws {
    let (_, router, ownSessionID, otherSessionID) = try makeModelRouterAndSessions()
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: ownSessionID)
    let (status, data) = try request(
      socketPath: start.socketPath,
      path: "/debug/actions",
      method: "POST",
      token: sessionToken,
      body: Data(#"{"action":"futureAction"}"#.utf8))

    XCTAssertEqual(status, 404)
    let raw = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(raw.contains(ownSessionID))
    XCTAssertFalse(raw.contains(otherSessionID))
    XCTAssertFalse(raw.contains("activeSessionId"))
    XCTAssertFalse(raw.contains("activeTabId"))
  }

  func testStaleSessionObserveStateDoesNotFallBackToGlobalActiveSession() throws {
    let (model, router, _, otherSessionID) = try makeModelRouterAndSessions()
    _ = model
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: "stale-session")
    let (status, data) = try request(
      socketPath: start.socketPath,
      path: "/debug/state",
      token: sessionToken)
    XCTAssertEqual(status, 200)

    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
    XCTAssertTrue(tabs.isEmpty)
    XCTAssertNil(json["activeSessionId"])
    XCTAssertNil(json["activeTabId"])
    let raw = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(raw.contains(otherSessionID))
  }

  func testGUIDiscoveryAndHealthEndpointsReturn200() throws {
    let (model, router, _, _) = try makeModelRouterAndSessions()
    _ = model
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let (discoveryStatus, discoveryData) = try request(
      socketPath: start.socketPath,
      path: "/debug",
      token: start.appObserveToken)
    XCTAssertEqual(discoveryStatus, 200)
    let discoveryJSON = try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any]
    XCTAssertEqual(discoveryJSON?["mode"] as? String, "gui")
    XCTAssertEqual(discoveryJSON?["name"] as? String, "laban-debug")
    let appObserveActions = discoveryJSON?["actions"] as? [[String: Any]]
    XCTAssertEqual(appObserveActions?.compactMap { $0["name"] as? String } ?? [], [])

    let (capabilitiesStatus, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/capabilities",
      token: start.appObserveToken)
    XCTAssertEqual(capabilitiesStatus, 200)

    let sessionToken = server.mintSessionObserveToken(sessionID: model.tabs[0].sessionId)
    let (sessionDiscoveryStatus, sessionDiscoveryData) = try request(
      socketPath: start.socketPath,
      path: "/debug",
      token: sessionToken)
    XCTAssertEqual(sessionDiscoveryStatus, 200)
    let sessionDiscoveryJSON =
      try JSONSerialization.jsonObject(with: sessionDiscoveryData) as? [String: Any]
    let actions = try XCTUnwrap(sessionDiscoveryJSON?["actions"] as? [[String: Any]])
    let actionNames = Set(actions.compactMap { $0["name"] as? String })
    XCTAssertEqual(actionNames, ["propose", "scrollViewport"])
    XCTAssertFalse(actionNames.contains("typeText"))
    XCTAssertFalse(actionNames.contains("key"))
    XCTAssertFalse(actionNames.contains("paste"))
    XCTAssertFalse(actionNames.contains("setClipboardText"))

    let (healthStatus, healthData) = try request(
      socketPath: start.socketPath,
      path: "/debug/health",
      token: start.appObserveToken)
    XCTAssertEqual(healthStatus, 200)
    let healthJSON = try JSONSerialization.jsonObject(with: healthData) as? [String: Any]
    XCTAssertEqual(healthJSON?["mode"] as? String, "gui")
    XCTAssertEqual(healthJSON?["ok"] as? Bool, true)
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
