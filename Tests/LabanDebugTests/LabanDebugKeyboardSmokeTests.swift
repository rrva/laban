import Foundation
import XCTest

@testable import LabanDebug

final class LabanDebugKeyboardSmokeTests: XCTestCase {

  private func makeRuntime(
    sessionMode: HeadlessSessionMode = .fixture
  ) throws -> HeadlessDebugRuntime {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-keyboard-test-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: artifacts) }
    return try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "keyboard-smoke",
      sessionMode: sessionMode
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

  private func waitForText(
    _ runtime: HeadlessDebugRuntime,
    _ text: String,
    timeoutMs: Int = 2_000
  ) throws -> Bool {
    let body = try JSONSerialization.data(
      withJSONObject: [
        "timeoutMs": timeoutMs,
        "condition": [
          "kind": "textVisible",
          "text": text,
        ],
      ])
    let obj = jsonDict(runtime.wait(body))
    return obj["ok"] as? Bool == true
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

  func testRealShellCatVReceivesDebugKeyActions() throws {
    let runtime = try makeRuntime(sessionMode: .realShell)
    let marker = "CATV_READY"
    let octalMarker = marker.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
    let command = "stty -echo -icanon min 1 time 0; printf '\(octalMarker)\\012'; cat -vet\n"
    XCTAssertFalse(command.contains(marker), "typed command must not satisfy its own wait")

    _ = runtime.applyAction(action(["action": "typeText", "text": command]))
    XCTAssertTrue(try waitForText(runtime, marker), "cat -vet command did not become ready")

    _ = runtime.applyAction(action(["action": "key", "key": "tab"]))
    _ = runtime.applyAction(action(["action": "key", "key": "backspace"]))
    _ = runtime.applyAction(action(["action": "key", "key": "arrowUp"]))
    _ = runtime.applyAction(action(["action": "key", "key": "tab", "modifiers": ["shift"]]))
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

    XCTAssertTrue(
      try waitForText(runtime, "^I^?^[[A^[[Z$"),
      "cat -vet should visibly receive tab, backspace, arrow, backtab, and Option text bytes")

    _ = runtime.applyAction(
      action(["action": "key", "key": "c", "modifiers": ["control"]]))
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
