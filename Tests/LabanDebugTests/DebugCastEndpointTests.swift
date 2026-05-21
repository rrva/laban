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
    guard case .success(let data, let tabId, let chunks, let windowSeconds) = result else {
      XCTFail("expected .success, got \(result)")
      return
    }
    XCTAssertEqual(tabId, initialTab.id)
    XCTAssertEqual(chunks, 2)
    XCTAssertEqual(windowSeconds, 5)

    // Verify the bytes parse as v2 NDJSON with a sane header.
    let lines =
      String(data: data, encoding: .utf8)?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init) ?? []
    XCTAssertEqual(lines.count, 3, "header + 2 events")
    let header =
      try JSONSerialization.jsonObject(
        with: Data(lines[0].utf8)) as? [String: Any]
    XCTAssertEqual(header?["version"] as? Int, 2)
    XCTAssertNotNil(header?["width"])
    XCTAssertNotNil(header?["height"])

    let firstEvent =
      try JSONSerialization.jsonObject(
        with: Data(lines[1].utf8)) as? [Any]
    XCTAssertEqual(firstEvent?[1] as? String, "o")
    XCTAssertEqual(firstEvent?[2] as? String, "hello ")
  }

  func testRecentCastBytesStartsWithFullFrameSnapshotWhenWindowOnlyHasDelta() throws {
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
      runId: "smoke-cast-full-frame",
      persistenceBaseURL: persistence)

    let initialTab = try XCTUnwrap(runtime.model.tabs.first)
    let session = try XCTUnwrap(runtime.model.session(forTab: initialTab.id))
    XCTAssertEqual(
      session.feedOutput(Array("\u{1B}[2J\u{1B}[Halpha\r\nbeta".utf8)),
      0)

    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(session.feedOutput(Array("\u{1B}[2;5H!".utf8)), 0)

    let result = runtime.recentCastBytes(seconds: 0.02, tabId: nil)
    guard case .success(let data, _, let chunks, _) = result else {
      XCTFail("expected .success, got \(result)")
      return
    }
    XCTAssertEqual(chunks, 1, "metadata should count recorded PTY chunks, not the synthetic frame")

    let lines =
      String(data: data, encoding: .utf8)?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init) ?? []
    XCTAssertEqual(lines.count, 3, "header + synthetic full frame + partial PTY delta")

    let seedEvent = try parseEvent(lines[1])
    XCTAssertEqual(seedEvent.0, 0.0, accuracy: 1e-9)
    XCTAssertEqual(seedEvent.1, "o")
    XCTAssertTrue(seedEvent.2.contains("\u{1B}[2J"), seedEvent.2.debugDescription)
    XCTAssertTrue(seedEvent.2.contains("alpha"), seedEvent.2.debugDescription)
    XCTAssertTrue(seedEvent.2.contains("beta"), seedEvent.2.debugDescription)
    XCTAssertFalse(seedEvent.2.contains("beta!"), seedEvent.2.debugDescription)

    guard lines.count > 2 else { return }
    let deltaEvent = try parseEvent(lines[2])
    XCTAssertGreaterThan(deltaEvent.0, 0.0)
    XCTAssertEqual(deltaEvent.1, "o")
    XCTAssertTrue(deltaEvent.2.contains("\u{1B}[2;5H!"), deltaEvent.2.debugDescription)
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
    guard case .failure(let status, _) = result else {
      XCTFail("expected .failure, got \(result)")
      return
    }
    XCTAssertEqual(status, 400)
  }

  private func parseEvent(_ line: String) throws -> (Double, String, String) {
    let arr = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any]
    let time = (arr?[0] as? NSNumber)?.doubleValue ?? -1
    let kind = arr?[1] as? String ?? ""
    let payload = arr?[2] as? String ?? ""
    return (time, kind, payload)
  }
}
