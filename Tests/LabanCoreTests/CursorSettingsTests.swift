import Foundation
import XCTest

@testable import LabanCore

final class CursorSettingsTests: XCTestCase {
  /// A private, uniquely named suite rather than `UserDefaults.standard`.
  /// `swift test --parallel` forks per test case and every process shares the
  /// one on-disk domain, so writing the real keys here raced other suites. The
  /// UUID keeps the name unique even against sibling methods of this class.
  /// See `execplans/active/test-userdefaults-isolation.md`.
  private var defaults: UserDefaults!
  private var suiteName = ""


  // MARK: - Setup / teardown

  override func setUp() {
    super.setUp()
    suiteName = "CursorSettingsTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  // MARK: - Default values

  func testDefaultStyleIsBlock() {
    XCTAssertEqual(
      CursorSettings.style(defaults: defaults), .block,
      "fresh install must default to block cursor")
  }

  func testDefaultBlinkIsOff() {
    XCTAssertFalse(
      CursorSettings.blinkEnabled(defaults: defaults),
      "fresh install must default to blink off so idle terminal needs no wakeups")
  }

  // MARK: - Round-trip persistence

  func testSetStyleBarRoundTrips() {
    CursorSettings.setStyle(.bar, defaults: defaults)
    XCTAssertEqual(CursorSettings.style(defaults: defaults), .bar)
  }

  func testSetStyleUnderlineRoundTrips() {
    CursorSettings.setStyle(.underline, defaults: defaults)
    XCTAssertEqual(CursorSettings.style(defaults: defaults), .underline)
  }

  func testSetStyleBlockRoundTrips() {
    CursorSettings.setStyle(.bar, defaults: defaults)
    CursorSettings.setStyle(.block, defaults: defaults)
    XCTAssertEqual(CursorSettings.style(defaults: defaults), .block)
  }

  func testSetBlinkEnabledRoundTrips() {
    CursorSettings.setBlinkEnabled(true, defaults: defaults)
    XCTAssertTrue(CursorSettings.blinkEnabled(defaults: defaults))
  }

  func testSetBlinkDisabledRoundTrips() {
    CursorSettings.setBlinkEnabled(true, defaults: defaults)
    CursorSettings.setBlinkEnabled(false, defaults: defaults)
    XCTAssertFalse(CursorSettings.blinkEnabled(defaults: defaults))
  }

  // MARK: - Int32 mapping

  func testBlockStyleValue() {
    XCTAssertEqual(
      CursorSettings.Style.block.labanStyleValue, 0,
      "block must map to LABAN_CURSOR_STYLE_BLOCK = 0")
  }

  func testBarStyleValue() {
    XCTAssertEqual(
      CursorSettings.Style.bar.labanStyleValue, 1,
      "bar must map to LABAN_CURSOR_STYLE_BAR = 1")
  }

  func testUnderlineStyleValue() {
    XCTAssertEqual(
      CursorSettings.Style.underline.labanStyleValue, 2,
      "underline must map to LABAN_CURSOR_STYLE_UNDERLINE = 2")
  }

  // MARK: - Notification

  func testSetStylePostsNotification() {
    let exp = expectation(description: "didChangeNotification fires for style")
    let token = NotificationCenter.default.addObserver(
      forName: CursorSettings.didChangeNotification, object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(token) }

    CursorSettings.setStyle(.bar, defaults: defaults)
    wait(for: [exp], timeout: 1)
  }

  func testSetBlinkPostsNotification() {
    let exp = expectation(description: "didChangeNotification fires for blink")
    let token = NotificationCenter.default.addObserver(
      forName: CursorSettings.didChangeNotification, object: nil, queue: .main
    ) { _ in exp.fulfill() }
    defer { NotificationCenter.default.removeObserver(token) }

    CursorSettings.setBlinkEnabled(true, defaults: defaults)
    wait(for: [exp], timeout: 1)
  }

  // MARK: - Mutation check helper

  /// Verifies that flipping the blink default from false to true changes the
  /// observed default. (The Review Gate mutation check swaps the source literal;
  /// this test documents the expected relationship.)
  func testDefaultBlinkMutationWouldBeDetectable() {
    // With the key absent, the default must be false.
    XCTAssertFalse(CursorSettings.blinkEnabled(defaults: defaults))
    // If the implementation stored `true` as the fallback, this assertion fails.
    // A reviewer mutating the source literal from `false` to `true` must see at
    // least this test fail.
  }
}
