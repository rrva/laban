import Foundation
import XCTest

@testable import LabanDebug

/// Headless parity for ADR 0040: once a program enables Kitty paste events
/// (mode 5522), the debug `paste` action sends an OSC 5522 paste event
/// instead of bracketed text, exactly like the AppKit ⌘V path.
final class HeadlessKittyPasteEventTests: XCTestCase {
  func testPasteSendsAPasteEventWhenMode5522IsOn() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try act(runtime, ["action": "feedOutput", "text": "\u{1B}[?5522h"])
    try act(runtime, ["action": "setClipboardText", "text": "hello"])
    try act(runtime, ["action": "paste"])

    let kinds = try eventKinds(runtime)
    XCTAssertTrue(kinds.contains("clipboard.pasteEvent"), "\(kinds)")
    XCTAssertFalse(kinds.contains("clipboard.pasted"), "no text paste while mode 5522 is on")
  }

  func testPasteStaysTextWithoutMode5522() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try act(runtime, ["action": "setClipboardText", "text": "hello"])
    try act(runtime, ["action": "paste"])

    let kinds = try eventKinds(runtime)
    XCTAssertTrue(kinds.contains("clipboard.pasted"), "\(kinds)")
    XCTAssertFalse(kinds.contains("clipboard.pasteEvent"))
  }

  // MARK: - Helpers

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-5522-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "kitty-paste-event-tests"
    )
    return (runtime, artifacts)
  }

  private func act(_ runtime: HeadlessDebugRuntime, _ body: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = runtime.applyAction(data)
    XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
  }

  private func eventKinds(_ runtime: HeadlessDebugRuntime) throws -> [String] {
    let events =
      try JSONSerialization.jsonObject(with: runtime.events(since: 0).body) as! [String: Any]
    return ((events["events"] as? [[String: Any]]) ?? []).compactMap { $0["kind"] as? String }
  }
}
