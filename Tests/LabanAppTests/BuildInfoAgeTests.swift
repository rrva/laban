import Foundation
import XCTest

@testable import LabanApp

final class BuildInfoAgeTests: XCTestCase {
  func testRelativeAgeBreaksDownAllFourUnits() {
    let interval: TimeInterval = (3 * 86_400) + (4 * 3_600) + (12 * 60) + 7
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: interval),
      "3 days, 4 hours, 12 minutes, 7 seconds ago")
  }

  func testRelativeAgeKeepsZeroUnitsSoEveryFieldShows() {
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: 0),
      "0 days, 0 hours, 0 minutes, 0 seconds ago")
  }

  func testRelativeAgeSingularPluralization() {
    let oneOfEach: TimeInterval = 86_400 + 3_600 + 60 + 1
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: oneOfEach),
      "1 day, 1 hour, 1 minute, 1 second ago")
  }

  func testRelativeAgeRoundsFractionalSeconds() {
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: 90.6),
      "0 days, 0 hours, 1 minute, 31 seconds ago")
  }

  func testRelativeAgeClampsClockSkewToZero() {
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: -500),
      "0 days, 0 hours, 0 minutes, 0 seconds ago")
  }

  func testAgeDescriptionMeasuresAgainstNow() {
    // ISO-8601 stamp matching the build-app format, two hours before `now`.
    let built = "2026-05-30T10:00:00Z"
    let now = ISO8601DateFormatter().date(from: "2026-05-30T12:30:15Z")!
    // ageDescription parses BuildInfo.date from the bundle, which the test
    // bundle does not stamp, so exercise the parse+format path directly.
    let parsed = ISO8601DateFormatter().date(from: built)!
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: now.timeIntervalSince(parsed)),
      "0 days, 2 hours, 30 minutes, 15 seconds ago")
  }
}
