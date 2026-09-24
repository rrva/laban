import Foundation
import XCTest

@testable import LabanRenderer

final class EmojiRenderingSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-emoji-rendering-settings-tests-\(getpid())"
  private var savedRegistrationDomain: [String: Any] = [:]

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
    // Other suites pin the emoji mode through `register(defaults:)`, whose
    // process-wide registration domain even a fresh suite reads through.
    // Drop that pin so the missing-key fallback is what gets tested.
    savedRegistrationDomain = UserDefaults.standard.volatileDomain(
      forName: UserDefaults.registrationDomain)
    var registered = savedRegistrationDomain
    registered.removeValue(forKey: EmojiRenderingSettings.defaultsKey)
    UserDefaults.standard.setVolatileDomain(registered, forName: UserDefaults.registrationDomain)
  }

  override func tearDown() {
    UserDefaults.standard.setVolatileDomain(
      savedRegistrationDomain, forName: UserDefaults.registrationDomain)
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultModeIsColor() {
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .color)
  }

  func testGarbageValueFallsBackToColor() {
    defaults.set("sparkles", forKey: EmojiRenderingSettings.defaultsKey)
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .color)
  }

  func testSetMonochromePersistsRawValue() {
    EmojiRenderingSettings.set(.monochrome, defaults: defaults)
    XCTAssertEqual(
      defaults.string(forKey: EmojiRenderingSettings.defaultsKey),
      EmojiRenderingMode.monochrome.rawValue)
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .monochrome)
  }

  func testRoundTrip() {
    EmojiRenderingSettings.set(.color, defaults: defaults)
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .color)
    EmojiRenderingSettings.set(.monochrome, defaults: defaults)
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .monochrome)
  }

  func testSetFiresChangeNotification() {
    let exp = expectation(
      forNotification: EmojiRenderingSettings.didChangeNotification,
      object: nil,
      handler: nil)
    EmojiRenderingSettings.set(.color, defaults: defaults)
    wait(for: [exp], timeout: 1.0)
  }
}
