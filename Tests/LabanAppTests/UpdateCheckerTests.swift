import Foundation
import XCTest

@testable import LabanApp

final class UpdateCheckerTests: XCTestCase {
  func testDecodesExistingLatestLinkManifestShape() throws {
    let data = Data(
      """
      {
        "latest": "1.2.3",
        "link": "https://example.com/Laban-1.2.3.zip",
        "notes": "Manual download only."
      }
      """.utf8)

    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

    XCTAssertEqual(manifest.latest, "1.2.3")
    XCTAssertEqual(manifest.downloadURL.absoluteString, "https://example.com/Laban-1.2.3.zip")
    XCTAssertEqual(manifest.notes, "Manual download only.")
  }

  func testNumericVersionComparisonHandlesMultiDigitComponents() {
    XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.9"))
    XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.2"))
    XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
  }

  func testManifestRejectsNonWebDownloadURL() {
    let data = Data(
      """
      {"latest":"1.2.3","link":"file:///Applications/Laban.app"}
      """.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(UpdateManifest.self, from: data))
  }

  func testEvaluateReportsAvailableWhenManifestIsNewer() throws {
    let data = Data(
      """
      {"latest":"2.0.0","link":"https://example.com/Laban-2.0.0.zip"}
      """.utf8)

    XCTAssertEqual(
      try UpdateChecker.evaluate(data: data, currentVersion: "1.9.0"),
      .available(
        UpdateManifest(
          latest: "2.0.0",
          downloadURL: URL(string: "https://example.com/Laban-2.0.0.zip")!,
          notes: nil))
    )
  }

  func testEvaluateReportsCurrentWhenManifestIsNotNewer() throws {
    let data = Data(
      """
      {"latest":"1.9.0","link":"https://example.com/Laban-1.9.0.zip"}
      """.utf8)

    XCTAssertEqual(
      try UpdateChecker.evaluate(data: data, currentVersion: "2.0.0"),
      .upToDate(
        UpdateManifest(
          latest: "1.9.0",
          downloadURL: URL(string: "https://example.com/Laban-1.9.0.zip")!,
          notes: nil))
    )
  }
}
