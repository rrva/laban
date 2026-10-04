import Foundation
import XCTest

@testable import LabanDebug

final class CloseConfirmationEndpointTests: XCTestCase {
  func testIdleTabDoesNotAsk() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let state = try json(runtime.closeConfirmationState(query: [:]))
    XCTAssertEqual(state["scope"] as? String, "tab")
    XCTAssertEqual(state["asks"] as? Bool, false)
    let panes = try XCTUnwrap(state["panes"] as? [[String: Any]])
    XCTAssertEqual(panes.count, 1)
    XCTAssertEqual(panes.first?["busy"] as? Bool, false)
    XCTAssertNil(state["dialog"] as? [String: Any])
  }

  func testEveryScopeAnswers() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    for scope in ["pane", "tab", "window", "quit"] {
      let response = runtime.closeConfirmationState(query: ["scope": scope])
      XCTAssertEqual(response.status, 200, scope)
      XCTAssertEqual(try json(response)["scope"] as? String, scope)
    }
  }

  func testRejectsUnknownScopeAndSession() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    XCTAssertEqual(runtime.closeConfirmationState(query: ["scope": "app"]).status, 400)
    XCTAssertEqual(runtime.closeConfirmationState(query: ["sessionID": "missing"]).status, 404)
    XCTAssertEqual(runtime.closeConfirmationState(query: ["tabId": "missing"]).status, 404)
  }

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-closeconfirm-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "close-confirmation-tests"
    )
    return (runtime, artifacts)
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
