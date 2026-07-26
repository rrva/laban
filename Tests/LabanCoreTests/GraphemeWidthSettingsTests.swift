import Foundation
import XCTest

@testable import LabanCore

final class GraphemeWidthSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-grapheme-width-tests-\(getpid())"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultModeIsAuto() {
    XCTAssertEqual(GraphemeWidthSettings.current(defaults: defaults), .auto)
  }

  func testGarbageValueFallsBackToAuto() {
    defaults.set("preferLegacy", forKey: GraphemeWidthSettings.defaultsKey)
    XCTAssertEqual(GraphemeWidthSettings.current(defaults: defaults), .auto)
  }

  func testSetPreferGraphemeWritesDefaultsKeyAndIsCurrent() {
    GraphemeWidthSettings.set(.preferGrapheme, defaults: defaults)
    XCTAssertEqual(
      defaults.string(forKey: GraphemeWidthSettings.defaultsKey),
      GraphemeWidthMode.preferGrapheme.rawValue,
      "set must persist the raw value under the documented UserDefaults key")
    XCTAssertEqual(GraphemeWidthSettings.current(defaults: defaults), .preferGrapheme)
  }

  func testRoundTrip() {
    GraphemeWidthSettings.set(.preferGrapheme, defaults: defaults)
    XCTAssertEqual(GraphemeWidthSettings.current(defaults: defaults), .preferGrapheme)
    GraphemeWidthSettings.set(.auto, defaults: defaults)
    XCTAssertEqual(GraphemeWidthSettings.current(defaults: defaults), .auto)
  }

  func testSetFiresChangeNotification() {
    let exp = expectation(
      forNotification: GraphemeWidthSettings.didChangeNotification,
      object: nil, handler: nil)
    GraphemeWidthSettings.set(.preferGrapheme, defaults: defaults)
    wait(for: [exp], timeout: 1.0)
  }
}
