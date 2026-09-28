import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore
@testable import LabanDebug

class SplitPaneTestCase: XCTestCase {
  var runtime: HeadlessDebugRuntime!
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ".artifacts/split-panes/tests-\(UUID().uuidString)")
    runtime = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: root, tempURL: nil,
      deterministic: true, runId: "split-test", sessionMode: .realShell,
      persistenceBaseURL: root.appendingPathComponent("persist"), restorePersistedState: false)
  }
  override func tearDown() {
    runtime?.shutdown(terminateRemoteSessions: true)
    runtime = nil
  }
  @discardableResult
  func action(_ name: String, _ payload: [String: Any] = [:]) throws -> DebugResponse {
    var body = payload
    body["action"] = name
    let response = runtime.applyAction(try JSONSerialization.data(withJSONObject: body))
    XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
    return response
  }
  func split() throws -> (String, String) {
    let left = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    try action("pane.split")
    let right = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    XCTAssertNotEqual(left, right)
    return (left, right)
  }
  func printText(_ text: String, in id: String) throws {
    try action("typeText", ["sessionId": id, "text": "printf '\(text)\\n'\n"])
    try waitText(text, in: id)
  }
  func waitText(_ text: String, in id: String) throws {
    let response = runtime.wait(
      try JSONSerialization.data(withJSONObject: [
        "timeoutMs": 5000, "condition": ["kind": "textVisible", "sessionId": id, "text": text],
      ]))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertEqual(body["ok"] as? Bool, true, String(decoding: response.body, as: UTF8.self))
    runtime.renderFrameUnlocked()
  }
  func visible(_ id: String) throws -> String {
    let session = try XCTUnwrap(runtime.model.session(forSessionID: id))
    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }
    return TerminalSnapshotText.visibleText(from: UnsafePointer(snap), mode: .trimmedNonEmptyRows)
  }
}

final class SplitPaneHeadlessTests: SplitPaneTestCase {
  func testTwoPanesRenderAtDistinctOrigins() throws {
    let (left, right) = try split()
    try printText("LEFT", in: left)
    try printText("RIGHT", in: right)
    let boundary =
      CGFloat(runtime.sidebarWidth) + CGFloat(runtime.windowWidth - runtime.sidebarWidth) / 2
    var leftOrigins: [CGFloat] = []
    var rightOrigins: [CGFloat] = []
    var dividers = 0
    for command in runtime.lastFrameCommands {
      switch command {
      case .glyphRun(let origin, let text, _, _, _, let source, _, _, _, _, _, _, _)
      where source == .terminal:
        if text.contains("LEFT") { leftOrigins.append(origin.x) }
        if text.contains("RIGHT") { rightOrigins.append(origin.x) }
      case .rect(let rect, _, let source, _)
      where source == .terminal && rect.width == 1 && rect.height == CGFloat(runtime.windowHeight):
        dividers += 1
      default: break
      }
    }
    XCTAssertFalse(leftOrigins.isEmpty)
    XCTAssertFalse(rightOrigins.isEmpty)
    XCTAssertTrue(leftOrigins.allSatisfy { $0 < boundary })
    XCTAssertTrue(rightOrigins.allSatisfy { $0 > boundary })
    XCTAssertEqual(dividers, 1)
    XCTAssertFalse(try visible(left).contains("RIGHT"))
    XCTAssertFalse(try visible(right).contains("LEFT"))
  }

  func testOutputInUnfocusedPaneMarksFrameDirty() throws {
    let (left, right) = try split()
    runtime.renderFrameUnlocked()
    let session = try XCTUnwrap(runtime.model.session(forSessionID: left))
    session.feedOutput(Array("UNFOCUSED-OUTPUT".utf8))
    let result = runtime.surfaceController.syncSessions(
      captureFrame: 1, polling: .none,
      markInactiveDirtyRendered: false, noteOutputOnDirty: true)
    XCTAssertTrue(result.activeTerminalDirty)
    let deferred = runtime.surfaceController.syncSessions(
      captureFrame: 2, polling: .none,
      markInactiveDirtyRendered: false, noteOutputOnDirty: true)
    XCTAssertTrue(
      deferred.activeTerminalDirty, "unpainted visible output must survive a deferred frame")
    XCTAssertEqual(runtime.model.activeTab?.focusedSessionId, right)
    runtime.renderFrameUnlocked()
    XCTAssertTrue(try visible(left).contains("UNFOCUSED-OUTPUT"))
  }

  func testBothPanesWriteTranscripts() throws {
    let (left, right) = try split()
    try printText("LEFT-TRANSCRIPT", in: left)
    try printText("RIGHT-TRANSCRIPT", in: right)
    runtime.transcriptHost?.flushAll()
    for id in [left, right] {
      let url = try XCTUnwrap(runtime.transcriptHost?.transcriptURL(forSessionId: id))
      XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
    }
  }

  func testUnfocusedCursorIsHollow() throws {
    _ = try split()
    let cursors = runtime.lastFrameCommands.compactMap { command -> CGRect? in
      if case .cursor(let rect, _) = command { return rect }
      return nil
    }
    XCTAssertGreaterThanOrEqual(cursors.count, 5, "four outline edges and the focused cursor")
  }

  func testClickFocusAndPaneLocalMouseCoordinates() throws {
    let (left, _) = try split()
    try action("click", ["x": runtime.sidebarWidth + 20, "y": 20, "button": "left"])
    XCTAssertEqual(runtime.model.activeTab?.focusedSessionId, left)
  }
}

final class SurvivorPaneTests: SplitPaneTestCase {
  func survivor() throws -> String {
    let (left, right) = try split()
    try action("pane.close", ["sessionId": left])
    XCTAssertEqual(runtime.model.activeTab?.allSessionIds, [right])
    XCTAssertNotEqual(runtime.model.activeTab?.id, right)
    return right
  }
  func testTypingAfterFirstPaneClosed() throws { try printText("SURVIVOR", in: survivor()) }
  func testResizeAfterFirstPaneClosed() throws {
    let id = try survivor()
    try action("resizeWindow", ["width": 1100, "height": 700])
    XCTAssertGreaterThan(runtime.model.terminalSize(for: id).cols, 50)
  }
  func testCastEndpointAfterFirstPaneClosed() throws {
    let id = try survivor()
    try printText("CAST", in: id)
    if case .failure(_, let message) = runtime.recentCastBytes(seconds: 10, tabId: nil) {
      XCTFail(message)
    }
  }
  func testTranscriptAfterFirstPaneClosed() throws {
    let id = try survivor()
    try printText("TRANSCRIPT", in: id)
    runtime.transcriptHost?.flushAll()
    XCTAssertGreaterThan(
      try Data(contentsOf: XCTUnwrap(runtime.transcriptHost?.transcriptURL(forSessionId: id)))
        .count, 0)
  }
  func testFindAfterFirstPaneClosed() throws {
    let id = try survivor()
    try printText("FINDME", in: id)
    XCTAssertFalse(
      try XCTUnwrap(runtime.model.startFind(sessionID: id, needle: "FINDME")).matches.isEmpty)
  }
  func testRestoreAfterFirstPaneClosed() throws {
    let id = try survivor()
    XCTAssertEqual(runtime.persistenceRelaunch().status, 200)
    XCTAssertEqual(runtime.model.activeTab?.allSessionIds, [id])
    try printText("RESTORED", in: id)
  }
  func testAgentDetectionAfterFirstPaneClosed() throws {
    let id = try survivor()
    let detector = AgentSessionDetector(
      tabId: id, shellPid: 100, introspector: SurvivorAgentProcesses())
    let agent = try XCTUnwrap(detector.detectLiveAgentDescendant())
    let mirror = SurvivorMirror()
    let observer = AgentObserverHost(appModel: runtime.model, mirror: mirror, isEnabled: { true })
    observer.agentSessionDetector(detector, didObserve: agent)
    XCTAssertEqual(mirror.tracked, [id])
    XCTAssertEqual(
      runtime.model.snapshotForPersistence(windowId: "window").windows[0].tabs[0].paneStates?[0]
        .agent, agent)
  }
}

private struct SurvivorAgentProcesses: ProcessIntrospector {
  func children(of parent: pid_t) -> [(pid: pid_t, basename: String)] {
    parent == 100 ? [(101, "claude")] : []
  }
  func openVnodePaths(of pid: pid_t) -> [String] {
    ["/tmp/.claude/projects/project/0fa31a8c-1234-5678-9abc-deadbeef0001.jsonl"]
  }
  func arguments(of pid: pid_t) -> [String] { ["claude"] }
  func environment(of pid: pid_t) -> [String: String] { [:] }
  func currentWorkingDirectory(of pid: pid_t) -> String? { "/tmp" }
}
private final class SurvivorMirror: JSONLMirroring {
  var tracked: [String] = []
  func track(tabId: String, jsonlPath: String) { tracked.append(tabId) }
  func untrack(tabId: String, finalSnapshot: Bool) {}
  func snapshotAll() {}
}
