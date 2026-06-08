import Foundation
import XCTest

@testable import LabanDebug

final class ShellIntegrationEndpointTests: XCTestCase {
  func testInitialPhaseIsIdle() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let state = try json(runtime.shellIntegrationState(query: [:]))
    XCTAssertEqual(state["phase"] as? String, "idle")
    XCTAssertNil(state["lastExitCode"] as? Int)
  }

  func testFullCommandCycleEndsFinishedExitZero() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    // ESC = , BEL = . Drive A -> B -> C -> D;0.
    try feed(runtime, "\u{1B}]133;A\u{07}prompt$ \u{1B}]133;B\u{07}ls")
    try feed(runtime, "\u{1B}]133;C\u{07}output\n\u{1B}]133;D;0\u{07}")

    let state = try json(runtime.shellIntegrationState(query: [:]))
    XCTAssertEqual(state["phase"] as? String, "finished")
    XCTAssertEqual(state["lastExitCode"] as? Int, 0)
  }

  func testNonZeroExitSurfaces() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, "\u{1B}]133;C\u{07}\u{1B}]133;D;1\u{07}")

    let state = try json(runtime.shellIntegrationState(query: [:]))
    XCTAssertEqual(state["lastExitCode"] as? Int, 1)
  }

  func testTransitionsAppearOnEventStream() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, "\u{1B}]133;A\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D;0\u{07}")

    // onShellIntegrationChange is dispatched to the main queue; drain it.
    drainMainQueue()

    let events = try json(runtime.events(since: 0))
    let entries = (events["events"] as? [[String: Any]]) ?? []
    let phases =
      entries
      .filter { $0["kind"] as? String == "shell.integration" }
      .compactMap { $0["action"] as? String }
    XCTAssertEqual(phases, ["atPrompt", "running", "finished"])
  }

  func testActiveTabMetadataReflectsPhase() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, "\u{1B}]133;C\u{07}\u{1B}]133;D;3\u{07}")
    drainMainQueue()

    let state = try json(runtime.state())
    let tabs = try XCTUnwrap(state["tabs"] as? [[String: Any]])
    let active = try XCTUnwrap(tabs.first { $0["active"] as? Bool == true })
    XCTAssertEqual(active["shellPhase"] as? String, "finished")
    // The failed-command dot is a *background*-tab attention signal: a command
    // that exits non-zero on the tab the user is watching earns no dot, so the
    // active tab's lastCommandExitCode stays nil. The raw exit code is still
    // observable via the shell-integration endpoint (see testNonZeroExitSurfaces).
    XCTAssertNil(active["lastCommandExitCode"] as? Int)
  }

  func testMissingSessionReturns404() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.shellIntegrationState(query: ["sessionID": "missing"])
    XCTAssertEqual(response.status, 404)
  }

  // MARK: - Helpers

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-shellint-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "shellint-tests"
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
