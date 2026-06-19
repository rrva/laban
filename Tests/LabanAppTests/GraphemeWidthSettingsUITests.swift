import AppKit
import LabanCore
import XCTest

@testable import LabanApp

/// Tests for the "Unicode width" Settings row backed by `GraphemeWidthSettings`:
/// UserDefaults persistence and change-notification delivery. Mirrors
/// `CursorSettingsUITests` — the `SettingsWindowController`'s AppKit control
/// state is exercised by its `refresh()` call on `windowDidBecomeKey`, which
/// reads straight from `GraphemeWidthSettings.current()`; these tests cover the
/// store the popup's `@objc graphemeWidthChanged(_:)` handler drives.
final class GraphemeWidthSettingsUITests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: GraphemeWidthSettings.defaultsKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: GraphemeWidthSettings.defaultsKey)
    super.tearDown()
  }

  func testDefaultModeIsAuto() {
    XCTAssertEqual(
      GraphemeWidthSettings.current(), .auto,
      "missing defaults key must return .auto")
  }

  func testSelectingPreferGraphemeWritesDefaultsKey() {
    GraphemeWidthSettings.set(.preferGrapheme)
    XCTAssertEqual(GraphemeWidthSettings.current(), .preferGrapheme)
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: GraphemeWidthSettings.defaultsKey),
      GraphemeWidthMode.preferGrapheme.rawValue)
  }

  func testRevertingToAutoRoundTrips() {
    GraphemeWidthSettings.set(.preferGrapheme)
    GraphemeWidthSettings.set(.auto)
    XCTAssertEqual(GraphemeWidthSettings.current(), .auto)
  }

  func testSetFiresChangeNotification() {
    let exp = expectation(
      forNotification: GraphemeWidthSettings.didChangeNotification,
      object: nil, handler: nil)
    GraphemeWidthSettings.set(.preferGrapheme)
    wait(for: [exp], timeout: 1.0)
  }
}
