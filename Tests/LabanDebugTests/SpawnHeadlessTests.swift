import Foundation
import XCTest

@testable import LabanCore
@testable import LabanDebug

/// Headless parity for `laban new` / `laban split` (ADR 0024, Amendment
/// 2026-11-26): the same validation, anchoring, focus, label, and the
/// "Opened by a program" notice the GUI applies.
final class SpawnHeadlessTests: XCTestCase {
  private func makeRuntime() throws -> HeadlessDebugRuntime {
    try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("laban-debug-spawn-\(UUID().uuidString)"),
      tempURL: nil,
      deterministic: true,
      runId: "spawn-tests")
  }

  private func apply(_ runtime: HeadlessDebugRuntime, _ object: [String: Any], scoped: String?)
    throws -> DebugResponse
  {
    runtime.applyAction(try JSONSerialization.data(withJSONObject: object), scopedSessionID: scoped)
  }

  func testBackgroundTabCarriesLabelAndNoticeAndKeepsFocus() throws {
    let runtime = try makeRuntime()
    let first = try XCTUnwrap(runtime.model.activeTab)
    let response = try apply(
      runtime,
      ["action": "spawnTab", "argv": ["/usr/bin/make", "test"], "label": "tests", "focus": false],
      scoped: first.focusedSessionId)
    XCTAssertEqual(response.status, 200)
    let decoded = try JSONDecoder().decode(ControlSpawnResponse.self, from: response.body)
    XCTAssertEqual(decoded.placement, "tab")
    XCTAssertEqual(runtime.model.activeTab?.id, first.id, "--no-focus keeps the user's tab")
    let tab = try XCTUnwrap(runtime.model.tabs.first { $0.id == decoded.tabID })
    XCTAssertEqual(tab.title, "tests")
    XCTAssertEqual(tab.titleMetadata.notification?.text, "Opened by a program: make")
  }

  func testSplitDividesTheCallersPaneEvenWhenAnotherIsFocused() throws {
    let runtime = try makeRuntime()
    let tab = try XCTUnwrap(runtime.model.activeTab)
    let caller = tab.focusedSessionId
    XCTAssertEqual(try apply(runtime, ["action": "pane.split"], scoped: nil).status, 200)
    let focused = try XCTUnwrap(runtime.model.activeTab?.focusedSessionId)
    XCTAssertNotEqual(focused, caller)

    let response = try apply(
      runtime, ["action": "spawnSplit", "direction": "down", "focus": false], scoped: caller)
    XCTAssertEqual(response.status, 200)
    let decoded = try JSONDecoder().decode(ControlSpawnResponse.self, from: response.body)
    let updated = try XCTUnwrap(runtime.model.tabs.first { $0.id == tab.id })
    XCTAssertEqual(updated.focusedSessionId, focused)
    guard case .split(_, _, let first, _) = updated.panes,
      case .split(.horizontal, _, .leaf(caller), .leaf(decoded.sessionID)) = first
    else {
      return XCTFail("the new pane must sit under the caller's pane: \(updated.panes)")
    }
  }

  func testRefusalsComeBackWithTheirReason() throws {
    let runtime = try makeRuntime()
    let response = try apply(
      runtime, ["action": "spawnSplit", "direction": "left"], scoped: nil)
    XCTAssertEqual(response.status, 400)
    XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("right or down"))
  }
}
