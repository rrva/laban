import Foundation
import XCTest

@testable import LabanRenderer

final class EmojiRenderingSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-emoji-rendering-settings-tests"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultModeIsMonochrome() {
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .monochrome)
  }

  func testGarbageValueFallsBackToMonochrome() {
    defaults.set("sparkles", forKey: EmojiRenderingSettings.defaultsKey)
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .monochrome)
  }

  func testSetColorPersistsRawValue() {
    EmojiRenderingSettings.set(.color, defaults: defaults)
    XCTAssertEqual(
      defaults.string(forKey: EmojiRenderingSettings.defaultsKey),
      EmojiRenderingMode.color.rawValue)
    XCTAssertEqual(EmojiRenderingSettings.current(defaults: defaults), .color)
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
