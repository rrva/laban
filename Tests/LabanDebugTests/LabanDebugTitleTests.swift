import Foundation
import XCTest

@testable import LabanDebug

final class LabanDebugTitleTests: XCTestCase {
  private func makeRuntime(runId: String = "debug-title") throws -> (HeadlessDebugRuntime, URL) {
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

  private func jsonObject(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }

  private func post(_ runtime: HeadlessDebugRuntime, _ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    let response = runtime.applyAction(data)
    XCTAssertEqual(response.status, 200)
    let body = try jsonObject(response)
    XCTAssertEqual(body["ok"] as? Bool, true)
  }

  private func firstTab(from response: DebugResponse) throws -> [String: Any] {
    let state = try jsonObject(response)
    let tabs = state["tabs"] as! [[String: Any]]
    return tabs[0]
  }

  func testStateExposesTerminalTitleMetadata() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try post(runtime, ["action": "feedOutput", "text": "\u{1B}]0;ShellTitle\u{07}"])

    let tab = try firstTab(from: runtime.state())
    XCTAssertEqual(tab["title"] as? String, "ShellTitle")
    XCTAssertEqual(tab["displayTitle"] as? String, "ShellTitle")
    XCTAssertEqual(tab["titleSource"] as? String, "terminal")
    XCTAssertEqual(tab["terminalTitle"] as? String, "ShellTitle")
    XCTAssertEqual(tab["activityState"] as? String, "active")
    XCTAssertNotNil(tab["lastOutputAt"])
  }

  func testManualTitleSurvivesLaterTerminalTitleInDebugState() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try post(runtime, ["action": "setTabTitle", "title": "auth retry cleanup"])
    try post(runtime, ["action": "feedOutput", "text": "\u{1B}]0;vim README.md\u{07}"])

    let tab = try firstTab(from: runtime.state())
    XCTAssertEqual(tab["title"] as? String, "auth retry cleanup")
    XCTAssertEqual(tab["displayTitle"] as? String, "auth retry cleanup")
    XCTAssertEqual(tab["titleSource"] as? String, "user")
    XCTAssertEqual(tab["userTitle"] as? String, "auth retry cleanup")
    XCTAssertEqual(tab["terminalTitle"] as? String, "vim README.md")
  }

  func testLongTerminalTitleIsBoundedInDebugState() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let long = String(repeating: "a", count: 600)
    try post(runtime, ["action": "feedOutput", "text": "\u{1B}]0;\(long)\u{07}"])

    let tab = try firstTab(from: runtime.state())
    let terminalTitle = tab["terminalTitle"] as? String
    XCTAssertEqual(terminalTitle?.count, 256)
    XCTAssertEqual((tab["displayTitle"] as? String)?.count, 256)
  }

  func testSessionsExposeTitleMetadataAndInjectedWorkspace() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try post(
      runtime,
      [
        "action": "setTabMetadata",
        "repoName": "laban",
        "worktreeName": "cobra",
        "branch": "main",
        "isDirty": true,
        "foregroundProcess": "claude",
      ])

    let response = runtime.sessions()
    XCTAssertEqual(response.status, 200)
    let body = try jsonObject(response)
    let sessions = body["sessions"] as! [[String: Any]]
    let first = sessions[0]
    XCTAssertEqual(first["displayTitle"] as? String, "laban@cobra")
    XCTAssertEqual(first["titleSource"] as? String, "repo")
    let workspace = first["workspace"] as! [String: Any]
    XCTAssertEqual(workspace["branch"] as? String, "main")
    XCTAssertEqual(workspace["isDirty"] as? Bool, true)
    let process = first["process"] as! [String: Any]
    XCTAssertEqual(process["foregroundProcess"] as? String, "claude")
  }

  func testDebugCanExposeExitedActivityState() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try post(
      runtime,
      ["action": "setTabMetadata", "activityState": "exited", "exitStatus": 7])

    let tab = try firstTab(from: runtime.state())
    XCTAssertEqual(tab["activityState"] as? String, "exited")
    XCTAssertEqual(tab["exitStatus"] as? Int, 7)
  }

  func testDebugCanExposeBellAttention() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try post(runtime, ["action": "setTabMetadata", "bellAttention": true])

    let tab = try firstTab(from: runtime.state())
    XCTAssertEqual(tab["bellAttention"] as? Bool, true)

    let sessionsResponse = runtime.sessions()
    XCTAssertEqual(sessionsResponse.status, 200)
    let sessionsBody = try jsonObject(sessionsResponse)
    let sessions = sessionsBody["sessions"] as! [[String: Any]]
    XCTAssertEqual(sessions[0]["bellAttention"] as? Bool, true)
  }
}
