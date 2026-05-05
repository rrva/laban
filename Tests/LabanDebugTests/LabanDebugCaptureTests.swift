import Foundation
import XCTest

@testable import LabanDebug

final class LabanDebugCaptureTests: XCTestCase {
  func testCaptureDisabledByDefault() throws {
    let runtime = try runtime("disabled")
    let obj = try json(runtime.captureStatus())
    XCTAssertEqual(obj["active"] as? Bool, false)
  }

  func testStartStatusSnapshotAndStopCapture() throws {
    let runtime = try runtime("controls")
    let start = runtime.startCapture(
      #"{"name":"debug-capture","screenshots":"marked"}"#.data(using: .utf8)!)
    XCTAssertEqual(start.status, 200)
    let startObj = try json(start)
    XCTAssertEqual(startObj["active"] as? Bool, true)
    let dir = startObj["directory"] as! String
    XCTAssertTrue(dir.contains("/captures/debug-capture"))

    let active = try json(runtime.captureStatus())
    XCTAssertEqual(active["active"] as? Bool, true)

    _ = runtime.applyAction(#"{"action":"typeText","text":"hello capture"}"#.data(using: .utf8)!)
    let snapshot = runtime.captureSnapshot()
    XCTAssertEqual(snapshot.status, 200)
    let snapshotObj = try json(snapshot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotObj["path"] as! String))

    let stop = runtime.stopCapture()
    XCTAssertEqual(stop.status, 200)
    let stopObj = try json(stop)
    let manifest = stopObj["manifestPath"] as! String
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifest))
    XCTAssertEqual((try json(runtime.captureStatus()))["active"] as? Bool, false)
  }

  func testStartRejectsActiveCapture() throws {
    let runtime = try runtime("conflict")
    XCTAssertEqual(runtime.startCapture(#"{"name":"one"}"#.data(using: .utf8)!).status, 200)
    XCTAssertEqual(runtime.startCapture(#"{"name":"two"}"#.data(using: .utf8)!).status, 409)
  }

  func testCapturePathCannotEscapeArtifactRoot() throws {
    let runtime = try runtime("reject")
    let result = runtime.startCapture(#"{"name":"../escape"}"#.data(using: .utf8)!)
    XCTAssertEqual(result.status, 400)
  }

  func testShutdownMarksActiveCaptureInterrupted() throws {
    let runtime = try runtime("shutdown")
    let start = runtime.startCapture(
      #"{"name":"signal-capture","screenshots":"none"}"#.data(using: .utf8)!)
    XCTAssertEqual(start.status, 200)
    let startObj = try json(start)
    let dir = startObj["directory"] as! String

    runtime.shutdown(interrupted: true)

    let manifest = URL(fileURLWithPath: dir).appendingPathComponent("manifest.json")
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
    XCTAssertEqual(obj["interrupted"] as? Bool, true)
    XCTAssertEqual((try json(runtime.captureStatus()))["active"] as? Bool, false)
  }

  private func runtime(_ name: String) throws -> HeadlessDebugRuntime {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-capture-\(name)-\(UUID().uuidString)")
    return try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: name
    )
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
