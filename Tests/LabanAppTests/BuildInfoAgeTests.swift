import Foundation
import XCTest

@testable import LabanApp

final class BuildInfoAgeTests: XCTestCase {
  func testRelativeAgeBreaksDownDayHourMinuteAndDropsSeconds() {
    let interval: TimeInterval = (3 * 86_400) + (4 * 3_600) + (12 * 60) + 7
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: interval),
      "3 days, 4 hours, 12 minutes ago")
  }

  func testRelativeAgeKeepsZeroDayAndHourUnits() {
    let interval: TimeInterval = 12 * 60
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: interval),
      "0 days, 0 hours, 12 minutes ago")
  }

  func testRelativeAgeUnderOneMinuteReportsSeconds() {
    XCTAssertEqual(BuildInfo.relativeAge(seconds: 45), "45 seconds ago")
    XCTAssertEqual(BuildInfo.relativeAge(seconds: 1), "1 second ago")
    XCTAssertEqual(BuildInfo.relativeAge(seconds: 0), "0 seconds ago")
  }

  func testRelativeAgeAtOneMinuteSwitchesToMinutes() {
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: 60),
      "0 days, 0 hours, 1 minute ago")
  }

  func testRelativeAgeSingularPluralization() {
    let oneOfEach: TimeInterval = 86_400 + 3_600 + 60
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: oneOfEach),
      "1 day, 1 hour, 1 minute ago")
  }

  func testRelativeAgeRoundsFractionalSecondsUnderAMinute() {
    XCTAssertEqual(BuildInfo.relativeAge(seconds: 30.6), "31 seconds ago")
  }

  func testRelativeAgeClampsClockSkewToZero() {
    XCTAssertEqual(BuildInfo.relativeAge(seconds: -500), "0 seconds ago")
  }

  func testAgeDescriptionMeasuresAgainstNow() {
    // ISO-8601 stamps matching the build-app format, 2h30m15s apart. The
    // bundle under test carries no LABANBuildDate, so exercise the
    // parse+format path directly rather than through ageDescription().
    let built = ISO8601DateFormatter().date(from: "2026-05-30T10:00:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-05-30T12:30:15Z")!
    XCTAssertEqual(
      BuildInfo.relativeAge(seconds: now.timeIntervalSince(built)),
      "0 days, 2 hours, 30 minutes ago")
  }
}
