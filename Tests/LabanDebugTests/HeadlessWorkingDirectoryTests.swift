import Foundation
import XCTest

@testable import LabanDebug

/// Headless parity for the OSC 7 working-directory bridge: a shell reporting its
/// cwd via `ESC ] 7 ; file://<host>/<path> ST` flows through the same C scanner
/// -> AppModel.onWorkingDirectoryChange path, surfacing on the debug event
/// stream (the headless counterpart of the cwd the metadata sync adopts).
final class HeadlessWorkingDirectoryTests: XCTestCase {
  func testOSC7LocalReportSurfacesAsCwdEvent() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, "\u{1B}]7;file://localhost/Users/me/work\u{07}")
    // onWorkingDirectoryChange is dispatched to the main queue; drain it.
    drainMainQueue()

    let events = try json(runtime.events(since: 0))
    let entries = (events["events"] as? [[String: Any]]) ?? []
    let cwds = entries.filter { $0["kind"] as? String == "cwd.osc7" }
    XCTAssertEqual(cwds.count, 1, "a local OSC 7 report must record one cwd event")
    XCTAssertEqual(cwds.first?["text"] as? String, "/Users/me/work")
  }

  func testOSC7RemoteReportProducesNoEvent() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, "\u{1B}]7;file://remote-box.invalid/home/u\u{07}")
    drainMainQueue()

    let events = try json(runtime.events(since: 0))
    let entries = (events["events"] as? [[String: Any]]) ?? []
    XCTAssertTrue(
      entries.allSatisfy { $0["kind"] as? String != "cwd.osc7" },
      "a remote-host OSC 7 report must not record a cwd event")
  }

  // MARK: - Helpers

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-osc7-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "osc7-tests"
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
