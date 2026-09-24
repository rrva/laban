import Foundation
import XCTest

@testable import LabanCore

final class KittyGraphicsSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-kitty-graphics-settings-tests-\(getpid())"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testEnabledByDefault() {
    XCTAssertTrue(KittyGraphicsSettings.isEnabled(defaults: defaults, environment: [:]))
  }

  func testUserDefaultTurnsItOff() {
    defaults.set(false, forKey: KittyGraphicsSettings.defaultsKey)
    XCTAssertFalse(KittyGraphicsSettings.isEnabled(defaults: defaults, environment: [:]))
  }

  func testEnvironmentOverridesTheUserDefault() {
    defaults.set(false, forKey: KittyGraphicsSettings.defaultsKey)
    XCTAssertTrue(
      KittyGraphicsSettings.isEnabled(
        defaults: defaults, environment: [KittyGraphicsSettings.environmentKey: "1"]))
    XCTAssertFalse(
      KittyGraphicsSettings.isEnabled(
        defaults: .init(suiteName: suiteName + "-empty")!,
        environment: [KittyGraphicsSettings.environmentKey: "0"]))
  }
}
