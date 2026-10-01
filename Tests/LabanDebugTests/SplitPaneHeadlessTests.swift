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

  var area: CGRect {
    CGRect(
      x: runtime.sidebarWidth, y: 0, width: runtime.windowWidth - runtime.sidebarWidth,
      height: runtime.windowHeight)
  }

  /// Origins of every terminal glyph run whose text contains `needle`.
  func origins(of needle: String) -> [CGPoint] {
    runtime.lastFrameCommands.compactMap { command in
      if case .glyphRun(let origin, let text, _, _, _, let source, _, _, _, _, _, _, _) = command,
        source == .terminal, text.contains(needle)
      {
        return origin
      }
      return nil
    }
  }

  func rects(width: CGFloat? = nil, height: CGFloat? = nil) -> [CGRect] {
    runtime.lastFrameCommands.compactMap { command in
      if case .rect(let rect, _, let source, _) = command, source == .terminal,
        width.map({ rect.width == $0 }) ?? true, height.map({ rect.height == $0 }) ?? true
      {
        return rect
      }
      return nil
    }
  }

  /// `left | (topRight / bottomRight)`, focus on the bottom-right pane.
  func threePanes() throws -> (left: String, topRight: String, bottomRight: String) {
    let (left, topRight) = try split()
    try action("pane.split", ["axis": "horizontal"])
    let bottomRight = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    XCTAssertEqual(runtime.model.activeTab?.allSessionIds, [left, topRight, bottomRight])
    return (left, topRight, bottomRight)
  }

  func testThreePaneLayoutRendersThreeOriginsAndTwoDividers() throws {
    let (left, topRight, bottomRight) = try threePanes()
    try printText("PANE-ALPHA", in: left)
    try printText("PANE-BRAVO", in: topRight)
    try printText("PANE-CHARLIE", in: bottomRight)
    let tab = try XCTUnwrap(runtime.model.activeTab)
    let layout = Dictionary(
      uniqueKeysWithValues: tab.visibleLayout(in: area).map { ($0.sessionId, $0.rect) })
    for (id, needle) in [
      (left, "PANE-ALPHA"), (topRight, "PANE-BRAVO"), (bottomRight, "PANE-CHARLIE"),
    ] {
      let rect = try XCTUnwrap(layout[id])
      let found = origins(of: needle)
      XCTAssertFalse(found.isEmpty, needle)
      XCTAssertTrue(found.allSatisfy { rect.contains($0) }, "\(needle) must draw inside its pane")
    }
    let dividers = tab.visibleDividers(in: area)
    XCTAssertEqual(dividers.map(\.path), [[], [.second]])
    XCTAssertEqual(dividers.map(\.axis), [.vertical, .horizontal])
    for divider in dividers {
      XCTAssertEqual(
        rects().filter { $0 == divider.rect }.count, 1, "one rect for divider \(divider.path)")
    }
    XCTAssertTrue(rects(width: PaneDivider.previewThickness).isEmpty, "no preview without a drag")
    XCTAssertEqual(runtime.lastFramePaneSessionIds.count, 3)
  }

  func testZoomedTabUsesSinglePaneFrame() throws {
    let (left, _, bottomRight) = try threePanes()
    try action("pane.focus", ["sessionId": left])
    try printText("ZOOMED-LEFT", in: left)
    XCTAssertEqual(runtime.lastFramePaneSessionIds.count, 3)
    let tab = try XCTUnwrap(runtime.model.activeTab)
    let dividerRects = tab.visibleDividers(in: area).map(\.rect)
    XCTAssertEqual(dividerRects.count, 2)
    // Debug coordinates are top-down; layout rects are y up.
    let hiddenRect = try XCTUnwrap(
      tab.visibleLayout(in: area).first { $0.sessionId == bottomRight }?.rect)
    let hiddenX = Int(hiddenRect.midX)
    let hiddenY = runtime.windowHeight - Int(hiddenRect.midY)
    XCTAssertEqual(runtime.paneHit(x: hiddenX, y: hiddenY)?.sessionId, bottomRight)

    try action("pane.zoom", ["zoomed": true])
    runtime.renderFrameUnlocked()
    // Hit-testing goes through `Tab.visibleLayout`: the point that used to land in the
    // bottom-right pane now lands in the zoomed pane, whose rect is the whole area.
    let zoomedHit = try XCTUnwrap(runtime.paneHit(x: hiddenX, y: hiddenY))
    XCTAssertEqual(zoomedHit.sessionId, left)
    XCTAssertEqual(zoomedHit.rect, area)
    XCTAssertNil(runtime.paneHit(x: hiddenX, y: hiddenY, sessionId: bottomRight))
    let position = runtime.terminalMousePosition(x: hiddenX, y: hiddenY)
    XCTAssertEqual(CGFloat(position.x), CGFloat(hiddenX) - area.minX, accuracy: 0.5)
    XCTAssertEqual(runtime.model.activeTab?.zoomedSessionId, left)
    XCTAssertEqual(runtime.lastFramePaneSessionIds, [left])
    for divider in dividerRects {
      XCTAssertFalse(rects().contains(divider), "no divider while zoomed")
    }
    let found = origins(of: "ZOOMED-LEFT")
    XCTAssertFalse(found.isEmpty)
    XCTAssertTrue(
      found.allSatisfy { $0.x == area.minX }, "zoomed text starts at the terminal-area origin")
    XCTAssertFalse(origins(of: "ZOOMED-LEFT").isEmpty)
    // The hidden panes are not drawn at all.
    XCTAssertFalse(runtime.lastFramePaneSessionIds.contains(bottomRight))

    try action("pane.zoom", ["zoomed": false])
    runtime.renderFrameUnlocked()
    XCTAssertEqual(runtime.lastFramePaneSessionIds.count, 3)
  }

  func testZoomedTabShowsPaneCountBadgeInSidebar() throws {
    _ = try threePanes()
    func badges() -> [String] {
      runtime.lastFrameCommands.compactMap { command in
        if case .glyphRun(_, let text, _, _, _, let source, _, _, _, _, _, _, _) = command,
          source == .sidebar, text.contains("\u{2922}")
        {
          return text
        }
        return nil
      }
    }
    runtime.renderFrameUnlocked()
    XCTAssertTrue(badges().isEmpty)
    try action("pane.zoom", ["zoomed": true])
    runtime.renderFrameUnlocked()
    XCTAssertEqual(badges(), [SidebarProducer.zoomBadgeText(paneCount: 3)])
    try action("pane.zoom", ["zoomed": false])
    runtime.renderFrameUnlocked()
    XCTAssertTrue(badges().isEmpty, "the sidebar memo must not keep a stale badge")
  }

  func testDividerDragCommitsOnRelease() throws {
    _ = try split()
    runtime.renderFrameUnlocked()
    let divider = try XCTUnwrap(runtime.model.activeTab?.visibleDividers(in: area).first)
    XCTAssertEqual(divider.fraction, 0.5, accuracy: 0.001)
    let startX = Int(divider.rect.midX)
    let y = Int(divider.rect.midY)
    XCTAssertTrue(runtime.beginDividerDrag(x: startX, y: y))
    XCTAssertTrue(rects(width: PaneDivider.previewThickness).isEmpty, "nothing before a move")

    let target = divider.container.minX + divider.container.width / 3
    runtime.updateDividerDrag(x: startX - 40, y: y)
    runtime.updateDividerDrag(x: Int(target), y: y)
    runtime.renderFrameUnlocked()
    let during = try XCTUnwrap(runtime.model.activeTab)
    guard case .split(_, let duringFraction, _, _) = during.panes else { return XCTFail() }
    XCTAssertEqual(duringFraction, 0.5, accuracy: 0.0001, "the tree is untouched mid-drag")
    let previews = rects(width: PaneDivider.previewThickness, height: area.height)
    XCTAssertEqual(previews.count, 1)
    XCTAssertEqual(try XCTUnwrap(previews.first).midX, target, accuracy: 2)
    XCTAssertEqual(rects(width: 1, height: area.height).count, 1, "the real divider stays put")

    runtime.commitDividerDrag()
    runtime.renderFrameUnlocked()
    let after = try XCTUnwrap(runtime.model.activeTab)
    guard case .split(_, let finalFraction, _, _) = after.panes else { return XCTFail() }
    let cell = Double(runtime.cellWidth)
    XCTAssertEqual(
      finalFraction * Double(area.width), Double(target - area.minX), accuracy: cell)
    XCTAssertTrue(rects(width: PaneDivider.previewThickness).isEmpty, "preview ends on release")
    XCTAssertNil(runtime.dividerDrag)
  }

  func testDividerDragPreviewIsClampedToMinimumPaneWidth() throws {
    _ = try split()
    let divider = try XCTUnwrap(runtime.model.activeTab?.visibleDividers(in: area).first)
    XCTAssertTrue(runtime.beginDividerDrag(x: Int(divider.rect.midX), y: Int(divider.rect.midY)))
    runtime.updateDividerDrag(x: Int(area.minX) + 2, y: Int(divider.rect.midY))
    let preview = try XCTUnwrap(runtime.dividerPreviewRect)
    let minWidth = 10 * CGFloat(runtime.cellWidth)
    XCTAssertGreaterThanOrEqual(preview.midX - area.minX, minWidth)
    runtime.cancelDividerDrag()
    XCTAssertNil(runtime.dividerPreviewRect)
  }

  func testUnzoomShowsOutputWrittenWhileHidden() throws {
    let (left, right) = try split()
    try action("pane.zoom", ["zoomed": true])
    runtime.renderFrameUnlocked()
    XCTAssertEqual(runtime.lastFramePaneSessionIds, [right])
    try printText("WRITTEN-WHILE-HIDDEN", in: left)
    try action("pane.zoom", ["zoomed": false])
    runtime.renderFrameUnlocked()
    let leftRect = try XCTUnwrap(
      runtime.model.activeTab?.visibleLayout(in: area).first { $0.sessionId == left }?.rect)
    let found = origins(of: "WRITTEN-WHILE-HIDDEN")
    XCTAssertFalse(found.isEmpty, "output written while hidden must draw after unzoom")
    XCTAssertTrue(found.allSatisfy { leftRect.contains($0) })
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
