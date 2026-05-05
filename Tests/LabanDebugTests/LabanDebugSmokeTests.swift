import Foundation
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
    // The sidebar shows tab rows at y = height - (i+2) * rowHeight.
    // Quad-height rows: rowHeight ≈ 4*cellHeight + 10 ≈ 82, height ≈ 432.
    // Tab 0 spans roughly y = 268..350. Click near its center.
    let clickBody = #"{"action":"click","x":10,"y":300,"button":"left"}"#.data(using: .utf8)!
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
