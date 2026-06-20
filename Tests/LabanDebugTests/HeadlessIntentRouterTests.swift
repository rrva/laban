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

  func testScreenshotArtifactReturnsPNGHeaders() throws {
    let (runtime, artifacts) = try makeRuntime("router-screenshot")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = try XCTUnwrap(
      router.artifact(ArtifactRequest(id: "artifact.screenshot")))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "image/png")
    XCTAssertNotNil(response.headers["X-App-Frame"])
    XCTAssertNotNil(response.headers["X-App-Size"])
    XCTAssertEqual(Array(response.body.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
  }

  func testRecentCastArtifactReturnsLegacyJSONFailureWhenPersistenceIsMissing() throws {
    let (runtime, artifacts) = try makeRuntime("router-cast")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = try XCTUnwrap(
      router.artifact(ArtifactRequest(id: "cast.recent", params: ["seconds": "1"])))

    XCTAssertEqual(response.status, 400)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["error"] as? String, "transcript host is not wired (use --persistence-dir)")
  }

  func testLegacyNoBodyControlReturnsJSONFromRuntime() throws {
    let (runtime, artifacts) = try makeRuntime("router-persistence-flush")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.control(LegacyDebugControlInput(intentID: "persistence.flush"))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["ok"] as? Bool, true)
  }

  func testLegacyMalformedBodyControlDelegatesToRuntimeError() throws {
    let (runtime, artifacts) = try makeRuntime("router-find-malformed")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.control(
      LegacyDebugControlInput(intentID: "find.start", body: Data(#"{"needle":"apple""#.utf8)))

    XCTAssertEqual(response.status, 400)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["error"] as? String, "invalid find.start request")
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
