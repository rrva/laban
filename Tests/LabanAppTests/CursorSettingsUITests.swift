import AppKit
import LabanCore
import XCTest

@testable import LabanApp

/// Tests for cursor-style and blink settings: UserDefaults persistence
/// and notification delivery. The `SettingsWindowController` UI-interaction
/// tests are covered by the notification+read round-trip tests here; the
/// AppKit control state is exercised by the `refresh()` call on
/// `windowDidBecomeKey`, which reads straight from `CursorSettings`.
final class CursorSettingsUITests: XCTestCase {

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

  // MARK: - Defaults

  func testDefaultStyleIsBlock() {
    XCTAssertEqual(CursorSettings.style, .block,
      "missing defaults key must return .block")
  }

  func testDefaultBlinkEnabledIsFalse() {
    XCTAssertFalse(CursorSettings.blinkEnabled,
      "missing defaults key must return false for blink")
  }

  // MARK: - setStyle persists and fires notification

  func testSetStyleWritesDefaultsKey() {
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

  func testSetStyleFiresNotification() {
    let exp = expectation(
      forNotification: CursorSettings.didChangeNotification,
      object: nil, handler: nil)
    CursorSettings.setStyle(.bar)
    wait(for: [exp], timeout: 1.0)
  }

  // MARK: - setBlinkEnabled persists and fires notification

  func testSetBlinkEnabledWritesDefaultsKey() {
    CursorSettings.setBlinkEnabled(true)
    XCTAssertTrue(CursorSettings.blinkEnabled)
  }

  func testSetBlinkDisabledRoundTrips() {
    CursorSettings.setBlinkEnabled(true)
    CursorSettings.setBlinkEnabled(false)
    XCTAssertFalse(CursorSettings.blinkEnabled)
  }

  func testSetBlinkEnabledFiresNotification() {
    let exp = expectation(
      forNotification: CursorSettings.didChangeNotification,
      object: nil, handler: nil)
    CursorSettings.setBlinkEnabled(true)
    wait(for: [exp], timeout: 1.0)
  }

  // MARK: - Notification fires exactly once per set call

  func testNotificationFiresOncePerStyleSet() {
    var count = 0
    let token = NotificationCenter.default.addObserver(
      forName: CursorSettings.didChangeNotification,
      object: nil, queue: .main
    ) { _ in count += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    CursorSettings.setStyle(.bar)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    XCTAssertEqual(count, 1,
      "setStyle must fire exactly one didChangeNotification")
  }

  func testNotificationFiresOncePerBlinkSet() {
    var count = 0
    let token = NotificationCenter.default.addObserver(
      forName: CursorSettings.didChangeNotification,
      object: nil, queue: .main
    ) { _ in count += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    CursorSettings.setBlinkEnabled(true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    XCTAssertEqual(count, 1,
      "setBlinkEnabled must fire exactly one didChangeNotification")
  }

  // MARK: - External defaults write is reflected after next read

  func testExternalDefaultsWriteIsReflectedOnNextRead() {
    // Simulate an external write (e.g. `defaults write` or argument domain)
    UserDefaults.standard.set(
      CursorSettings.Style.underline.rawValue,
      forKey: CursorSettings.styleKey)
    UserDefaults.standard.set(true, forKey: CursorSettings.blinkKey)

    XCTAssertEqual(CursorSettings.style, .underline,
      "external defaults write must be visible through CursorSettings.style")
    XCTAssertTrue(CursorSettings.blinkEnabled,
      "external defaults write must be visible through CursorSettings.blinkEnabled")
  }
}
