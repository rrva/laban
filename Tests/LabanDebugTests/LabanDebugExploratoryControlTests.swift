import Foundation
import XCTest

@testable import LabanDebug

final class LabanDebugExploratoryControlTests: XCTestCase {
  func testPixelProbeReturnsPointAndRegionData() throws {
    let (runtime, artifacts) = try makeRuntime("pixel-probe")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let body = """
      {"points":[{"x":1,"y":1}],"regions":[{"name":"corner","x":0,"y":0,"width":8,"height":8}]}
      """.data(using: .utf8)!
    let response = runtime.pixelProbe(body)
    XCTAssertEqual(response.status, 200)

    let obj = try json(response)
    XCTAssertGreaterThanOrEqual(obj["frame"] as? Int ?? -1, 1)
    XCTAssertEqual((obj["points"] as? [[String: Any]])?.count, 1)
    let regions = obj["regions"] as! [[String: Any]]
    XCTAssertEqual(regions.first?["name"] as? String, "corner")
    XCTAssertGreaterThan(regions.first?["sampledPixels"] as? Int ?? 0, 0)
  }

  func testTerminalLogRecordsDebugInputAndOutput() throws {
    let (runtime, artifacts) = try makeRuntime("terminal-log")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    _ = runtime.applyAction(#"{"action":"typeText","text":"hello log"}"#.data(using: .utf8)!)
    _ = runtime.applyAction(
      #"{"action":"feedOutput","text":"\u001b]0;LogTitle\u0007"}"#.data(using: .utf8)!)

    let response = runtime.terminalLogResponse(query: [:])
    XCTAssertEqual(response.status, 200)
    let obj = try json(response)
    let events = obj["events"] as! [[String: Any]]
    XCTAssertTrue(events.contains { $0["direction"] as? String == "input" })
    XCTAssertTrue(events.contains { $0["direction"] as? String == "output" })
    XCTAssertNotNil(obj["next"])
    XCTAssertEqual(obj["truncated"] as? Bool, false)
  }

  func testTimingAndErrorsEndpointsAreQueryable() throws {
    let (runtime, artifacts) = try makeRuntime("timing-errors")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let timing = try json(runtime.timingResponse())
    XCTAssertGreaterThanOrEqual(timing["frame"] as? Int ?? -1, 1)
    XCTAssertGreaterThanOrEqual(timing["lastFrameMs"] as? Double ?? -1, 0)
    XCTAssertGreaterThanOrEqual(timing["renderMs"] as? Double ?? -1, 0)

    _ = runtime.applyAction(Data("{}".utf8))
    let errors = try json(runtime.errors(since: 0))
    let entries = errors["errors"] as! [[String: Any]]
    XCTAssertTrue(entries.contains { $0["kind"] as? String == "action.invalid" })
  }

  func testArtifactSnapshotWritesDiagnosticBundle() throws {
    let (runtime, artifacts) = try makeRuntime("artifact-snapshot")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    _ = runtime.applyAction(#"{"action":"typeText","text":"snapshot text"}"#.data(using: .utf8)!)
    let response = runtime.artifactSnapshot()
    XCTAssertEqual(response.status, 200)

    let obj = try json(response)
    let manifestPath = obj["path"] as! String
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath))
    let dir = URL(fileURLWithPath: manifestPath).deletingLastPathComponent()
    for file in [
      "state.json", "sessions.json", "render.json", "frame-commands.json",
      "render-trace.json", "events.json", "input-log.json", "terminal-log.json",
      "errors.json", "timing.json", "screenshot.png",
    ] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path),
        "missing snapshot file \(file)")
    }
  }

  func testFixtureControlLoadStepAndRestart() throws {
    let (runtime, artifacts) = try makeRuntime("fixture-control")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let fixtureURL = artifacts.appendingPathComponent("fixture-control.fixture.json")
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try fixtureJSON(name: "fixture-control", text: "fixture hello").write(to: fixtureURL)

    let loadBody = try JSONSerialization.data(withJSONObject: [
      "action": "load",
      "path": fixtureURL.path,
    ])
    let load = try json(runtime.fixtureControl(loadBody))
    XCTAssertEqual(load["ok"] as? Bool, true)
    XCTAssertEqual(load["stepIndex"] as? Int, 0)

    let step = try json(runtime.fixtureControl(#"{"action":"step","count":1}"#.data(using: .utf8)!))
    XCTAssertEqual(step["ok"] as? Bool, true)
    XCTAssertEqual(step["stepIndex"] as? Int, 1)

    let wait = try json(
      runtime.wait(
        #"{"timeoutMs":500,"condition":{"kind":"textVisible","text":"fixture hello"}}"#
          .data(using: .utf8)!))
    XCTAssertEqual(wait["ok"] as? Bool, true)

    let restart = try json(runtime.fixtureControl(#"{"action":"restart"}"#.data(using: .utf8)!))
    XCTAssertEqual(restart["ok"] as? Bool, true)
    XCTAssertEqual(restart["stepIndex"] as? Int, 0)
  }

  private func makeRuntime(_ name: String) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-explore-\(name)-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: name
    )
    return (runtime, artifacts)
  }

  private func fixtureJSON(name: String, text: String) -> Data {
    Data(
      """
      {
        "name": "\(name)",
        "version": 1,
        "description": "test fixture",
        "initialSize": {"cols": 40, "rows": 8},
        "steps": [
          {"op": "writeBytes", "encoding": "utf8", "data": "\(text)"}
        ],
        "expect": {"containsText": ["\(text)"]}
      }
      """.utf8)
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
