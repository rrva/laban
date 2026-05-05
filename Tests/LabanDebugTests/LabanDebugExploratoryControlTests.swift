import Foundation
import XCTest

@testable import LabanDebug

final class LabanDebugExploratoryControlTests: XCTestCase {
  func testDiscoveryListsExploratoryControls() throws {
    let (runtime, artifacts) = try makeRuntime("discovery")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.discovery()
    XCTAssertEqual(response.status, 200)

    let obj = try json(response)
    XCTAssertEqual(obj["name"] as? String, "laban-debug")
    XCTAssertEqual(obj["schema"] as? String, "schemas/debug/discovery.schema.json")
    XCTAssertEqual(obj["runId"] as? String, "discovery")
    XCTAssertEqual(obj["mode"] as? String, "headless")
    XCTAssertGreaterThanOrEqual(obj["frame"] as? Int ?? -1, 1)
    XCTAssertEqual(obj["artifactRoot"] as? String, artifacts.path)
    XCTAssertNotNil(obj["fixtureRoot"] as? String)

    let entrypoints = obj["entrypoints"] as! [String]
    XCTAssertTrue(entrypoints.contains("/debug"))
    XCTAssertTrue(entrypoints.contains("/debug/capabilities"))

    let endpoints = obj["endpoints"] as! [[String: Any]]
    XCTAssertTrue(
      endpoints.contains {
        $0["method"] as? String == "POST" && $0["path"] as? String == "/debug/actions"
      })
    XCTAssertTrue(
      endpoints.contains {
        $0["method"] as? String == "POST" && $0["path"] as? String == "/debug/snapshot"
      })
    XCTAssertTrue(
      endpoints.contains {
        $0["method"] as? String == "POST" && $0["path"] as? String == "/debug/fixture"
      })
    XCTAssertTrue(
      endpoints.contains {
        $0["method"] as? String == "POST" && $0["path"] as? String == "/debug/pixel-probe"
      })

    let actions = obj["actions"] as! [[String: Any]]
    XCTAssertTrue(actions.contains { $0["name"] as? String == "typeText" })
    XCTAssertTrue(actions.contains { $0["name"] as? String == "key" })

    let waits = obj["waitConditions"] as! [[String: Any]]
    XCTAssertTrue(waits.contains { $0["name"] as? String == "textVisible" })

    let fixtureActions = obj["fixtureActions"] as! [[String: Any]]
    XCTAssertTrue(fixtureActions.contains { $0["name"] as? String == "restart" })
  }

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
    let artifacts = tempArtifacts("fixture-control")
    let fixtureRoot = artifacts.appendingPathComponent("fixtures", isDirectory: true)
    let (runtime, _) = try makeRuntime(
      "fixture-control", artifactsURL: artifacts, fixtureRootURL: fixtureRoot)
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let fixtureURL = fixtureRoot.appendingPathComponent("fixture-control.fixture.json")
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    try fixtureJSON(name: "fixture-control", text: "fixture hello").write(to: fixtureURL)

    let loadBody = try JSONSerialization.data(withJSONObject: [
      "action": "load",
      "path": "fixture-control.fixture.json",
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

  func testFixtureControlRejectsAbsoluteTraversalAndSymlinkPaths() throws {
    let artifacts = tempArtifacts("fixture-paths")
    let fixtureRoot = artifacts.appendingPathComponent("fixtures", isDirectory: true)
    let (runtime, _) = try makeRuntime(
      "fixture-paths", artifactsURL: artifacts, fixtureRootURL: fixtureRoot)
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let outside = artifacts.appendingPathComponent("outside.fixture.json")
    try fixtureJSON(name: "outside", text: "outside").write(to: outside)

    let absolute = try fixtureLoad(runtime, path: outside.path)
    XCTAssertEqual(absolute.status, 400)
    XCTAssertEqual(absolute.body["ok"] as? Bool, false)

    let traversal = try fixtureLoad(runtime, path: "../outside.fixture.json")
    XCTAssertEqual(traversal.status, 400)
    XCTAssertEqual(traversal.body["ok"] as? Bool, false)

    let link = fixtureRoot.appendingPathComponent("link.fixture.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let symlink = try fixtureLoad(runtime, path: "link.fixture.json")
    XCTAssertEqual(symlink.status, 400)
    XCTAssertEqual(symlink.body["ok"] as? Bool, false)
  }

  private func tempArtifacts(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-explore-\(name)-\(UUID().uuidString)")
  }

  private func makeRuntime(
    _ name: String,
    artifactsURL: URL? = nil,
    fixtureRootURL: URL? = nil
  ) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = artifactsURL ?? tempArtifacts(name)
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: name,
      fixtureRootURL: fixtureRootURL
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

  private func fixtureLoad(_ runtime: HeadlessDebugRuntime, path: String) throws
    -> (status: Int, body: [String: Any])
  {
    let body = try JSONSerialization.data(withJSONObject: ["action": "load", "path": path])
    let response = runtime.fixtureControl(body)
    return (response.status, try json(response))
  }
}
