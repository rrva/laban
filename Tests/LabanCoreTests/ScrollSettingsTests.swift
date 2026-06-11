import Foundation
import XCTest

@testable import LabanCore

final class ScrollSettingsTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: ScrollSettings.modeKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: ScrollSettings.modeKey)
    super.tearDown()
  }

  func testDefaultModeIsPixelSmooth() {
    XCTAssertEqual(
      ScrollSettings.mode, .pixelSmooth,
      "fresh install must default to pixel-smooth scrolling")
  }

  func testSetLineQuantizedRoundTrips() {
    ScrollSettings.setMode(.lineQuantized)
    XCTAssertEqual(ScrollSettings.mode, .lineQuantized)
  }

  func testSetPixelSmoothRoundTrips() {
    ScrollSettings.setMode(.lineQuantized)
    ScrollSettings.setMode(.pixelSmooth)
    XCTAssertEqual(ScrollSettings.mode, .pixelSmooth)
  }

  func testGarbageValueFallsBackToDefault() {
    UserDefaults.standard.set("warpSpeed", forKey: ScrollSettings.modeKey)
    XCTAssertEqual(ScrollSettings.mode, .pixelSmooth)
  }

  func testSetModePostsNotification() {
    let exp = expectation(description: "didChangeNotification fires for mode")
    let token = NotificationCenter.default.addObserver(
      forName: ScrollSettings.didChangeNotification, object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(token) }

    ScrollSettings.setMode(.lineQuantized)
    wait(for: [exp], timeout: 1)
  }
}
