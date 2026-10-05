import Foundation
import XCTest

@testable import LabanCore

final class PersistenceStoreBaseURLTests: XCTestCase {
  func testSupportDirOverrideReplacesApplicationSupportRoot() {
    let url = PersistenceStore.defaultBaseURL(
      environment: ["LABAN_SUPPORT_DIR": "/tmp/laban-shot"])
    XCTAssertEqual(url.path, "/tmp/laban-shot")
  }

  func testEmptySupportDirFallsBackToApplicationSupport() {
    let url = PersistenceStore.defaultBaseURL(environment: ["LABAN_SUPPORT_DIR": ""])
    XCTAssertEqual(url.lastPathComponent, "Laban")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Application Support")
  }
}
