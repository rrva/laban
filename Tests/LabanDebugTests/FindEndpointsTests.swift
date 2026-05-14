import Foundation
import XCTest

@testable import LabanDebug

final class FindEndpointsTests: XCTestCase {
  func testStartFindReturnsMatchesAndFrameCommands() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }
    try apply(runtime, ["action": "feedOutput", "text": "apple\nbanana\napple pie\n"])

    let response = runtime.findStart(Data(#"{"needle":"apple"}"#.utf8))
    XCTAssertEqual(response.status, 200)
    let body = try json(response)
    XCTAssertEqual(body["isActive"] as? Bool, true)
    XCTAssertEqual(body["total"] as? Int, 2)
    XCTAssertEqual(body["selectedIndex"] as? Int, 0)

    let commands = try json(runtime.frameCommands(query: ["source": "find"]))
    let kinds = (commands["commands"] as! [[String: Any]]).compactMap { $0["kind"] as? String }
    XCTAssertTrue(kinds.contains("findSelected"))
    XCTAssertTrue(kinds.contains("findMatch"))
  }

  func testStepNextAndPreviousWrap() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }
    try apply(runtime, ["action": "feedOutput", "text": "apple apple\n"])
    _ = runtime.findStart(Data(#"{"needle":"apple"}"#.utf8))

    var response = runtime.findStep(Data(#"{"direction":"previous"}"#.utf8))
    XCTAssertEqual(try json(response)["selectedIndex"] as? Int, 1)
    response = runtime.findStep(Data(#"{"direction":"next"}"#.utf8))
    XCTAssertEqual(try json(response)["selectedIndex"] as? Int, 0)
  }

  func testStopClearsState() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }
    try apply(runtime, ["action": "feedOutput", "text": "apple\n"])
    _ = runtime.findStart(Data(#"{"needle":"apple"}"#.utf8))

    let stop = runtime.findStop(Data("{}".utf8))
    XCTAssertEqual(try json(stop)["stopped"] as? Bool, true)
    let state = try json(runtime.findState(query: [:]))
    XCTAssertEqual(state["isActive"] as? Bool, false)
  }

  func testStartRejectsEmptyNeedle() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.findStart(Data(#"{"needle":""}"#.utf8))

    XCTAssertEqual(response.status, 400)
  }

  func testStartOnMissingSessionReturns404() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.findStart(Data(#"{"sessionID":"missing","needle":"apple"}"#.utf8))

    XCTAssertEqual(response.status, 404)
  }

  func testActionVariantsDriveFind() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }
    try apply(runtime, ["action": "feedOutput", "text": "apple apple\n"])

    let start = runtime.applyAction(Data(#"{"action":"find.start","needle":"apple"}"#.utf8))
    XCTAssertEqual(try json(start)["total"] as? Int, 2)
    let step = runtime.applyAction(Data(#"{"action":"find.step","direction":"next"}"#.utf8))
    XCTAssertEqual(try json(step)["selectedIndex"] as? Int, 1)
    let stop = runtime.applyAction(Data(#"{"action":"find.stop"}"#.utf8))
    XCTAssertEqual(try json(stop)["stopped"] as? Bool, true)
  }

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-find-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "find-tests"
    )
    return (runtime, artifacts)
  }

  private func apply(_ runtime: HeadlessDebugRuntime, _ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    let response = runtime.applyAction(data)
    XCTAssertEqual(response.status, 200)
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
