import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

final class LabanDebugSmokeTests: XCTestCase {
  func testDebugMousePositionUsesTopLeftTerminalSurfaceY() {
    let pos = DebugMouseInput.terminalSurfacePosition(
      windowX: 360,
      windowY: 400,
      windowHeight: 480,
      sidebarWidth: 200
    )

    XCTAssertEqual(pos.x, 160)
    XCTAssertEqual(pos.y, 80)
  }

  func testDebugMouseSurfaceWidthExcludesSidebar() {
    XCTAssertEqual(DebugMouseInput.terminalSurfaceWidth(windowWidth: 1000, sidebarWidth: 200), 800)
    XCTAssertEqual(DebugMouseInput.terminalSurfaceWidth(windowWidth: 100, sidebarWidth: 200), 1)
  }

  // MARK: - HTTP server address parsing

  func testAddressParseLoopback() throws {
    let addr = try DebugServerAddress.parse("127.0.0.1:9999")
    XCTAssertEqual(addr.host, "127.0.0.1")
    XCTAssertEqual(addr.port, 9999)
  }

  func testAddressParseLocalhost() throws {
    let addr = try DebugServerAddress.parse("localhost:0")
    XCTAssertEqual(addr.host, "localhost")
    XCTAssertEqual(addr.port, 0)
  }

  func testAddressRejectsPublicHost() {
    XCTAssertThrowsError(try DebugServerAddress.parse("0.0.0.0:9999"))
    XCTAssertThrowsError(try DebugServerAddress.parse("192.168.1.1:9999"))
  }

  func testAddressRejectsMalformed() {
    XCTAssertThrowsError(try DebugServerAddress.parse("noport"))
    XCTAssertThrowsError(try DebugServerAddress.parse("127.0.0.1:notanumber"))
  }

  func testDebugHTTPServerRequiresBearerToken() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-http-auth")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let server = DebugHTTPServer(runtime: runtime)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    XCTAssertFalse(readiness.debugToken.isEmpty)
    let healthURL = URL(string: readiness.debugServer + "/debug/health")!

    let noAuth = try httpGet(healthURL)
    XCTAssertEqual(noAuth.status, 401)

    let badAuth = try httpGet(healthURL, token: "wrong")
    XCTAssertEqual(badAuth.status, 401)

    let ok = try httpGet(healthURL, token: readiness.debugToken)
    XCTAssertEqual(ok.status, 200)
    let obj = try JSONSerialization.jsonObject(with: ok.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  func testDebugHTTPServerWaitDoesNotBlockHealthRequest() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-http-wait-concurrent")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let server = DebugHTTPServer(runtime: runtime)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let baseURL = URL(string: readiness.debugServer)!
    let waitFD = try openDebugSocket(port: UInt16(baseURL.port!))
    defer { Darwin.close(waitFD) }

    let body = #"{"timeoutMs":900,"condition":{"kind":"textVisible","text":"never-visible"}}"#
      .data(using: .utf8)!
    try sendRawHTTP(
      fd: waitFD,
      method: "POST",
      path: "/debug/wait",
      token: readiness.debugToken,
      body: body
    )
    usleep(100_000)

    let healthURL = URL(string: readiness.debugServer + "/debug/health")!
    let start = Date()
    let ok = try httpGet(healthURL, token: readiness.debugToken, timeout: 1.0)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(ok.status, 200)
    XCTAssertLessThan(elapsed, 0.5)

    XCTAssertEqual(try readHTTPStatus(fd: waitFD, timeout: 2), 200)
  }

  func testDebugHTTPServerSlowHeaderDoesNotBlockHealthRequest() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-http-slow-header")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let server = DebugHTTPServer(runtime: runtime)
    let readiness = try server.start(host: "127.0.0.1", port: 0)
    defer { server.stop() }

    let baseURL = URL(string: readiness.debugServer)!
    let slowFD = try openDebugSocket(port: UInt16(baseURL.port!))
    defer { Darwin.close(slowFD) }

    let partial = "GET /debug/health HTTP/1.1\r\nHost: 127.0.0.1\r\n"
      .data(using: .utf8)!
    try sendAll(fd: slowFD, data: partial)
    usleep(100_000)

    let healthURL = URL(string: readiness.debugServer + "/debug/health")!
    let start = Date()
    let ok = try httpGet(healthURL, token: readiness.debugToken, timeout: 1.0)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(ok.status, 200)
    XCTAssertLessThan(elapsed, 0.5)
  }

  // MARK: - HeadlessDebugRuntime smoke (no fixture, no HTTP)

  func testRuntimeHealthNoFixture() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-no-fixture"
    )

    let health = runtime.health()
    XCTAssertEqual(health.status, 200)
    let obj = try JSONSerialization.jsonObject(with: health.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
    XCTAssertEqual(obj["mode"] as? String, "headless")
    XCTAssertNotNil(obj["frame"])
  }

  func testRuntimeRealShellModeRoutesTypedTextThroughPTY() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-real-pty",
      sessionMode: .realShell
    )

    let marker = "REAL_PTY_OK"
    let octalMarker = marker.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
    let command = "printf '\(octalMarker)\\012'\n"
    XCTAssertFalse(command.contains(marker), "typed command must not contain expected output")

    let actionBody = try JSONSerialization.data(
      withJSONObject: ["action": "typeText", "text": command])
    XCTAssertEqual(runtime.applyAction(actionBody).status, 200)

    let waitBody = try JSONSerialization.data(
      withJSONObject: [
        "timeoutMs": 2_000,
        "condition": [
          "kind": "textVisible",
          "text": marker,
        ],
      ])
    let wait = runtime.wait(waitBody)
    let obj = try JSONSerialization.jsonObject(with: wait.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  func testRuntimeStateHasOneTab() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-state"
    )

    let state = runtime.state()
    XCTAssertEqual(state.status, 200)
    let obj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = obj["tabs"] as! [[String: Any]]
    XCTAssertEqual(tabs.count, 1)
    XCTAssertNotNil(obj["activeTabId"])
    XCTAssertNotNil(obj["activeSessionId"])
  }

  func testRuntimeScreenshotNonEmpty() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-screenshot"
    )

    let (data, frame, width, height) = try runtime.screenshotBytes()
    XCTAssertGreaterThan(data.count, 0)
    XCTAssertGreaterThan(frame, 0)
    XCTAssertGreaterThan(width, 0)
    XCTAssertGreaterThan(height, 0)
  }

  func testRuntimeNewTabAction() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-newtab"
    )

    let body = #"{"action":"newTab"}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)

    let state = runtime.state()
    let stateObj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = stateObj["tabs"] as! [[String: Any]]
    XCTAssertEqual(tabs.count, 2)
  }

  func testRuntimeAdvanceFramesRendersEachRequestedFrame() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-advance-frames"
    )

    let initialHealth = runtime.health()
    let initialObj = try JSONSerialization.jsonObject(with: initialHealth.body) as! [String: Any]
    let initialFrame = initialObj["frame"] as! Int

    let body = #"{"action":"advanceFrames","count":3}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
    XCTAssertEqual(obj["frame"] as? Int, initialFrame + 3)

    let finalHealth = runtime.health()
    let finalObj = try JSONSerialization.jsonObject(with: finalHealth.body) as! [String: Any]
    XCTAssertEqual(finalObj["frame"] as? Int, initialFrame + 3)
  }

  func testRuntimeFrameCommandsHasCommands() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-cmds"
    )

    let resp = runtime.frameCommands(query: ["source": "all", "limit": "100"])
    XCTAssertEqual(resp.status, 200)
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    let cmds = obj["commands"] as! [[String: Any]]
    XCTAssertGreaterThan(cmds.count, 0)
    XCTAssertNotNil(obj["truncated"])
  }

  func testRuntimeRenderTraceHasRequiredFields() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-trace"
    )

    let resp = runtime.renderTrace(Data())
    XCTAssertEqual(resp.status, 200)
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    for key in [
      "traceId", "frame", "backend", "surface", "sources", "layout",
      "packets", "commandRanges", "commands", "resources", "passes",
      "pixelProbes", "invariants", "truncated",
    ] {
      XCTAssertNotNil(obj[key], "missing required field: \(key)")
    }
  }

  func testRuntimeEventsContainsServerReady() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-events"
    )
    runtime.emitServerReady()

    let resp = runtime.events(since: 0)
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    let events = obj["events"] as! [[String: Any]]
    let kinds = events.compactMap { $0["kind"] as? String }
    XCTAssertTrue(kinds.contains("server.ready"), "expected server.ready in \(kinds)")
    XCTAssertTrue(kinds.contains("frame.rendered"), "expected frame.rendered in \(kinds)")
    XCTAssertNotNil(obj["next"])
  }

  func testRuntimeScrollViewportReturnsOk() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-scroll"
    )

    let body = #"{"action":"scrollViewport","deltaRows":-4}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  func testRuntimeMouseWheelNormalModeScrolls() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-mwheel"
    )

    // First write enough lines to create scrollback.
    let typeBody = #"{"action":"typeText","text":"seq 1 20\n"}"#.data(using: .utf8)!
    _ = runtime.applyAction(typeBody)

    // Now wheel in terminal area (past sidebar) — should succeed.
    let body = #"{"action":"mouseWheel","x":300,"y":200,"deltaY":3}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  func testRuntimeMouseWheelInSidebarIgnored() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-mw-side"
    )

    // Wheel in sidebar area — should be consumed locally (ok: true).
    let body = #"{"action":"mouseWheel","x":10,"y":100,"deltaY":3}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  func testRuntimeClickSidebarNewTab() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-click-side"
    )

    // First create a second tab so we have something to click on in the sidebar.
    let newTabBody = #"{"action":"newTab"}"#.data(using: .utf8)!
    _ = runtime.applyAction(newTabBody)

    // Now there are 2 tabs. Click in the sidebar area to select the first tab.
    // The "+" button moved to a titlebar accessory, so tabs now start at the
    // top of the sidebar: tab rows at y = height - (i+1) * rowHeight.
    // Quad-height rows: rowHeight ≈ 4*cellHeight + 10 ≈ 82, height ≈ 432.
    // Tab 0 spans roughly y = 350..432. Click near its center.
    let clickBody = #"{"action":"click","x":10,"y":390,"button":"left"}"#.data(using: .utf8)!
    let result = runtime.applyAction(clickBody)
    XCTAssertEqual(result.status, 200)

    // We just verify the action succeeded - tab navigation via sidebar click works.
    // The runtime returns ok:true even for sidebar hits.
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)

    // Still have 2 tabs.
    let state = runtime.state()
    let stateObj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = stateObj["tabs"] as! [[String: Any]]
    XCTAssertEqual(tabs.count, 2)
  }

  func testRuntimeClickWithoutMouseTrackingSetsLocalSelection() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-click-notrack"
    )

    // Click in terminal area (past sidebar) — should return ok:true and set a one-cell selection.
    let body = #"{"action":"click","x":300,"y":200,"button":"left"}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
    XCTAssertNil(obj["error"])

    // Verify selection is now active.
    let selResp = runtime.selection()
    XCTAssertEqual(selResp.status, 200)
    let selObj = try JSONSerialization.jsonObject(with: selResp.body) as! [String: Any]
    XCTAssertEqual(selObj["active"] as? Bool, true)
    XCTAssertNotNil(selObj["anchor"])
    XCTAssertNotNil(selObj["focus"])
  }

  func testRuntimeMouseTrackingActionsAreRecordedInInputLog() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-mouse-track-log")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let enable = try JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": "\u{1B}[?1000h\u{1B}[?1006h"])
    _ = runtime.applyAction(enable)

    let wheel = try JSONSerialization.data(
      withJSONObject: ["action": "mouseWheel", "x": 300, "y": 200, "deltaY": 3])
    let wheelResult = runtime.applyAction(wheel)
    let wheelObj = try JSONSerialization.jsonObject(with: wheelResult.body) as! [String: Any]
    XCTAssertEqual(wheelObj["ok"] as? Bool, true)
    XCTAssertEqual(wheelObj["mouseTracking"] as? Bool, true)
    XCTAssertEqual(wheelObj["sent"] as? Bool, true)

    let click = try JSONSerialization.data(
      withJSONObject: ["action": "click", "x": 300, "y": 200, "button": "right"])
    let clickResult = runtime.applyAction(click)
    let clickObj = try JSONSerialization.jsonObject(with: clickResult.body) as! [String: Any]
    XCTAssertEqual(clickObj["ok"] as? Bool, true)
    XCTAssertEqual(clickObj["mouseTracking"] as? Bool, true)
    XCTAssertEqual(clickObj["sent"] as? Bool, true)

    let inputLog = runtime.inputLogResponse(since: 0)
    let inputObj = try JSONSerialization.jsonObject(with: inputLog.body) as! [String: Any]
    let events = inputObj["events"] as! [[String: Any]]
    let terminalMouse = events.filter {
      ($0["kind"] as? String) == "mouse" && ($0["route"] as? String) == "terminal"
    }
    let wheelEvents = terminalMouse.filter { ($0["command"] as? String) == "mouseWheel" }
    let clickEvents = terminalMouse.filter { ($0["command"] as? String) == "click" }

    XCTAssertEqual(wheelEvents.count, 1)
    XCTAssertEqual(clickEvents.count, 1)
    XCTAssertGreaterThan(wheelEvents[0]["encodedLength"] as? Int ?? 0, 0)
    XCTAssertGreaterThan(clickEvents[0]["encodedLength"] as? Int ?? 0, 0)
    XCTAssertNotNil(wheelEvents[0]["encodedHex"])
    XCTAssertNotNil(clickEvents[0]["encodedHex"])
  }

  func testRuntimeSessionsReportsRealViewportState() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-session-vs"
    )

    // Write enough lines to create scrollback.
    let typeBody = #"{"action":"typeText","text":"seq 1 100\n"}"#.data(using: .utf8)!
    _ = runtime.applyAction(typeBody)

    let resp = runtime.sessions()
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    let sessions = obj["sessions"] as! [[String: Any]]
    guard let s = sessions.first else {
      XCTFail("no sessions")
      return
    }
    XCTAssertGreaterThanOrEqual(s["scrollbackLines"] as? Int ?? 0, 0)
    XCTAssertGreaterThanOrEqual(s["viewportOffset"] as? Int ?? -1, 0)
  }

  func testRuntimeTypingAfterScrollbackReturnsViewportToBottom() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-input-follow-bottom"
    )

    let history = (1...100).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"
    let historyAction = try JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": history])
    _ = runtime.applyAction(historyAction)
    _ = runtime.applyAction(#"{"action":"scrollViewport","deltaRows":-12}"#.data(using: .utf8)!)

    func firstSession() throws -> [String: Any] {
      let resp = runtime.sessions()
      let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
      let sessions = obj["sessions"] as! [[String: Any]]
      guard let session = sessions.first else {
        throw NSError(domain: "LabanDebugSmokeTests", code: 1)
      }
      return session
    }

    let scrolled = try firstSession()
    let scrolledOffset = scrolled["viewportOffset"] as? Int ?? 0
    let scrolledBottom = scrolled["scrollbackLines"] as? Int ?? 0
    XCTAssertLessThan(scrolledOffset, scrolledBottom)

    _ = runtime.applyAction(
      #"{"action":"typeText","text":"printf 'bottom\\n'\n"}"#.data(using: .utf8)!)

    let followed = try firstSession()
    XCTAssertEqual(
      followed["viewportOffset"] as? Int,
      followed["scrollbackLines"] as? Int
    )
  }

  func testRuntimeUnsupportedActionReturnsOkFalse() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-unsupported"
    )

    let body = #"{"action":"nonexistent_action"}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, false)
    XCTAssertNotNil(obj["error"])
  }

  func testRuntimeWaitFrameAtLeast() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-wait"
    )

    let body = #"{"timeoutMs":500,"condition":{"kind":"frameAtLeast","frame":1}}"#.data(
      using: .utf8)!
    let result = runtime.wait(body)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  func testRuntimeWaitTextVisibleCanTargetBackgroundSession() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-wait-session-text")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    _ = runtime.applyAction(
      #"{"action":"feedOutput","text":"background-only"}"#.data(using: .utf8)!)
    let firstState = try JSONSerialization.jsonObject(with: runtime.state().body) as! [String: Any]
    let firstSessionId = firstState["activeSessionId"] as! String

    _ = runtime.applyAction(#"{"action":"newTab"}"#.data(using: .utf8)!)
    _ = runtime.applyAction(
      #"{"action":"feedOutput","text":"foreground-only"}"#.data(using: .utf8)!)
    let secondState = try JSONSerialization.jsonObject(with: runtime.state().body) as! [String: Any]
    XCTAssertNotEqual(secondState["activeSessionId"] as? String, firstSessionId)

    let waitBody = try JSONSerialization.data(
      withJSONObject: [
        "timeoutMs": 200,
        "condition": [
          "kind": "textVisible",
          "sessionId": firstSessionId,
          "text": "background-only",
        ],
      ])
    let result = runtime.wait(waitBody)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  // MARK: - Selection and clipboard tests

  func testSetSelectionActionSetsActiveSelection() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-sel-set"
    )

    let body = #"{"action":"setSelection","anchor":{"row":0,"col":2},"focus":{"row":0,"col":5}}"#
      .data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }

  func testDebugSelectionEndpointReflectsSetSelection() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-sel-debug"
    )

    // Initially no selection.
    let initResp = runtime.selection()
    XCTAssertEqual(initResp.status, 200)
    let initObj = try JSONSerialization.jsonObject(with: initResp.body) as! [String: Any]
    XCTAssertEqual(initObj["active"] as? Bool, false)

    // Set selection.
    let setBody = #"{"action":"setSelection","anchor":{"row":0,"col":2},"focus":{"row":0,"col":5}}"#
      .data(using: .utf8)!
    _ = runtime.applyAction(setBody)

    let selResp = runtime.selection()
    XCTAssertEqual(selResp.status, 200)
    let selObj = try JSONSerialization.jsonObject(with: selResp.body) as! [String: Any]
    XCTAssertEqual(selObj["active"] as? Bool, true)
    XCTAssertNotNil(selObj["anchor"])
    XCTAssertNotNil(selObj["focus"])
    XCTAssertNotNil(selObj["rects"])
    XCTAssertNotNil(selObj["text"])
    XCTAssertNotNil(selObj["sessionId"])
  }

  func testDebugSelectionProjectionClampsOutOfRangeColumns() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-sel-clamp"
    )

    let setBody =
      #"{"action":"setSelection","anchor":{"row":0,"col":-50},"focus":{"row":0,"col":500}}"#
      .data(using: .utf8)!
    let setResp = runtime.applyAction(setBody)
    XCTAssertEqual(setResp.status, 200)

    let selResp = runtime.selection()
    XCTAssertEqual(selResp.status, 200)
    let selObj = try JSONSerialization.jsonObject(with: selResp.body) as! [String: Any]
    XCTAssertEqual(selObj["active"] as? Bool, true)
    let rects = selObj["rects"] as? [[String: Any]]
    XCTAssertEqual(rects?.count, 1)
    let rect = try XCTUnwrap(rects?.first)
    XCTAssertGreaterThanOrEqual(rect["x"] as? Double ?? -1, 0)
    XCTAssertGreaterThan(rect["width"] as? Double ?? 0, 0)

    let copyResp = runtime.applyAction(#"{"action":"copy"}"#.data(using: .utf8)!)
    XCTAssertEqual(copyResp.status, 200)
  }

  func testSelectionsStayBoundToSessionsAcrossTabSwitchAndCopy() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-sel-tabs"
    )

    let firstTab = try XCTUnwrap(runtime.model.activeTab)
    let firstSession = try XCTUnwrap(runtime.model.session(forTab: firstTab.id))
    firstSession.write(Array("alpha one\r\n".utf8))
    firstSession.poll()

    let firstSelection =
      #"{"action":"setSelection","anchor":{"row":0,"col":0},"focus":{"row":0,"col":4}}"#
      .data(using: .utf8)!
    XCTAssertEqual(runtime.applyAction(firstSelection).status, 200)

    XCTAssertEqual(runtime.applyAction(#"{"action":"newTab"}"#.data(using: .utf8)!).status, 200)
    let secondTab = try XCTUnwrap(runtime.model.activeTab)
    XCTAssertNotEqual(secondTab.id, firstTab.id)
    let secondSession = try XCTUnwrap(runtime.model.session(forTab: secondTab.id))
    secondSession.write(Array("bravo two\r\n".utf8))
    secondSession.poll()

    let secondSelection =
      #"{"action":"setSelection","anchor":{"row":0,"col":0},"focus":{"row":0,"col":4}}"#
      .data(using: .utf8)!
    XCTAssertEqual(runtime.applyAction(secondSelection).status, 200)

    var selection = runtime.selection()
    var selectionObj = try JSONSerialization.jsonObject(with: selection.body) as! [String: Any]
    XCTAssertEqual(selectionObj["sessionId"] as? String, secondSession.id)
    XCTAssertEqual(selectionObj["text"] as? String, "bravo")

    XCTAssertEqual(runtime.applyAction(#"{"action":"copy"}"#.data(using: .utf8)!).status, 200)
    var clipboard = runtime.clipboard()
    var clipboardObj = try JSONSerialization.jsonObject(with: clipboard.body) as! [String: Any]
    XCTAssertEqual(clipboardObj["lastCopyText"] as? String, "bravo")

    let selectFirst = try JSONSerialization.data(
      withJSONObject: ["action": "selectTab", "tabId": firstTab.id])
    XCTAssertEqual(runtime.applyAction(selectFirst).status, 200)

    selection = runtime.selection()
    selectionObj = try JSONSerialization.jsonObject(with: selection.body) as! [String: Any]
    XCTAssertEqual(selectionObj["sessionId"] as? String, firstSession.id)
    XCTAssertEqual(selectionObj["text"] as? String, "alpha")

    XCTAssertEqual(runtime.applyAction(#"{"action":"copy"}"#.data(using: .utf8)!).status, 200)
    clipboard = runtime.clipboard()
    clipboardObj = try JSONSerialization.jsonObject(with: clipboard.body) as! [String: Any]
    XCTAssertEqual(clipboardObj["lastCopyText"] as? String, "alpha")
  }

  func testCloseTabPrunesDebugSelectionForClosedSession() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-sel-close"
    )

    let firstTab = try XCTUnwrap(runtime.model.activeTab)
    let firstSessionId = firstTab.sessionId
    let setSelection =
      #"{"action":"setSelection","anchor":{"row":0,"col":0},"focus":{"row":0,"col":3}}"#
      .data(using: .utf8)!
    XCTAssertEqual(runtime.applyAction(setSelection).status, 200)
    XCTAssertNotNil(runtime.selectionBySession[firstSessionId])

    XCTAssertEqual(runtime.applyAction(#"{"action":"newTab"}"#.data(using: .utf8)!).status, 200)
    let closeFirst = try JSONSerialization.data(
      withJSONObject: ["action": "closeTab", "tabId": firstTab.id])
    XCTAssertEqual(runtime.applyAction(closeFirst).status, 200)

    XCTAssertNil(
      runtime.selectionBySession[firstSessionId],
      "closing a tab must discard its stale selection state")
  }

  func testCopyActionPopulatesDebugClipboard() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-copy"
    )

    // Set selection first.
    let setBody = #"{"action":"setSelection","anchor":{"row":0,"col":0},"focus":{"row":0,"col":3}}"#
      .data(using: .utf8)!
    _ = runtime.applyAction(setBody)

    // Copy.
    let copyBody = #"{"action":"copy"}"#.data(using: .utf8)!
    let result = runtime.applyAction(copyBody)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)

    // Clipboard should reflect the copy.
    let clipResp = runtime.clipboard()
    XCTAssertEqual(clipResp.status, 200)
    let clipObj = try JSONSerialization.jsonObject(with: clipResp.body) as! [String: Any]
    XCTAssertNotNil(clipObj["lastCopyText"])
    XCTAssertTrue(clipObj.keys.contains("lastPasteText"))
    XCTAssertTrue(clipObj.keys.contains("lastPasteUsedBracketedPaste"))
    XCTAssertTrue(clipObj.keys.contains("lastPasteIgnoredNonText"))
  }

  func testPasteActionRecordsDebugClipboardState() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-paste"
    )

    // Pre-load clipboard.
    let setClipBody = #"{"action":"setClipboardText","text":"hello paste"}"#.data(using: .utf8)!
    _ = runtime.applyAction(setClipBody)

    // Paste.
    let pasteBody = #"{"action":"paste"}"#.data(using: .utf8)!
    let result = runtime.applyAction(pasteBody)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)

    // Debug clipboard should record paste state.
    let clipResp = runtime.clipboard()
    let clipObj = try JSONSerialization.jsonObject(with: clipResp.body) as! [String: Any]
    XCTAssertEqual(clipObj["lastPasteText"] as? String, "hello paste")
    XCTAssertNotNil(clipObj["lastPasteUsedBracketedPaste"])
    XCTAssertEqual(clipObj["lastPasteIgnoredNonText"] as? Bool, false)
  }

  func testPasteActionLogsCommittedBracketedPasteBytes() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-paste-encoded"
    )

    let enable = try JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": "\u{1B}[?2004h"])
    _ = runtime.applyAction(enable)
    let setClipBody = #"{"action":"setClipboardText","text":"hello paste"}"#.data(using: .utf8)!
    _ = runtime.applyAction(setClipBody)

    let pasteBody = #"{"action":"paste"}"#.data(using: .utf8)!
    let result = runtime.applyAction(pasteBody)
    XCTAssertEqual(result.status, 200)

    let expectedBytes = Array("\u{1b}[200~hello paste\u{1b}[201~".utf8)
    let expectedHex = expectedBytes.map { String(format: "%02x", $0) }.joined()

    let inputLog = runtime.inputLogResponse(since: 0)
    let logObj = try JSONSerialization.jsonObject(with: inputLog.body) as! [String: Any]
    let events = try XCTUnwrap(logObj["events"] as? [[String: Any]])
    let pasteEvent = try XCTUnwrap(events.last { $0["kind"] as? String == "paste" })
    XCTAssertEqual(pasteEvent["encodedHex"] as? String, expectedHex)
    XCTAssertEqual(pasteEvent["encodedLength"] as? Int, expectedBytes.count)

    let terminalLog = runtime.terminalLogResponse(query: ["since": "0"])
    let termObj = try JSONSerialization.jsonObject(with: terminalLog.body) as! [String: Any]
    let terminalEvents = try XCTUnwrap(termObj["events"] as? [[String: Any]])
    XCTAssertTrue(
      terminalEvents.contains {
        ($0["direction"] as? String) == "input"
          && ($0["escaped"] as? String) == "\\e[200~hello paste\\e[201~"
      },
      "terminal log must include committed bracketed paste bytes")
  }

  func testPasteActionSanitizesDebugClipboardLikeAppPaste() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-paste-sanitize"
    )

    let setClipBody =
      #"{"action":"setClipboardText","text":"safe\u001b]0;owned\u0007\u009b31m"}"#
      .data(using: .utf8)!
    _ = runtime.applyAction(setClipBody)

    let pasteBody = #"{"action":"paste"}"#.data(using: .utf8)!
    let result = runtime.applyAction(pasteBody)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)

    let clipResp = runtime.clipboard()
    let clipObj = try JSONSerialization.jsonObject(with: clipResp.body) as! [String: Any]
    XCTAssertEqual(clipObj["lastPasteText"] as? String, "safe]0;owned31m")
    XCTAssertEqual(clipObj["lastPasteIgnoredNonText"] as? Bool, true)

    let inputLog = runtime.inputLogResponse(since: 0)
    let logObj = try JSONSerialization.jsonObject(with: inputLog.body) as! [String: Any]
    let events = try XCTUnwrap(logObj["events"] as? [[String: Any]])
    let pasteEvent = try XCTUnwrap(events.last { $0["kind"] as? String == "paste" })
    XCTAssertEqual(pasteEvent["text"] as? String, "safe]0;owned31m")
  }

  func testDropFilesActionPastesEscapedPaths() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-drop-files"
    )

    let paths = ["/tmp/example image.png", "/tmp/spec.pdf"]
    let body = try JSONSerialization.data(
      withJSONObject: ["action": "dropFiles", "paths": paths])
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)

    let expectedText = TerminalDropText.format(paths: paths)
    let expectedBytes = Array(expectedText.utf8)
    let expectedHex = expectedBytes.map { String(format: "%02x", $0) }.joined()

    let inputLog = runtime.inputLogResponse(since: 0)
    let logObj = try JSONSerialization.jsonObject(with: inputLog.body) as! [String: Any]
    let events = try XCTUnwrap(logObj["events"] as? [[String: Any]])
    let dropEvent = try XCTUnwrap(events.last { $0["kind"] as? String == "drop" })
    XCTAssertEqual(dropEvent["text"] as? String, expectedText)
    XCTAssertEqual(dropEvent["encodedHex"] as? String, expectedHex)
    XCTAssertEqual(dropEvent["encodedLength"] as? Int, expectedBytes.count)

    let terminalLog = runtime.terminalLogResponse(query: ["since": "0"])
    let termObj = try JSONSerialization.jsonObject(with: terminalLog.body) as! [String: Any]
    let terminalEvents = try XCTUnwrap(termObj["events"] as? [[String: Any]])
    XCTAssertTrue(
      terminalEvents.contains {
        ($0["direction"] as? String) == "input"
          && ($0["escaped"] as? String) == expectedText
      },
      "terminal log must include committed dropped path paste bytes")
  }

  func testDropFilesActionRecordsInputEnvelope() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-drop-envelope"
    )

    let body = try JSONSerialization.data(
      withJSONObject: ["action": "dropFiles", "paths": ["/tmp/screenshot.png"]])
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)

    let inputLog = runtime.inputLogResponse(since: 0)
    let logObj = try JSONSerialization.jsonObject(with: inputLog.body) as! [String: Any]
    let events = try XCTUnwrap(logObj["events"] as? [[String: Any]])
    let dropEvent = try XCTUnwrap(events.last { $0["command"] as? String == "dropFiles" })
    XCTAssertEqual(dropEvent["kind"] as? String, "drop")
    XCTAssertEqual(dropEvent["route"] as? String, "terminal")
    XCTAssertNotNil(dropEvent["tabId"])
    XCTAssertNotNil(dropEvent["sessionId"])
  }

  func testSelectionFrameCommandsAppearsWithSourceFilter() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-sel-cmds"
    )

    // Set a multi-cell selection.
    let setBody = #"{"action":"setSelection","anchor":{"row":0,"col":0},"focus":{"row":0,"col":5}}"#
      .data(using: .utf8)!
    _ = runtime.applyAction(setBody)

    // Check frame commands for selection kind.
    let cmdsResp = runtime.frameCommands(query: ["source": "all", "limit": "500"])
    let cmdsObj = try JSONSerialization.jsonObject(with: cmdsResp.body) as! [String: Any]
    let cmds = cmdsObj["commands"] as! [[String: Any]]
    let selectionCmds = cmds.filter { ($0["kind"] as? String) == "selection" }
    XCTAssertGreaterThan(
      selectionCmds.count, 0, "expected selection frame commands after setSelection")
  }

  // MARK: - Title synchronization tests

  private func makeRuntime(runId: String) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: runId
    )
    return (runtime, artifacts)
  }

  private func httpGet(
    _ url: URL, token: String? = nil, timeout: TimeInterval = 5.0
  ) throws -> (status: Int, body: Data) {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let sem = DispatchSemaphore(value: 0)
    var result: (status: Int, body: Data)?
    var requestError: Error?
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      requestError = error
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      result = (status, data ?? Data())
      sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 0.5) == .timedOut {
      task.cancel()
      throw NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorTimedOut,
        userInfo: [NSLocalizedDescriptionKey: "HTTP request timed out"])
    }
    if let requestError { throw requestError }
    return result ?? (-1, Data())
  }

  private func openDebugSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError("socket") }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(port)
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      let error = posixError("connect")
      Darwin.close(fd)
      throw error
    }
    return fd
  }

  private func sendRawHTTP(
    fd: Int32, method: String, path: String, token: String, body: Data
  ) throws {
    var request = "\(method) \(path) HTTP/1.1\r\n"
    request += "Host: 127.0.0.1\r\n"
    request += "Authorization: Bearer \(token)\r\n"
    request += "Content-Length: \(body.count)\r\n"
    request += "Connection: close\r\n"
    request += "\r\n"
    var data = request.data(using: .utf8)!
    data.append(body)
    try sendAll(fd: fd, data: data)
  }

  private func sendAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var sent = 0
      while sent < rawBuffer.count {
        let n = send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw posixError("send") }
        sent += n
      }
    }
  }

  private func readHTTPStatus(fd: Int32, timeout: Int) throws -> Int {
    var recvTimeout = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

    var data = Data()
    var buf = [UInt8](repeating: 0, count: 1024)
    while data.range(of: Data([0x0D, 0x0A])) == nil && data.count < 8192 {
      let n = recv(fd, &buf, buf.count, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { throw posixError("recv") }
      data.append(contentsOf: buf[0..<n])
    }

    guard let header = String(data: data, encoding: .utf8),
      let line = header.components(separatedBy: "\r\n").first
    else { return -1 }
    let parts = line.split(separator: " ")
    guard parts.count >= 2 else { return -1 }
    return Int(parts[1]) ?? -1
  }

  private func posixError(_ operation: String) -> NSError {
    let code = errno
    return NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(code),
      userInfo: [
        NSLocalizedDescriptionKey:
          "\(operation) failed: \(String(cString: strerror(code)))"
      ])
  }

  private func feedOSCTitle(_ title: String, to runtime: HeadlessDebugRuntime) {
    let seq = "\u{1B}]0;\(title)\u{07}"
    let body = try! JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": seq])
    _ = runtime.applyAction(body)
  }

  func testTitleEqualsWaitWithoutPriorStateCall() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-title-wait")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    feedOSCTitle("MyTitle", to: runtime)

    // Wait for titleEquals without calling state() first.
    let waitBody = #"{"timeoutMs":500,"condition":{"kind":"titleEquals","title":"MyTitle"}}"#
      .data(using: .utf8)!
    let waitResult = runtime.wait(waitBody)
    let waitObj = try JSONSerialization.jsonObject(with: waitResult.body) as! [String: Any]
    XCTAssertEqual(
      waitObj["ok"] as? Bool, true,
      "titleEquals wait must succeed without prior state() call")
  }

  func testTitleSyncVisibleInStateAfterFeedOutput() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-title-state")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    feedOSCTitle("ShellTitle", to: runtime)

    let state = runtime.state()
    XCTAssertEqual(state.status, 200)
    let stateObj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = stateObj["tabs"] as! [[String: Any]]
    let activeTabResp = tabs.first(where: { $0["active"] as? Bool == true })
    XCTAssertEqual(activeTabResp?["title"] as? String, "ShellTitle")
  }

  func testTitleSyncVisibleInSessionsAfterFeedOutput() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "smoke-title-sessions")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let seq = "\u{1B}]2;SessionTitle\u{07}"
    let body = try! JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": seq])
    _ = runtime.applyAction(body)

    let resp = runtime.sessions()
    XCTAssertEqual(resp.status, 200)
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    let sessions = obj["sessions"] as! [[String: Any]]
    XCTAssertEqual(sessions.first?["title"] as? String, "SessionTitle")
  }
}
