import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

final class HeadlessIntentRouterTests: XCTestCase {
  func testPaneIntentsSplitFocusAndCloseThroughRouter() throws {
    let (runtime, artifacts) = try makeRuntime("router-panes")
    defer {
      runtime.shutdown(terminateRemoteSessions: true)
      try? FileManager.default.removeItem(at: artifacts)
    }
    let router = HeadlessIntentRouter(runtime: runtime)
    let left = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    for action in ["pane.split", "pane.focus", "pane.close"] {
      let payload: [String: Any] =
        action == "pane.split" ? ["action": action] : ["action": action, "sessionId": left]
      let response = router.route(
        .legacyDebugAction(
          LegacyDebugActionInput(
            intentID: action, action: action,
            body: try JSONSerialization.data(withJSONObject: payload))))
      XCTAssertEqual(response.status, 200)
      if action == "pane.focus" { XCTAssertEqual(runtime.model.activeTab?.focusedSessionId, left) }
    }
    XCTAssertEqual(runtime.model.activeTab?.allSessionIds.count, 1)
    XCTAssertNotEqual(runtime.model.activeTab?.focusedSessionId, left)
  }

  func testHealthLegacyQueryReturnsJSONControlResponse() throws {
    let (runtime, artifacts) = try makeRuntime("router-health")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.query(LegacyDebugQueryInput(intentID: "debug.health"))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["ok"] as? Bool, true)
    XCTAssertEqual(body["mode"] as? String, "headless")
    XCTAssertNotNil(body["frame"])
  }

  func testEventsLegacyQueryUsesSinceParameter() throws {
    let (runtime, artifacts) = try makeRuntime("router-events")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let since = runtime.withRuntimeLock {
      let baseSeq = runtime.logs.eventSeq
      runtime.logs.appendEvent(EventEntry(kind: "before"))
      runtime.logs.appendEvent(EventEntry(kind: "after"))
      return baseSeq + 1
    }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.query(
      LegacyDebugQueryInput(intentID: "log.events", params: ["since": "\(since)"]))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    let events = try XCTUnwrap(body["events"] as? [[String: Any]])
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?["kind"] as? String, "after")
    XCTAssertEqual(body["next"] as? Int, since + 1)
  }

  func testNotificationStateReportsNativeUnavailable() throws {
    let (runtime, artifacts) = try makeRuntime("router-notifications-state")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.query(
      LegacyDebugQueryInput(intentID: "notifications.state"))

    XCTAssertEqual(response.status, 200)
    let snapshot = try JSONDecoder().decode(
      NativeNotificationDiagnosticsSnapshot.self, from: response.body)
    XCTAssertFalse(snapshot.nativeAvailable)
    XCTAssertNil(snapshot.identity)
    XCTAssertTrue(snapshot.events.isEmpty)
    XCTAssertEqual(snapshot.focusAuthorizationStatus, .unavailable)
    XCTAssertNil(snapshot.focusSuppressesNotifications)
    XCTAssertNil(snapshot.focusCheckedAt)
  }

  func testNotificationTestReturnsUnavailable() throws {
    let (runtime, artifacts) = try makeRuntime("router-notifications-test")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.control(
      LegacyDebugControlInput(
        intentID: "notifications.test",
        body: Data("{}".utf8)))

    XCTAssertEqual(response.status, 409)
    let body = try json(response)
    XCTAssertEqual(body["error"] as? String, "native notifications unavailable in headless mode")
  }

  func testScreenshotArtifactReturnsPNGHeaders() throws {
    let (runtime, artifacts) = try makeRuntime("router-screenshot")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = try XCTUnwrap(
      router.artifact(ArtifactRequest(id: "artifact.screenshot")))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "image/png")
    XCTAssertNotNil(response.headers["X-App-Frame"])
    XCTAssertNotNil(response.headers["X-App-Size"])
    XCTAssertEqual(Array(response.body.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
  }

  func testRecentCastArtifactReturnsLegacyJSONFailureWhenPersistenceIsMissing() throws {
    let (runtime, artifacts) = try makeRuntime("router-cast")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = try XCTUnwrap(
      router.artifact(ArtifactRequest(id: "cast.recent", params: ["seconds": "1"])))

    XCTAssertEqual(response.status, 400)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["error"] as? String, "transcript host is not wired (use --persistence-dir)")
  }

  func testLegacyNoBodyControlReturnsJSONFromRuntime() throws {
    let (runtime, artifacts) = try makeRuntime("router-persistence-flush")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.control(LegacyDebugControlInput(intentID: "persistence.flush"))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["ok"] as? Bool, true)
  }

  func testLegacyMalformedBodyControlDelegatesToRuntimeError() throws {
    let (runtime, artifacts) = try makeRuntime("router-find-malformed")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.control(
      LegacyDebugControlInput(intentID: "find.start", body: Data(#"{"needle":"apple""#.utf8)))

    XCTAssertEqual(response.status, 400)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["error"] as? String, "invalid find.start request")
  }

  func testLegacyDebugActionReturnsActionResultForTabAction() throws {
    let (runtime, artifacts) = try makeRuntime("router-new-tab")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let body = Data(#"{"action":"newTab"}"#.utf8)
    let response = router.route(
      .legacyDebugAction(LegacyDebugActionInput(intentID: "tab.new", action: "newTab", body: body)))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body0 = try json(response)
    XCTAssertEqual(body0["ok"] as? Bool, true)
    XCTAssertNotNil(body0["frame"])
    XCTAssertNil(body0["mouseTracking"])
    XCTAssertNil(body0["sent"])
  }

  func testLegacyDebugActionPreservesMouseActionResultWire() throws {
    let (runtime, artifacts) = try makeRuntime("router-mouse-wheel")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    // Enable SGR mouse tracking so the wheel takes the tracked-forward path that
    // returns MouseActionResult (mouseTracking + sent), mirroring the legacy
    // /debug/actions server.
    let enableBody = try JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": "\u{1B}[?1000h\u{1B}[?1006h"])
    _ = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "fixture.feedOutput", action: "feedOutput", body: enableBody)))

    let wheelBody = try JSONSerialization.data(
      withJSONObject: ["action": "mouseWheel", "x": 300, "y": 200, "deltaY": 3])
    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "terminal.mouseWheel", action: "mouseWheel", body: wheelBody)))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["ok"] as? Bool, true)
    XCTAssertEqual(body["mouseTracking"] as? Bool, true)
    XCTAssertEqual(body["sent"] as? Bool, true)
  }

  func testHeadlessRouterHandlesEverySharedOpNonError() throws {
    let (runtime, artifacts) = try makeRuntime("router-parity")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)
    let tabId = runtime.model.activeTab?.id ?? ""

    XCTAssertLessThan(router.query(.state).status, 400)

    let shared: [(intentID: String, action: String, body: Data)] = [
      ("tab.select", "selectTab", Data(#"{"action":"selectTab","tabId":"\#(tabId)"}"#.utf8)),
      ("terminal.typeText", "typeText", Data(#"{"action":"typeText","text":"parity"}"#.utf8)),
      ("terminal.sendKey", "key", Data(#"{"action":"key","key":"a"}"#.utf8)),
    ]
    for op in shared {
      let response = router.route(
        .legacyDebugAction(
          LegacyDebugActionInput(intentID: op.intentID, action: op.action, body: op.body)))
      XCTAssertLessThan(response.status, 400, op.intentID)
    }
  }

  // MARK: - Split panes 2

  /// Builds `A | (B / C)` and returns (A, B, C); focus ends on C.
  private func buildThreePanes(_ runtime: HeadlessDebugRuntime) throws -> (String, String, String) {
    let a = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    XCTAssertEqual(act(runtime, "pane.split", ["axis": "vertical"]).status, 200)
    let b = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    XCTAssertEqual(act(runtime, "pane.split", ["axis": "horizontal"]).status, 200)
    let c = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    return (a, b, c)
  }

  private func act(
    _ runtime: HeadlessDebugRuntime, _ action: String, _ payload: [String: Any] = [:]
  )
    -> DebugResponse
  {
    var body = payload
    body["action"] = action
    return runtime.applyAction(try! JSONSerialization.data(withJSONObject: body))
  }

  private func rootFraction(_ runtime: HeadlessDebugRuntime, path: PanePath = []) -> Double? {
    guard var node = runtime.model.activeTab?.panes else { return nil }
    for side in path {
      guard case .split(_, _, let first, let second) = node else { return nil }
      node = side == .first ? first : second
    }
    if case .split(_, let fraction, _, _) = node { return fraction }
    return nil
  }

  func testPaneResizeByPath() throws {
    let (runtime, artifacts) = try makeRuntime("router-pane-resize")
    defer {
      runtime.shutdown(terminateRemoteSessions: true)
      try? FileManager.default.removeItem(at: artifacts)
    }
    _ = try buildThreePanes(runtime)
    let rootBefore = try XCTUnwrap(rootFraction(runtime))

    let resized = act(runtime, "pane.resize", ["path": ["second"], "fraction": 0.7])
    XCTAssertEqual(resized.status, 200, String(decoding: resized.body, as: UTF8.self))
    XCTAssertEqual(try XCTUnwrap(rootFraction(runtime, path: [.second])), 0.7, accuracy: 0.02)
    XCTAssertEqual(try XCTUnwrap(rootFraction(runtime)), rootBefore, accuracy: 0.0001)

    // A leaf is not a split, and neither is a path that walks off the tree.
    let leaf = act(runtime, "pane.resize", ["path": ["first"], "fraction": 0.4])
    XCTAssertEqual(leaf.status, 400)
    XCTAssertTrue(String(decoding: leaf.body, as: UTF8.self).contains("notSplit"))
    XCTAssertEqual(act(runtime, "pane.resize", ["path": ["bogus"], "fraction": 0.4]).status, 400)
    XCTAssertEqual(act(runtime, "pane.resize", ["path": ["second"]]).status, 400)
    XCTAssertEqual(act(runtime, "pane.resize", [:]).status, 400)

    // Without a path the focused pane's divider on that side moves by two cells. The
    // focused pane (C, bottom right) is `second` of the horizontal split, so Up moves it.
    let before = try XCTUnwrap(rootFraction(runtime, path: [.second]))
    XCTAssertEqual(act(runtime, "pane.resize", ["direction": "up"]).status, 200)
    XCTAssertLessThan(try XCTUnwrap(rootFraction(runtime, path: [.second])), before)
  }

  func testPaneFocusByDirection() throws {
    let (runtime, artifacts) = try makeRuntime("router-pane-focus-direction")
    defer {
      runtime.shutdown(terminateRemoteSessions: true)
      try? FileManager.default.removeItem(at: artifacts)
    }
    let (a, b, c) = try buildThreePanes(runtime)
    func focused() -> String? { runtime.model.activeTab?.focusedSessionId }

    XCTAssertEqual(act(runtime, "pane.focus", ["direction": "left"]).status, 200)
    XCTAssertEqual(focused(), a)
    // Right returns to the most recently focused pane on that side.
    XCTAssertEqual(act(runtime, "pane.focus", ["direction": "right"]).status, 200)
    XCTAssertEqual(focused(), c)
    XCTAssertEqual(act(runtime, "pane.focus", ["direction": "up"]).status, 200)
    XCTAssertEqual(focused(), b)
    // At the edge the chord does nothing and still succeeds.
    XCTAssertEqual(act(runtime, "pane.focus", ["direction": "up"]).status, 200)
    XCTAssertEqual(focused(), b)
    XCTAssertEqual(act(runtime, "pane.focus", ["direction": "down"]).status, 200)
    XCTAssertEqual(focused(), c)
    // Cycling and unknown words keep their old behaviour.
    XCTAssertEqual(act(runtime, "pane.focus", ["direction": "next"]).status, 200)
    XCTAssertEqual(focused(), a)
    XCTAssertEqual(act(runtime, "pane.focus", ["direction": "sideways"]).status, 400)
  }

  func testPaneZoomToggle() throws {
    let (runtime, artifacts) = try makeRuntime("router-pane-zoom")
    defer {
      runtime.shutdown(terminateRemoteSessions: true)
      try? FileManager.default.removeItem(at: artifacts)
    }
    // One pane: zoom is a no-op.
    XCTAssertEqual(act(runtime, "pane.zoom").status, 200)
    XCTAssertNil(runtime.model.activeTab?.zoomedSessionId)

    let (_, _, c) = try buildThreePanes(runtime)
    XCTAssertEqual(act(runtime, "pane.zoom").status, 200)
    XCTAssertEqual(runtime.model.activeTab?.zoomedSessionId, c)
    let state = try tabState(runtime)
    XCTAssertEqual(state["zoomedSessionId"] as? String, c)

    XCTAssertEqual(act(runtime, "pane.zoom").status, 200)
    XCTAssertNil(runtime.model.activeTab?.zoomedSessionId)
    XCTAssertNil(try tabState(runtime)["zoomedSessionId"] as? String)

    XCTAssertEqual(act(runtime, "pane.zoom", ["zoomed": true]).status, 200)
    XCTAssertEqual(runtime.model.activeTab?.zoomedSessionId, c)
    XCTAssertEqual(act(runtime, "pane.zoom", ["zoomed": true]).status, 200)
    XCTAssertEqual(runtime.model.activeTab?.zoomedSessionId, c)
    XCTAssertEqual(act(runtime, "pane.zoom", ["zoomed": false]).status, 200)
    XCTAssertNil(runtime.model.activeTab?.zoomedSessionId)
  }

  func testPaneEqualize() throws {
    let (runtime, artifacts) = try makeRuntime("router-pane-equalize")
    defer {
      runtime.shutdown(terminateRemoteSessions: true)
      try? FileManager.default.removeItem(at: artifacts)
    }
    _ = try buildThreePanes(runtime)
    XCTAssertEqual(
      act(runtime, "pane.resize", ["path": [], "fraction": 0.3]).status, 200)
    XCTAssertEqual(
      act(runtime, "pane.resize", ["path": ["second"], "fraction": 0.7]).status, 200)
    XCTAssertEqual(try XCTUnwrap(rootFraction(runtime)), 0.3, accuracy: 0.02)

    XCTAssertEqual(act(runtime, "pane.equalize").status, 200)
    // `A | (B / C)`: the horizontal split counts as one column, so every fraction is half.
    XCTAssertEqual(try XCTUnwrap(rootFraction(runtime)), 0.5, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(rootFraction(runtime, path: [.second])), 0.5, accuracy: 0.0001)
  }

  func testPaneSplitTooSmallReturnsError() throws {
    let (runtime, artifacts) = try makeRuntime("router-pane-too-small")
    defer {
      runtime.shutdown(terminateRemoteSessions: true)
      try? FileManager.default.removeItem(at: artifacts)
    }
    var refusal: DebugResponse?
    for _ in 0..<40 {
      let response = act(runtime, "pane.split", ["axis": "horizontal"])
      if response.status != 200 {
        refusal = response
        break
      }
    }
    let response = try XCTUnwrap(refusal, "repeated splits must eventually be refused")
    XCTAssertEqual(response.status, 400)
    XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("tooSmall"))
    let count = try XCTUnwrap(runtime.model.activeTab?.allSessionIds.count)
    XCTAssertGreaterThan(count, 1)
    // A refusal leaves the layout alone.
    XCTAssertEqual(act(runtime, "pane.split", ["axis": "horizontal"]).status, 400)
    XCTAssertEqual(runtime.model.activeTab?.allSessionIds.count, count)
  }

  func testDividerGrabZoneAndDragCommitsOnce() throws {
    let (runtime, artifacts) = try makeRuntime("router-divider-drag")
    defer {
      runtime.shutdown(terminateRemoteSessions: true)
      try? FileManager.default.removeItem(at: artifacts)
    }
    let (a, _, _) = try buildThreePanes(runtime)
    let area = CGRect(
      x: runtime.sidebarWidth, y: 0, width: runtime.windowWidth - runtime.sidebarWidth,
      height: runtime.windowHeight)
    let divider = try XCTUnwrap(
      try XCTUnwrap(runtime.model.activeTab).visibleDividers(in: area).first { $0.path.isEmpty })
    let dividerX = Int(divider.rect.midX)
    // Near the top: below the middle the right half holds the second divider.
    let midY = 20

    XCTAssertNotNil(runtime.dividerHit(x: dividerX + 3, y: midY))
    XCTAssertNotNil(runtime.dividerHit(x: dividerX - 3, y: midY))
    XCTAssertNil(runtime.dividerHit(x: dividerX + 8, y: midY))

    // A plain click on the divider does nothing: no focus change, no tree change.
    let focusBefore = runtime.model.activeTab?.focusedSessionId
    let treeBefore = runtime.model.activeTab?.panes
    XCTAssertEqual(
      act(runtime, "click", ["x": dividerX, "y": midY, "button": "left"]).status, 200)
    XCTAssertEqual(runtime.model.activeTab?.focusedSessionId, focusBefore)
    XCTAssertEqual(runtime.model.activeTab?.panes, treeBefore)

    // Preview-then-commit: moving the proposal leaves the tree alone.
    XCTAssertTrue(runtime.beginDividerDrag(x: dividerX, y: midY))
    let third = area.minX + area.width / 3
    runtime.updateDividerDrag(x: Int(third), y: midY)
    XCTAssertEqual(runtime.model.activeTab?.panes, treeBefore)
    runtime.cancelDividerDrag()
    XCTAssertEqual(runtime.model.activeTab?.panes, treeBefore)

    // The mouseDrag action performs the same drag and commits once at the end point.
    let drag = act(
      runtime, "mouseDrag",
      ["startX": dividerX, "startY": midY, "endX": Int(third), "endY": midY])
    XCTAssertEqual(drag.status, 200, String(decoding: drag.body, as: UTF8.self))
    XCTAssertEqual(try XCTUnwrap(rootFraction(runtime)), 1.0 / 3.0, accuracy: 0.02)
    XCTAssertNil(runtime.dividerDrag)
    // The shell in the first pane never saw the press: the drag did not need mouse tracking.
    XCTAssertNotNil(runtime.model.session(forSessionID: a))
  }

  private func tabState(_ runtime: HeadlessDebugRuntime) throws -> [String: Any] {
    let response = runtime.state()
    XCTAssertEqual(response.status, 200)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let tabs = try XCTUnwrap(body["tabs"] as? [[String: Any]])
    return try XCTUnwrap(tabs.first { ($0["active"] as? Bool) == true })
  }

  private func makeRuntime(_ runId: String) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-headless-router-\(runId)-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: runId)
    return (runtime, artifacts)
  }

  private func json(_ response: ControlResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
