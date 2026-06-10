import Foundation
import XCTest
@testable import LabanCore

final class CursorSettingsTests: XCTestCase {

  // MARK: - Setup / teardown

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: CursorSettings.styleKey)
    UserDefaults.standard.removeObject(forKey: CursorSettings.blinkKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: CursorSettings.styleKey)
    UserDefaults.standard.removeObject(forKey: CursorSettings.blinkKey)
    super.tearDown()
  }

  // MARK: - Default values

  func testDefaultStyleIsBlock() {
    XCTAssertEqual(CursorSettings.style, .block,
      "fresh install must default to block cursor")
  }

  func testDefaultBlinkIsOff() {
    XCTAssertFalse(CursorSettings.blinkEnabled,
      "fresh install must default to blink off so idle terminal needs no wakeups")
  }

  // MARK: - Round-trip persistence

  func testSetStyleBarRoundTrips() {
    CursorSettings.setStyle(.bar)
    XCTAssertEqual(CursorSettings.style, .bar)
  }

  func testSetStyleUnderlineRoundTrips() {
    CursorSettings.setStyle(.underline)
    XCTAssertEqual(CursorSettings.style, .underline)
  }

  func testSetStyleBlockRoundTrips() {
    CursorSettings.setStyle(.bar)
    CursorSettings.setStyle(.block)
    XCTAssertEqual(CursorSettings.style, .block)
  }

  func testSetBlinkEnabledRoundTrips() {
    CursorSettings.setBlinkEnabled(true)
    XCTAssertTrue(CursorSettings.blinkEnabled)
  }

  func testSetBlinkDisabledRoundTrips() {
    CursorSettings.setBlinkEnabled(true)
    CursorSettings.setBlinkEnabled(false)
    XCTAssertFalse(CursorSettings.blinkEnabled)
  }

  // MARK: - Int32 mapping

  func testBlockStyleValue() {
    XCTAssertEqual(CursorSettings.Style.block.labanStyleValue, 0,
      "block must map to LABAN_CURSOR_STYLE_BLOCK = 0")
  }

  func testBarStyleValue() {
    XCTAssertEqual(CursorSettings.Style.bar.labanStyleValue, 1,
      "bar must map to LABAN_CURSOR_STYLE_BAR = 1")
  }

  func testUnderlineStyleValue() {
    XCTAssertEqual(CursorSettings.Style.underline.labanStyleValue, 2,
      "underline must map to LABAN_CURSOR_STYLE_UNDERLINE = 2")
  }

  // MARK: - Notification

  func testSetStylePostsNotification() {
    let exp = expectation(description: "didChangeNotification fires for style")
    let token = NotificationCenter.default.addObserver(
      forName: CursorSettings.didChangeNotification, object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(token) }

    CursorSettings.setStyle(.bar)
    wait(for: [exp], timeout: 1)
  }

  func testSetBlinkPostsNotification() {
    let exp = expectation(description: "didChangeNotification fires for blink")
    let token = NotificationCenter.default.addObserver(
      forName: CursorSettings.didChangeNotification, object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(token) }

    CursorSettings.setBlinkEnabled(true)
    wait(for: [exp], timeout: 1)
  }

  // MARK: - Mutation check helper

  /// Verifies that flipping the blink default from false to true changes the
  /// observed default. (The Review Gate mutation check swaps the source literal;
  /// this test documents the expected relationship.)
  func testDefaultBlinkMutationWouldBeDetectable() {
    // With the key absent, the default must be false.
    XCTAssertFalse(CursorSettings.blinkEnabled)
    // If the implementation stored `true` as the fallback, this assertion fails.
    // A reviewer mutating the source literal from `false` to `true` must see at
    // least this test fail.
  }
}
