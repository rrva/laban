import Foundation
import LabanDebug
import XCTest

final class LabanDebugSmokeTests: XCTestCase {

  // MARK: - HTTP server address parsing

  func testAddressParseLoopback() throws {
    let addr = try DebugServerAddress.parse("127.0.0.1:9999")
    XCTAssertEqual(addr.host, "127.0.0.1")
    XCTAssertEqual(addr.port, 9999)
  }

  func testAddressParseLocalhost() throws {
    let addr = try DebugServerAddress.parse("localhost:0")
    XCTAssertEqual(addr.host, "localhost")
    XCTAssertEqual(addr.port, 0)
  }

  func testAddressRejectsPublicHost() {
    XCTAssertThrowsError(try DebugServerAddress.parse("0.0.0.0:9999"))
    XCTAssertThrowsError(try DebugServerAddress.parse("192.168.1.1:9999"))
  }

  func testAddressRejectsMalformed() {
    XCTAssertThrowsError(try DebugServerAddress.parse("noport"))
    XCTAssertThrowsError(try DebugServerAddress.parse("127.0.0.1:notanumber"))
  }

  // MARK: - HeadlessDebugRuntime smoke (no fixture, no HTTP)

  func testRuntimeHealthNoFixture() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-no-fixture"
    )

    let health = runtime.health()
    XCTAssertEqual(health.status, 200)
    let obj = try JSONSerialization.jsonObject(with: health.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
    XCTAssertEqual(obj["mode"] as? String, "headless")
    XCTAssertNotNil(obj["frame"])
  }

  func testRuntimeStateHasOneTab() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-state"
    )

    let state = runtime.state()
    XCTAssertEqual(state.status, 200)
    let obj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = obj["tabs"] as! [[String: Any]]
    XCTAssertEqual(tabs.count, 1)
    XCTAssertNotNil(obj["activeTabId"])
    XCTAssertNotNil(obj["activeSessionId"])
  }

  func testRuntimeScreenshotNonEmpty() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-screenshot"
    )

    let (data, frame, width, height) = try runtime.screenshotBytes()
    XCTAssertGreaterThan(data.count, 0)
    XCTAssertGreaterThan(frame, 0)
    XCTAssertGreaterThan(width, 0)
    XCTAssertGreaterThan(height, 0)
  }

  func testRuntimeNewTabAction() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-newtab"
    )

    let body = #"{"action":"newTab"}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)

    let state = runtime.state()
    let stateObj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = stateObj["tabs"] as! [[String: Any]]
    XCTAssertEqual(tabs.count, 2)
  }

  func testRuntimeFrameCommandsHasCommands() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-cmds"
    )

    let resp = runtime.frameCommands(query: ["source": "all", "limit": "100"])
    XCTAssertEqual(resp.status, 200)
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    let cmds = obj["commands"] as! [[String: Any]]
    XCTAssertGreaterThan(cmds.count, 0)
    XCTAssertNotNil(obj["truncated"])
  }

  func testRuntimeRenderTraceHasRequiredFields() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-trace"
    )

    let resp = runtime.renderTrace(Data())
    XCTAssertEqual(resp.status, 200)
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    for key in [
      "traceId", "frame", "backend", "surface", "sources", "layout",
      "packets", "commandRanges", "commands", "resources", "passes",
      "pixelProbes", "invariants", "truncated",
    ] {
      XCTAssertNotNil(obj[key], "missing required field: \(key)")
    }
  }

  func testRuntimeEventsContainsServerReady() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-events"
    )
    runtime.emitServerReady()

    let resp = runtime.events(since: 0)
    let obj = try JSONSerialization.jsonObject(with: resp.body) as! [String: Any]
    let events = obj["events"] as! [[String: Any]]
    let kinds = events.compactMap { $0["kind"] as? String }
    XCTAssertTrue(kinds.contains("server.ready"), "expected server.ready in \(kinds)")
    XCTAssertTrue(kinds.contains("frame.rendered"), "expected frame.rendered in \(kinds)")
    XCTAssertNotNil(obj["next"])
  }

  func testRuntimeUnsupportedActionReturnsOkFalse() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-unsupported"
    )

    let body = #"{"action":"mouseWheel","x":100,"y":100,"deltaY":-3}"#.data(using: .utf8)!
    let result = runtime.applyAction(body)
    XCTAssertEqual(result.status, 200)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, false)
    XCTAssertNotNil(obj["error"])
  }

  func testRuntimeWaitFrameAtLeast() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-wait"
    )

    let body = #"{"timeoutMs":500,"condition":{"kind":"frameAtLeast","frame":1}}"#.data(
      using: .utf8)!
    let result = runtime.wait(body)
    let obj = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    XCTAssertEqual(obj["ok"] as? Bool, true)
  }
}
