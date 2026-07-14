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

  func testNotificationStateReportsNativeUnavailable() throws {
    let (runtime, artifacts) = try makeRuntime("router-notifications-state")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.query(
      LegacyDebugQueryInput(intentID: "notifications.state"))

    XCTAssertEqual(response.status, 200)
    let snapshot = try JSONDecoder().decode(
      NativeNotificationDiagnosticsSnapshot.self, from: response.body)
    XCTAssertFalse(snapshot.nativeAvailable)
    XCTAssertNil(snapshot.identity)
    XCTAssertTrue(snapshot.events.isEmpty)
    XCTAssertEqual(snapshot.focusAuthorizationStatus, .unavailable)
    XCTAssertNil(snapshot.focusSuppressesNotifications)
    XCTAssertNil(snapshot.focusCheckedAt)
  }

  func testNotificationTestReturnsUnavailable() throws {
    let (runtime, artifacts) = try makeRuntime("router-notifications-test")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let response = router.control(
      LegacyDebugControlInput(
        intentID: "notifications.test",
        body: Data("{}".utf8)))

    XCTAssertEqual(response.status, 409)
    let body = try json(response)
    XCTAssertEqual(body["error"] as? String, "native notifications unavailable in headless mode")
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

  func testLegacyDebugActionReturnsActionResultForTabAction() throws {
    let (runtime, artifacts) = try makeRuntime("router-new-tab")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    let body = Data(#"{"action":"newTab"}"#.utf8)
    let response = router.route(
      .legacyDebugAction(LegacyDebugActionInput(intentID: "tab.new", action: "newTab", body: body)))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body0 = try json(response)
    XCTAssertEqual(body0["ok"] as? Bool, true)
    XCTAssertNotNil(body0["frame"])
    XCTAssertNil(body0["mouseTracking"])
    XCTAssertNil(body0["sent"])
  }

  func testLegacyDebugActionPreservesMouseActionResultWire() throws {
    let (runtime, artifacts) = try makeRuntime("router-mouse-wheel")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)

    // Enable SGR mouse tracking so the wheel takes the tracked-forward path that
    // returns MouseActionResult (mouseTracking + sent), mirroring the legacy
    // /debug/actions server.
    let enableBody = try JSONSerialization.data(
      withJSONObject: ["action": "feedOutput", "text": "\u{1B}[?1000h\u{1B}[?1006h"])
    _ = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "fixture.feedOutput", action: "feedOutput", body: enableBody)))

    let wheelBody = try JSONSerialization.data(
      withJSONObject: ["action": "mouseWheel", "x": 300, "y": 200, "deltaY": 3])
    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "terminal.mouseWheel", action: "mouseWheel", body: wheelBody)))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentType, "application/json")
    let body = try json(response)
    XCTAssertEqual(body["ok"] as? Bool, true)
    XCTAssertEqual(body["mouseTracking"] as? Bool, true)
    XCTAssertEqual(body["sent"] as? Bool, true)
  }

  func testHeadlessRouterHandlesEverySharedOpNonError() throws {
    let (runtime, artifacts) = try makeRuntime("router-parity")
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let router = HeadlessIntentRouter(runtime: runtime)
    let tabId = runtime.model.activeTab?.id ?? ""

    XCTAssertLessThan(router.query(.state).status, 400)

    let shared: [(intentID: String, action: String, body: Data)] = [
      ("tab.select", "selectTab", Data(#"{"action":"selectTab","tabId":"\#(tabId)"}"#.utf8)),
      ("terminal.typeText", "typeText", Data(#"{"action":"typeText","text":"parity"}"#.utf8)),
      ("terminal.sendKey", "key", Data(#"{"action":"key","key":"a"}"#.utf8)),
    ]
    for op in shared {
      let response = router.route(
        .legacyDebugAction(
          LegacyDebugActionInput(intentID: op.intentID, action: op.action, body: op.body)))
      XCTAssertLessThan(response.status, 400, op.intentID)
    }
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
