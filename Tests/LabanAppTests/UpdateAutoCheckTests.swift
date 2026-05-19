import Foundation
import XCTest

@testable import LabanApp

final class UpdateAutoCheckTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testSkipsUnstampedDevBuild() {
    XCTAssertEqual(
      UpdateAutoCheck.decide(
        version: "0.0.0",
        manifestURLConfigured: true,
        lastCheck: nil,
        now: now),
      .skip(.unstampedDevBuild))
  }

  func testSkipsWhenManifestURLMissing() {
    XCTAssertEqual(
      UpdateAutoCheck.decide(
        version: "0.4.12",
        manifestURLConfigured: false,
        lastCheck: nil,
        now: now),
      .skip(.manifestURLMissing))
  }

  func testSkipsWhenLastCheckIsRecent() {
    let recent = now.addingTimeInterval(-60)
    XCTAssertEqual(
      UpdateAutoCheck.decide(
        version: "0.4.12",
        manifestURLConfigured: true,
        lastCheck: recent,
        now: now),
      .skip(.checkedRecently))
  }

  func testChecksWhenLastCheckIsOlderThanInterval() {
    let stale = now.addingTimeInterval(-(UpdateAutoCheck.pollInterval + 1))
    XCTAssertEqual(
      UpdateAutoCheck.decide(
        version: "0.4.12",
        manifestURLConfigured: true,
        lastCheck: stale,
        now: now),
      .check)
  }

  func testChecksOnFirstLaunchWithNoPriorCheck() {
    XCTAssertEqual(
      UpdateAutoCheck.decide(
        version: "0.4.12",
        manifestURLConfigured: true,
        lastCheck: nil,
        now: now),
      .check)
  }

  func testRoundTripsLastCheckThroughUserDefaults() throws {
    let suite = UserDefaults(suiteName: "UpdateAutoCheckTests-\(UUID().uuidString)")!
    XCTAssertNil(UpdateAutoCheck.loadLastCheck(defaults: suite))
    UpdateAutoCheck.recordCheck(now, defaults: suite)
    let restored = try XCTUnwrap(UpdateAutoCheck.loadLastCheck(defaults: suite))
    XCTAssertEqual(restored.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
  }
}
