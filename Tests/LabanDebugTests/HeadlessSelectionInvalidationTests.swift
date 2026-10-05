import Foundation
import XCTest

@testable import LabanDebug

/// Headless parity for the visible app's selection invalidation arms
/// (`TerminalBitmapViewSelectionTests`): the remote app, not Laban, can move
/// content under a local selection, so the harness must drop the selection on
/// the same triggers the app does or E2E frames and `copy` observe a stale one.
final class HeadlessSelectionInvalidationTests: XCTestCase {

  func testForwardedRightClickClearsSelection() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "sel-right-press")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let sessionId = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)

    feed(runtime, "alpha bravo\r\n\u{1b}[?1000h\u{1b}[?1006h")
    setSelection(runtime, row: 0, startCol: 0, endCol: 4)
    XCTAssertNotNil(runtime.selectionBySession[sessionId])

    let click = runtime.applyAction(
      try JSONSerialization.data(withJSONObject: [
        "action": "click", "x": runtime.sidebarWidth + 20, "y": 20, "button": "right",
      ]))
    XCTAssertEqual(click.status, 200)

    XCTAssertNil(
      runtime.selectionBySession[sessionId],
      "a right press forwarded under mouse tracking must clear the local selection")
  }

  func testAltScreenEntryClearsSelection() throws {
    let (runtime, artifacts) = try makeRuntime(runId: "sel-alt-entry")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let sessionId = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)

    feed(runtime, "alpha bravo\r\n")
    setSelection(runtime, row: 0, startCol: 0, endCol: 4)
    XCTAssertNotNil(runtime.selectionBySession[sessionId])

    feed(runtime, "\u{1b}[?1049h\u{1b}[Hgamma delta")

    XCTAssertNil(
      runtime.selectionBySession[sessionId],
      "entering the alternate screen must clear the primary-screen selection")
  }

  // MARK: - Helpers

  private func feed(_ runtime: HeadlessDebugRuntime, _ text: String) {
    let data = try! JSONSerialization.data(withJSONObject: [
      "action": "feedOutput", "text": text,
    ])
    XCTAssertEqual(runtime.applyAction(data).status, 200)
  }

  private func setSelection(
    _ runtime: HeadlessDebugRuntime, row: Int, startCol: Int, endCol: Int
  ) {
    let data = try! JSONSerialization.data(withJSONObject: [
      "action": "setSelection",
      "anchor": ["row": row, "col": startCol],
      "focus": ["row": row, "col": endCol],
    ])
    XCTAssertEqual(runtime.applyAction(data).status, 200)
  }

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
}
