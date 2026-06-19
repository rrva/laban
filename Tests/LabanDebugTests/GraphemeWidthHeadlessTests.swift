import Foundation
import XCTest

@testable import LabanCore
@testable import LabanDebug

/// Headless end-to-end coverage for the "Unicode width" user preference
/// (`GraphemeWidthSettings`): a fresh session created under `.preferGrapheme`
/// must start with DEC mode 2027 (grapheme cluster) ON — observable via
/// `GET /debug/terminal-modes` BEFORE any program sends a sequence — while
/// `.auto` leaves it OFF until a program negotiates the mode. The preference is
/// read by `Session.init` (the single shared session-creation funnel reachable
/// by both the app and the headless runtime), so this exercises the real
/// production wiring, not a parallel rig.
final class GraphemeWidthHeadlessTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: GraphemeWidthSettings.defaultsKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: GraphemeWidthSettings.defaultsKey)
    super.tearDown()
  }

  func testPreferGraphemeStartsFreshSessionWithMode2027On() throws {
    GraphemeWidthSettings.set(.preferGrapheme)

    let (runtime, artifacts) = try makeRuntime(runId: "grapheme-prefer")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    XCTAssertEqual(
      try modes(runtime)["grapheme_cluster_2027"] as? Bool, true,
      "a session created under .preferGrapheme must report mode 2027 ON before any program output")
  }

  func testAutoStartsFreshSessionWithMode2027Off() throws {
    GraphemeWidthSettings.set(.auto)

    let (runtime, artifacts) = try makeRuntime(runId: "grapheme-auto")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    XCTAssertEqual(
      try modes(runtime)["grapheme_cluster_2027"] as? Bool, false,
      "a session created under .auto must report mode 2027 OFF until a program negotiates it")
  }

  func testAutoSessionStillHonorsProgramDecsetOverride() throws {
    GraphemeWidthSettings.set(.auto)

    let (runtime, artifacts) = try makeRuntime(runId: "grapheme-auto-override")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    XCTAssertEqual(try modes(runtime)["grapheme_cluster_2027"] as? Bool, false)

    // A program turning the mode on at runtime still wins under .auto.
    try feedOutput(runtime, "\u{1B}[?2027h")
    XCTAssertEqual(
      try modes(runtime)["grapheme_cluster_2027"] as? Bool, true,
      "a program's DECSET 2027 must enable the mode even when the preference is .auto")
  }

  func testPreferGraphemeSessionStillHonorsProgramDecrstOverride() throws {
    GraphemeWidthSettings.set(.preferGrapheme)

    let (runtime, artifacts) = try makeRuntime(runId: "grapheme-prefer-override")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    XCTAssertEqual(try modes(runtime)["grapheme_cluster_2027"] as? Bool, true)

    // The preference is only a starting default — a program's DECRST 2027 wins.
    try feedOutput(runtime, "\u{1B}[?2027l")
    XCTAssertEqual(
      try modes(runtime)["grapheme_cluster_2027"] as? Bool, false,
      "a program's DECRST 2027 must override the .preferGrapheme starting default")
  }

  // MARK: - Helpers

  private func makeRuntime(runId: String) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-grapheme-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: runId
    )
    return (runtime, artifacts)
  }

  private func feedOutput(_ runtime: HeadlessDebugRuntime, _ text: String) throws {
    let data = try JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": text])
    XCTAssertEqual(runtime.applyAction(data).status, 200)
  }

  private func modes(_ runtime: HeadlessDebugRuntime) throws -> [String: Any] {
    let response = runtime.terminalModes()
    XCTAssertEqual(response.status, 200)
    return try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
