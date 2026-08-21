import Foundation
import XCTest

@testable import LabanApp

final class SparkleUpdatePolicyTests: XCTestCase {
  private func configured(_ values: [String: String?]) -> Bool {
    SparkleUpdatePolicy.isConfigured(infoValue: { values[$0] ?? nil })
  }

  func testConfiguredWhenFeedAndKeyPresent() {
    XCTAssertTrue(
      configured([
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": "cHVibGljLWtleQ==",
      ]))
  }

  func testNotConfiguredWhenFeedMissing() {
    // Dev builds (scripts/build-app without LABAN_SPARKLE_FEED_URL) stamp
    // neither key and must never contact the release feed.
    XCTAssertFalse(configured([:]))
    XCTAssertFalse(configured(["SUPublicEDKey": "cHVibGljLWtleQ=="]))
  }

  func testNotConfiguredWhenKeyMissing() {
    XCTAssertFalse(configured(["SUFeedURL": "https://example.com/appcast.xml"]))
  }

  func testNotConfiguredWhenValuesBlank() {
    XCTAssertFalse(
      configured([
        "SUFeedURL": "  ",
        "SUPublicEDKey": "\n",
      ]))
  }
}
