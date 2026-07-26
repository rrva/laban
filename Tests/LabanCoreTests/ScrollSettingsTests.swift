import Foundation
import XCTest

@testable import LabanCore

final class ScrollSettingsTests: XCTestCase {
  /// A private, uniquely named suite rather than `UserDefaults.standard`.
  /// `swift test --parallel` forks per test case and every process shares the
  /// one on-disk domain, so writing the real key here raced other suites. The
  /// UUID makes the name unique even against sibling test methods of this same
  /// class. See `execplans/active/test-userdefaults-isolation.md`.
  private var defaults: UserDefaults!
  private var suiteName = ""

  override func setUp() {
    super.setUp()
    suiteName = "ScrollSettingsTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultModeIsPixelSmooth() {
    XCTAssertEqual(
      ScrollSettings.mode(defaults: defaults), .pixelSmooth,
      "fresh install must default to pixel-smooth scrolling")
  }

  func testSetLineQuantizedRoundTrips() {
    ScrollSettings.setMode(.lineQuantized, defaults: defaults)
    XCTAssertEqual(ScrollSettings.mode(defaults: defaults), .lineQuantized)
  }

  func testSetPixelSmoothRoundTrips() {
    ScrollSettings.setMode(.lineQuantized, defaults: defaults)
    ScrollSettings.setMode(.pixelSmooth, defaults: defaults)
    XCTAssertEqual(ScrollSettings.mode(defaults: defaults), .pixelSmooth)
  }

  func testGarbageValueFallsBackToDefault() {
    defaults.set("warpSpeed", forKey: ScrollSettings.modeKey)
    XCTAssertEqual(ScrollSettings.mode(defaults: defaults), .pixelSmooth)
  }

  func testSetModePostsNotification() {
    let exp = expectation(description: "didChangeNotification fires for mode")
    let token = NotificationCenter.default.addObserver(
      forName: ScrollSettings.didChangeNotification, object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(token) }

    ScrollSettings.setMode(.lineQuantized, defaults: defaults)
    wait(for: [exp], timeout: 1)
  }
}
