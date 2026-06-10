import Foundation
import XCTest

@testable import LabanCore
@testable import LabanDebug

/// Headless end-to-end coverage for user-configurable cursor style:
/// the user's "bar" preference must shape the cursor draw command, a program
/// DECSCUSR override (`ESC [2 SP q`) must win while explicit, and DECSCUSR 0
/// (`ESC [0 SP q`) must hand control back to the user preference. Also checks
/// the `/state` `cursorSettings` object that exposes the same facts to agents.
final class CursorSettingsHeadlessTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: CursorSettings.styleKey)
    UserDefaults.standard.removeObject(forKey: CursorSettings.blinkKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: CursorSettings.styleKey)
    UserDefaults.standard.removeObject(forKey: CursorSettings.blinkKey)
    super.tearDown()
  }

  func testUserBarStyleProgramOverrideAndRevert() throws {
    CursorSettings.setStyle(.bar)

    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let cellWidth = try cellWidth(runtime)
    try advanceFrames(runtime, count: 1)

    // Phase 1 — user preference applies: bar cursor, narrower than a cell.
    let barRect = try cursorRect(runtime)
    XCTAssertLessThan(
      barRect.width, cellWidth,
      "user 'bar' style must draw a cursor narrower than the cell")
    var state = try stateCursorSettings(runtime)
    XCTAssertEqual(state["style"] as? String, "bar")
    XCTAssertEqual(state["blinkEnabled"] as? Bool, false)
    XCTAssertEqual(state["styleOverridden"] as? Bool, false)
    XCTAssertEqual(state["blinkOverridden"] as? Bool, false)

    // Phase 2 — program override: DECSCUSR 2 (steady block) wins.
    try feedOutput(runtime, "\u{1B}[2 q")
    try advanceFrames(runtime, count: 1)
    let blockRect = try cursorRect(runtime)
    XCTAssertEqual(
      blockRect.width, cellWidth, accuracy: 0.5,
      "DECSCUSR steady block must draw a full-cell cursor despite the user's bar preference")
    state = try stateCursorSettings(runtime)
    XCTAssertEqual(state["styleOverridden"] as? Bool, true)
    XCTAssertEqual(state["blinkOverridden"] as? Bool, true)

    // Phase 3 — DECSCUSR 0 clears the override; the user's bar returns.
    try feedOutput(runtime, "\u{1B}[0 q")
    try advanceFrames(runtime, count: 1)
    let revertedRect = try cursorRect(runtime)
    XCTAssertLessThan(
      revertedRect.width, cellWidth,
      "DECSCUSR 0 must revert the cursor to the user's bar preference")
    XCTAssertEqual(
      revertedRect.width, barRect.width, accuracy: 0.5,
      "reverted cursor must match the original bar width")
    state = try stateCursorSettings(runtime)
    XCTAssertEqual(state["styleOverridden"] as? Bool, false)
    XCTAssertEqual(state["blinkOverridden"] as? Bool, false)
  }

  func testStateReportsUserSettingsWithDefaults() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let settings = try stateCursorSettings(runtime)
    XCTAssertEqual(
      settings["style"] as? String, "block",
      "missing defaults must report block style")
    XCTAssertEqual(
      settings["blinkEnabled"] as? Bool, false,
      "missing defaults must report blink disabled")
  }

  // MARK: - Helpers

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-cursor-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "cursor-settings-tests"
    )
    return (runtime, artifacts)
  }

  private func feedOutput(_ runtime: HeadlessDebugRuntime, _ text: String) throws {
    let data = try JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": text])
    let response = runtime.applyAction(data)
    XCTAssertEqual(response.status, 200)
  }

  private func advanceFrames(_ runtime: HeadlessDebugRuntime, count: Int) throws {
    let data = try JSONSerialization.data(
      withJSONObject: ["action": "advanceFrames", "count": count])
    let response = runtime.applyAction(data)
    XCTAssertEqual(response.status, 200)
  }

  private func cellWidth(_ runtime: HeadlessDebugRuntime) throws -> Double {
    let obj = try json(runtime.renderState())
    let cell = try XCTUnwrap(obj["cell"] as? [String: Any], "renderState must expose cell metrics")
    return try XCTUnwrap(cell["width"] as? Double, "cell metrics must include width")
  }

  /// The cursor draw command's rect from the latest frame-command dump.
  private func cursorRect(_ runtime: HeadlessDebugRuntime) throws -> CGRect {
    let obj = try json(runtime.frameCommands(query: ["source": "all", "limit": "2000"]))
    let commands = (obj["commands"] as? [[String: Any]]) ?? []
    let cursors = commands.filter { $0["kind"] as? String == "cursor" }
    XCTAssertEqual(cursors.count, 1, "exactly one cursor command expected per frame")
    let rect = try XCTUnwrap(cursors.first?["rect"] as? [String: Any])
    return CGRect(
      x: (rect["x"] as? Double) ?? 0,
      y: (rect["y"] as? Double) ?? 0,
      width: (rect["width"] as? Double) ?? 0,
      height: (rect["height"] as? Double) ?? 0)
  }

  private func stateCursorSettings(_ runtime: HeadlessDebugRuntime) throws -> [String: Any] {
    let obj = try json(runtime.state())
    return try XCTUnwrap(
      obj["cursorSettings"] as? [String: Any],
      "/state must include a cursorSettings object")
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    XCTAssertEqual(response.status, 200)
    return try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
