import Foundation
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanDebug

final class PaneReviewHeadlessTests: XCTestCase {
  private var runtime: HeadlessDebugRuntime!
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    runtime = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: root, tempURL: nil,
      deterministic: true, runId: "pane-review",
      persistenceBaseURL: root.appendingPathComponent("persist"))
  }
  override func tearDown() {
    runtime.shutdown(terminateRemoteSessions: true)
    runtime = nil
    try? FileManager.default.removeItem(at: root)
  }
  @discardableResult private func action(
    _ name: String, _ values: [String: Any] = [:], status: Int = 200
  ) throws -> DebugResponse {
    var body = values
    body["action"] = name
    let result = runtime.applyAction(try JSONSerialization.data(withJSONObject: body))
    XCTAssertEqual(result.status, status, String(decoding: result.body, as: UTF8.self))
    return result
  }
  private func split() throws -> (String, String) {
    let left = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    try action("pane.split")
    return (left, try XCTUnwrap(runtime.model.activeTab?.focusedSessionId))
  }
  func testFinalPaneCloseAndShortcutLeaveSessionAlive() throws {
    let id = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    try action("pane.close", status: 400)
    try action("key", ["key": "d", "modifiers": ["command", "shift"]])
    XCTAssertEqual(runtime.model.tabs.count, 1)
    XCTAssertNotNil(runtime.model.session(forSessionID: id))
  }
  func testExplicitUnfocusedScrollSelectionCopyAndPreedit() throws {
    let (left, right) = try split()
    let a = try XCTUnwrap(runtime.model.session(forSessionID: left))
    let b = try XCTUnwrap(runtime.model.session(forSessionID: right))
    for session in [a, b] {
      session.feedOutput(Array((0..<100).map { "line \($0)\r\n" }.joined().utf8))
    }
    runtime.renderFrameUnlocked()
    let offset = b.viewportState()?.viewportOffset
    try action("scrollViewport", ["sessionId": left, "deltaRows": -4])
    XCTAssertNotEqual(a.viewportState()?.viewportOffset, offset)
    XCTAssertEqual(b.viewportState()?.viewportOffset, offset)
    a.scrollViewportToActiveBottom()
    a.feedOutput(Array("\u{1b}[2J\u{1b}[HLEFT".utf8))
    b.feedOutput(Array("\u{1b}[2J\u{1b}[HRIGHT".utf8))
    try action(
      "setSelection",
      ["sessionId": left, "anchor": ["row": 0, "col": 0], "focus": ["row": 0, "col": 3]])
    try action("copy", ["sessionId": left])
    XCTAssertEqual(runtime.lastCopyText, "LEFT")
    XCTAssertNil(runtime.selectionBySession[right])
    try action("setPreedit", ["sessionId": left, "text": "か"])
    XCTAssertEqual(runtime.preeditBySession[left]?.text, "か")
    XCTAssertNil(runtime.preeditBySession[right])
    for name in ["scrollViewport", "copy", "setPreedit"] {
      try action(name, ["sessionId": "missing"], status: 400)
    }
  }
  func testClickReportsPaneLocalCoordinates() throws {
    let (_, right) = try split()
    try XCTUnwrap(runtime.model.session(forSessionID: right)).feedOutput(
      Array("\u{1b}[?1000h\u{1b}[?1006h".utf8))
    let rect = try XCTUnwrap(runtime.paneHit(x: 0, y: 0, sessionId: right)).rect
    try action(
      "click",
      [
        "sessionId": right, "x": Int(rect.minX) + runtime.cellWidth * 3,
        "y": runtime.windowHeight - runtime.cellHeight * 2, "button": "left",
      ])
    let report = try XCTUnwrap(runtime.logs.inputLogResponse(since: 0).events.last)
    XCTAssertEqual(report.sessionId, right)
    XCTAssertEqual(
      report.encodedHex,
      Array("\u{1b}[<0;4;3M\u{1b}[<0;4;3m".utf8).map { String(format: "%02x", $0) }.joined())
  }
  func testWindowBlurAndRepeatedPaneFocusDoNotSendFocusIn() throws {
    let (left, right) = try split()
    for id in [left, right] {
      runtime.model.session(forSessionID: id)?.feedOutput(Array("\u{1b}[?1004h".utf8))
    }
    runtime.renderFrameUnlocked()
    try action("windowFocus", ["focused": false])
    try action("pane.focus", ["sessionId": left])
    let blurredReport = try XCTUnwrap(
      runtime.logs.eventsResponse(since: 0).events.last { $0.kind == "focus.reported" })
    XCTAssertEqual(blurredReport.sessionId, left)
    XCTAssertEqual(blurredReport.action, "focusOut")
    let count = runtime.logs.terminalBytes.input
    try action("pane.focus", ["sessionId": left])
    try action("windowFocus", ["focused": false])
    XCTAssertEqual(runtime.logs.terminalBytes.input, count)
    try action("windowFocus", ["focused": true])
    XCTAssertEqual(runtime.logs.terminalBytes.input, count + 3)
  }
  func testBackgroundSplitCastUsesSpawnedPaneDimensionsBeforeSelection() throws {
    let tab = try XCTUnwrap(runtime.model.activeTab)
    try action("newTab")
    try action("pane.split", ["tabId": tab.id])
    let paneId = try XCTUnwrap(runtime.model.tabs.first { $0.id == tab.id }?.focusedSessionId)
    let session = try XCTUnwrap(runtime.model.session(forSessionID: paneId))
    session.feedOutput(Array("BACKGROUND".utf8))
    let snapshot = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snapshot) }
    guard case .success(let data, _, _, _) = runtime.recentCastBytes(seconds: 10, tabId: tab.id)
    else { return XCTFail("cast unavailable") }
    let headerData = Data(try XCTUnwrap(data.split(separator: 10).first))
    let header = try XCTUnwrap(JSONSerialization.jsonObject(with: headerData) as? [String: Any])
    XCTAssertEqual(header["width"] as? Int, Int(snapshot.pointee.cols))
    XCTAssertEqual(header["height"] as? Int, Int(snapshot.pointee.rows))
    XCTAssertLessThan(Int(snapshot.pointee.cols), Int(runtime.model.terminalAreaSize.cols))
    XCTAssertNotEqual(runtime.model.activeTab?.id, tab.id)
  }

  func testSplitCastUsesPaneGridDimensions() throws {
    let (_, right) = try split()
    runtime.model.session(forSessionID: right)?.feedOutput(Array("CAST".utf8))
    guard case .success(let data, _, _, _) = runtime.recentCastBytes(seconds: 10, tabId: nil) else {
      return XCTFail("cast unavailable")
    }
    let headerData = try XCTUnwrap(data.split(separator: 10).first).withUnsafeBytes { Data($0) }
    let header = try XCTUnwrap(JSONSerialization.jsonObject(with: headerData) as? [String: Any])
    XCTAssertEqual(header["width"] as? Int, Int(runtime.model.terminalSize(for: right).cols))
    XCTAssertLessThan(header["width"] as? Int ?? 0, Int(runtime.model.terminalAreaSize.cols))
  }
}
