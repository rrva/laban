import Foundation
import XCTest

@testable import LabanDebug

final class LabanDebugKeyboardSmokeTests: XCTestCase {

  private func makeRuntime() throws -> HeadlessDebugRuntime {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-keyboard-test-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: artifacts) }
    return try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "keyboard-smoke"
    )
  }

  private func action(_ dict: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: dict)
  }

  private func jsonDict(_ response: DebugResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
  }

  private func inputLog(_ runtime: HeadlessDebugRuntime, since: Int = 0) -> [[String: Any]] {
    let resp = runtime.inputLogResponse(since: since)
    let dict = jsonDict(resp)
    return (dict["events"] as? [[String: Any]]) ?? []
  }

  func testEnterKeyLogsTerminalRouteWithRequiredFields() throws {
    let runtime = try makeRuntime()
    let resp = runtime.applyAction(action(["action": "key", "key": "enter"]))
    let result = jsonDict(resp)
    XCTAssertEqual(result["ok"] as? Bool, true)

    let events = inputLog(runtime)
    guard let ev = events.last else {
      XCTFail("no input log entry")
      return
    }
    XCTAssertEqual(ev["kind"] as? String, "key")
    XCTAssertEqual(ev["route"] as? String, "terminal")
    XCTAssertNotNil(ev["inputId"])
    XCTAssertNotNil(ev["frameBefore"])
    XCTAssertNotNil(ev["sessionId"])
  }

  func testCommandTCreatesTabAndLogsAppCommand() throws {
    let runtime = try makeRuntime()
    let stateBefore = jsonDict(runtime.state())
    let tabsBefore = (stateBefore["tabs"] as? [[String: Any]])?.count ?? 0

    _ = runtime.applyAction(
      action(["action": "key", "key": "t", "modifiers": ["command"]]))

    let stateAfter = jsonDict(runtime.state())
    let tabsAfter = (stateAfter["tabs"] as? [[String: Any]])?.count ?? 0
    XCTAssertEqual(tabsAfter, tabsBefore + 1, "Cmd-T should create a new tab")

    let events = inputLog(runtime)
    guard let ev = events.last else {
      XCTFail("no input log entry")
      return
    }
    XCTAssertEqual(ev["kind"] as? String, "key")
    XCTAssertEqual(ev["route"] as? String, "appCommand")
    XCTAssertEqual(ev["command"] as? String, "newTab")
  }

  func testUnhandledCommandKeyLogsIgnored() throws {
    let runtime = try makeRuntime()
    _ = runtime.applyAction(
      action(["action": "key", "key": "x", "modifiers": ["command"]]))

    let events = inputLog(runtime)
    guard let ev = events.last else {
      XCTFail("no input log entry")
      return
    }
    XCTAssertEqual(ev["route"] as? String, "ignored")
    XCTAssertNil(ev["encodedHex"])
  }

  func testOptionConsumedTextKeyLogsEncodedBytes() throws {
    let runtime = try makeRuntime()
    _ = runtime.applyAction(
      action(
        [
          "action": "key",
          "key": "4",
          "modifiers": ["option"],
          "consumedModifiers": ["option"],
          "text": "$",
          "unshifted": "4",
        ] as [String: Any]))

    let events = inputLog(runtime)
    guard let ev = events.last else {
      XCTFail("no input log entry")
      return
    }
    XCTAssertEqual(ev["kind"] as? String, "key")
    XCTAssertEqual(ev["route"] as? String, "terminal")
    let consumed = ev["consumedModifiers"] as? [String] ?? []
    XCTAssertTrue(consumed.contains("option"))
    XCTAssertNotNil(ev["encodedHex"], "encoded bytes should be present for text key")
  }

  func testInputLogSinceFiltersCorrectly() throws {
    let runtime = try makeRuntime()
    _ = runtime.applyAction(action(["action": "key", "key": "enter"]))
    _ = runtime.applyAction(action(["action": "key", "key": "enter"]))

    let all = inputLog(runtime, since: 0)
    XCTAssertEqual(all.count, 2)

    let next = (jsonDict(runtime.inputLogResponse(since: 0))["next"] as? Int) ?? 0
    let none = inputLog(runtime, since: next)
    XCTAssertTrue(none.isEmpty, "since=next should return no events")
  }
}
