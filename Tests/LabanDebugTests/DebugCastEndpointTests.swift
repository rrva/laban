import Foundation
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanDebug

final class DebugCastEndpointTests: XCTestCase {

  func testRecentCastBytesProducesValidV2CastForActiveTab() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cast-debug-\(UUID().uuidString)")
    let persistence = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cast-persistence-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: artifacts)
      try? FileManager.default.removeItem(at: persistence)
    }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-cast",
      persistenceBaseURL: persistence)

    let initialTab = try XCTUnwrap(runtime.model.tabs.first)
    let session = try XCTUnwrap(runtime.model.session(forTab: initialTab.id))
    XCTAssertEqual(session.feedOutput(Array("hello ".utf8)), 0)
    Thread.sleep(forTimeInterval: 0.02)
    XCTAssertEqual(session.feedOutput(Array("cast world\r\n".utf8)), 0)

    let result = runtime.recentCastBytes(seconds: 5, tabId: nil)
    guard case let .success(data, tabId, chunks, windowSeconds) = result else {
      XCTFail("expected .success, got \(result)")
      return
    }
    XCTAssertEqual(tabId, initialTab.id)
    XCTAssertEqual(chunks, 2)
    XCTAssertEqual(windowSeconds, 5)

    // Verify the bytes parse as v2 NDJSON with a sane header.
    let lines = String(data: data, encoding: .utf8)?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init) ?? []
    XCTAssertEqual(lines.count, 3, "header + 2 events")
    let header = try JSONSerialization.jsonObject(
      with: Data(lines[0].utf8)) as? [String: Any]
    XCTAssertEqual(header?["version"] as? Int, 2)
    XCTAssertNotNil(header?["width"])
    XCTAssertNotNil(header?["height"])

    let firstEvent = try JSONSerialization.jsonObject(
      with: Data(lines[1].utf8)) as? [Any]
    XCTAssertEqual(firstEvent?[1] as? String, "o")
    XCTAssertEqual(firstEvent?[2] as? String, "hello ")
  }

  func testRecentCastBytesFailsWithoutTranscriptHost() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cast-debug-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    // No persistence URL → no transcript host → no ring.
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "smoke-cast-no-host")

    let result = runtime.recentCastBytes(seconds: 5, tabId: nil)
    guard case let .failure(status, _) = result else {
      XCTFail("expected .failure, got \(result)")
      return
    }
    XCTAssertEqual(status, 400)
  }
}
