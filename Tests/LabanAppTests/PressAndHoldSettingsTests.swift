import XCTest

@testable import LabanApp

final class PressAndHoldSettingsTests: XCTestCase {

  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "laban.tests.pressAndHold.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testAccentPanelIsDisabledWhenUserHasNoOpinion() {
    XCTAssertNil(defaults.object(forKey: PressAndHoldSettings.key))
    PressAndHoldSettings.disableAccentPanel(defaults: defaults)
    XCTAssertEqual(defaults.bool(forKey: PressAndHoldSettings.key), false)
  }

  func testExplicitUserValueOverridesTheRegisteredOptOut() {
    PressAndHoldSettings.disableAccentPanel(defaults: defaults)
    defaults.set(true, forKey: PressAndHoldSettings.key)
    XCTAssertEqual(defaults.bool(forKey: PressAndHoldSettings.key), true)
  }
}
