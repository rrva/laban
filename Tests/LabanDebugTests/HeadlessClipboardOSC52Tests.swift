import Foundation
import XCTest

@testable import LabanDebug

/// Headless parity for the OSC 52 clipboard bridge: a program copying via
/// `ESC ] 52 ; c ; <base64> ST` must flow through the same C scanner ->
/// AppModel.onClipboardWrite path the AppKit host uses, surfacing on the debug
/// event stream (the headless counterpart of the NSPasteboard write).
final class HeadlessClipboardOSC52Tests: XCTestCase {
  func testOSC52WriteSurfacesAsClipboardEvent() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    // base64("hello") == "aGVsbG8=".
    try feed(runtime, "\u{1B}]52;c;aGVsbG8=\u{07}")
    // onClipboardWrite is dispatched to the main queue; drain it.
    drainMainQueue()

    let events = try json(runtime.events(since: 0))
    let entries = (events["events"] as? [[String: Any]]) ?? []
    let writes = entries.filter { $0["kind"] as? String == "clipboard.osc52Write" }
    XCTAssertEqual(writes.count, 1, "an OSC 52 write must record exactly one clipboard event")
    XCTAssertEqual(writes.first?["text"] as? String, "hello")
  }

  func testOSC52ReadQueryProducesNoEventWhileDisabled() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    // Read is off by default: a `?` query is dropped — no clipboard event.
    try feed(runtime, "\u{1B}]52;c;?\u{07}")
    drainMainQueue()

    let events = try json(runtime.events(since: 0))
    let entries = (events["events"] as? [[String: Any]]) ?? []
    XCTAssertTrue(
      entries.allSatisfy { $0["kind"] as? String != "clipboard.osc52Write" },
      "a denied OSC 52 read must not record a clipboard write event")
  }

  // MARK: - Helpers

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-osc52-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "osc52-tests"
    )
    return (runtime, artifacts)
  }

  private func feed(_ runtime: HeadlessDebugRuntime, _ text: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["action": "feedOutput", "text": text])
    let response = runtime.applyAction(data)
    XCTAssertEqual(response.status, 200)
  }

  private func drainMainQueue() {
    let expectation = expectation(description: "main queue drained")
    DispatchQueue.main.async { expectation.fulfill() }
    wait(for: [expectation], timeout: 2.0)
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
