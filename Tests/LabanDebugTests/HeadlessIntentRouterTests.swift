import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

final class HeadlessIntentRouterTests: XCTestCase {
  func testHealthLegacyQueryReturnsJSONControlResponse() throws {
    let (runtime, artifacts) = try makeRuntime("router-health")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.query(LegacyDebugQueryInput(intentID: "debug.health"))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["ok"] as? Bool, true)
    XCTAssertEqual(body["mode"] as? String, "headless")
    XCTAssertNotNil(body["frame"])
  }

  func testEventsLegacyQueryUsesSinceParameter() throws {
    let (runtime, artifacts) = try makeRuntime("router-events")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let since = runtime.withRuntimeLock {
      let baseSeq = runtime.logs.eventSeq
      runtime.logs.appendEvent(EventEntry(kind: "before"))
      runtime.logs.appendEvent(EventEntry(kind: "after"))
      return baseSeq + 1
    }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.query(
      LegacyDebugQueryInput(intentID: "log.events", params: ["since": "\(since)"]))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    let events = try XCTUnwrap(body["events"] as? [[String: Any]])
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?["kind"] as? String, "after")
    XCTAssertEqual(body["next"] as? Int, since + 1)
  }

  private func makeRuntime(_ runId: String) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-headless-router-\(runId)-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: runId)
    return (runtime, artifacts)
  }

  private func json(_ response: ControlResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
