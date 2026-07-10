import Foundation
import XCTest

@testable import LabanDebug

final class GetTextEndpointTests: XCTestCase {
  func testScreenSourceDefaultsToOwnActiveSessionAndFullGrid() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let state = try json(runtime.state())
    let tabs = try XCTUnwrap(state["tabs"] as? [[String: Any]])
    let activeSessionId = try XCTUnwrap(
      tabs.first { $0["active"] as? Bool == true }?["sessionId"] as? String)

    try feed(runtime, "hello\r\nworld\r\n")

    let response = try json(runtime.getText(query: [:]))
    XCTAssertEqual(response["ok"] as? Bool, true)
    XCTAssertEqual(response["source"] as? String, "screen")
    XCTAssertEqual(response["truncated"] as? Bool, false)
    let lines = try linesOf(response)
    // The screen source is a full 24-row grid (blank-padded), never fewer rows
    // than the terminal's configured height.
    XCTAssertEqual(lines.count, 24)
    XCTAssertEqual(response["totalAvailable"] as? Int, 24)
    // fullGrid mode pads each row out to the full column width, so match by
    // trimmed content rather than exact row equality.
    let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    XCTAssertTrue(trimmedLines.contains("hello"))
    XCTAssertTrue(trimmedLines.contains("world"))
    // "sessionId" is intentionally lowercase-d, diverging from an initial
    // "sessionID" reading of the brief, to match every other response struct
    // in ControlResponseModels.swift.
    let idKey = response["sessionId"] as? String
    XCTAssertEqual(idKey, activeSessionId)
  }

  func testScrollbackSourceBoundsSliceWithStartAndEndLine() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, numberedLines(count: 10))

    let response = try json(
      runtime.getText(query: ["source": "scrollback", "startLine": "2", "endLine": "4"]))
    XCTAssertEqual(response["ok"] as? Bool, true)
    XCTAssertEqual(response["truncated"] as? Bool, false)
    let lines = try linesOf(response)
    XCTAssertEqual(lines, ["line0002", "line0003", "line0004"])
  }

  func testScrollbackSourceTruncatesAtDefaultFiveHundredLines() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, numberedLines(count: 600))

    let response = try json(runtime.getText(query: ["source": "scrollback"]))
    XCTAssertEqual(response["ok"] as? Bool, true)
    XCTAssertEqual(response["truncated"] as? Bool, true)
    let lines = try linesOf(response)
    XCTAssertEqual(lines.count, 500)
    XCTAssertEqual(lines.first, "line0000")
    XCTAssertEqual(lines.last, "line0499")
    let totalAvailable = try XCTUnwrap(response["totalAvailable"] as? Int)
    XCTAssertGreaterThan(totalAvailable, 500)
  }

  func testScrollbackSourceHardCapsAtTwoThousandLinesEvenWhenMoreAreRequested() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, numberedLines(count: 2200))

    let response = try json(
      runtime.getText(query: ["source": "scrollback", "maxLines": "5000"]))
    XCTAssertEqual(response["ok"] as? Bool, true)
    XCTAssertEqual(response["truncated"] as? Bool, true)
    let lines = try linesOf(response)
    XCTAssertEqual(lines.count, 2000)
    XCTAssertEqual(lines.first, "line0000")
    let totalAvailable = try XCTUnwrap(response["totalAvailable"] as? Int)
    XCTAssertGreaterThan(totalAvailable, 2000)
  }

  func testRequestedRangeWithinBoundsIsNotMarkedTruncated() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    try feed(runtime, numberedLines(count: 600))

    // A caller-narrowed startLine/endLine window is not truncation, only the
    // maxLines/hard-cap bound cutting the result short counts as truncated.
    let response = try json(
      runtime.getText(
        query: ["source": "scrollback", "startLine": "0", "endLine": "9", "maxLines": "50"]))
    XCTAssertEqual(response["truncated"] as? Bool, false)
    let lines = try linesOf(response)
    XCTAssertEqual(lines.count, 10)
  }

  func testInvalidSourceReturns400() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.getText(query: ["source": "bogus"])
    XCTAssertEqual(response.status, 400)
  }

  func testNegativeMaxLinesReturns400() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.getText(query: ["maxLines": "-1"])
    XCTAssertEqual(response.status, 400)
  }

  func testMissingSessionReturns404() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.getText(query: ["sessionId": "missing"])
    XCTAssertEqual(response.status, 404)
  }

  // MARK: - Helpers

  private func makeRuntime() throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-gettext-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "gettext-tests"
    )
    return (runtime, artifacts)
  }

  private func feed(_ runtime: HeadlessDebugRuntime, _ text: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["action": "feedOutput", "text": text])
    let response = runtime.applyAction(data)
    XCTAssertEqual(response.status, 200)
  }

  /// Builds `count` distinct, zero-padded numbered lines ("line0000\r\n", ...)
  /// short enough to never soft-wrap in an 80-column terminal, so each fed
  /// line consumes exactly one screen row.
  private func numberedLines(count: Int) -> String {
    var text = ""
    text.reserveCapacity(count * 12)
    for i in 0..<count {
      text += String(format: "line%04d\r\n", i)
    }
    return text
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }

  private func linesOf(_ response: [String: Any]) throws -> [String] {
    try XCTUnwrap(response["lines"] as? [String])
  }
}
