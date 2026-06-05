import Foundation
import XCTest

@testable import LabanApp

final class IdleCountersTests: XCTestCase {
  func testIdleCountersAreDisabledByDefault() {
    let suiteName = "IdleCountersTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(IdleCounters.isEnabled(defaults: defaults, environment: [:]))
  }

  func testIdleCountersCanBeEnabledByDefaultsOrEnvironment() {
    let suiteName = "IdleCountersTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: IdleCounters.enabledDefaultKey)
    XCTAssertTrue(IdleCounters.isEnabled(defaults: defaults, environment: [:]))
    XCTAssertTrue(
      IdleCounters.isEnabled(
        defaults: defaults,
        environment: [IdleCounters.enabledEnvironmentKey: "1"]))
    XCTAssertFalse(
      IdleCounters.isEnabled(
        defaults: defaults,
        environment: [IdleCounters.enabledEnvironmentKey: "0"]))
  }

  func testDisabledCountersDoNotCreateSidecar() {
    let suiteName = "IdleCountersTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("IdleCountersTests.\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent(IdleCounters.sidecarFileName)
    defer { try? FileManager.default.removeItem(at: dir) }

    _ = IdleCounters(defaults: defaults, environment: [:], sidecarURL: url, startsTimer: false)

    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testEnabledCountersWritePrivacySafeSidecarLine() throws {
    let suiteName = "IdleCountersTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("IdleCountersTests.\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent(IdleCounters.sidecarFileName)
    defer { try? FileManager.default.removeItem(at: dir) }

    let counters = IdleCounters(
      defaults: defaults,
      environment: [IdleCounters.enabledEnvironmentKey: "1"],
      sidecarURL: url,
      startsTimer: false)
    counters.noteDisplayLinkTick()
    counters.noteDisplayLinkTick()
    counters.noteAdvanceFrame()
    counters.noteLabptyPoll(byteCount: 0)
    counters.noteLabptyPoll(byteCount: 5)
    counters.noteLabptyFeedStarted()
    counters.flushForTesting()

    let contents = try String(contentsOf: url, encoding: .utf8)
    let lines = contents.split(separator: "\n")
    XCTAssertEqual(lines.count, 1)
    let data = Data(lines[0].utf8)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(object["kind"] as? String, "idle.counters")
    XCTAssertEqual(object["seq"] as? Int, 1)
    XCTAssertEqual(object["displayLinkTicks"] as? Int, 2)
    XCTAssertEqual(object["advanceFrames"] as? Int, 1)
    XCTAssertEqual(object["labptyPolls"] as? Int, 2)
    XCTAssertEqual(object["emptyLabptyPolls"] as? Int, 1)
    XCTAssertEqual(object["dirtyLabptyPolls"] as? Int, 1)
    XCTAssertEqual(object["activeFeeds"] as? Int, 1)
    XCTAssertNotNil(object["ts"] as? String)
    XCTAssertNotNil(object["tMs"] as? Int)
    XCTAssertNotNil(object["pid"] as? Int)

    XCTAssertNil(object["tabId"])
    XCTAssertNil(object["sessionId"])
    XCTAssertNil(object["path"])
    XCTAssertNil(object["environment"])
    XCTAssertNil(object["terminalText"])
  }
}
