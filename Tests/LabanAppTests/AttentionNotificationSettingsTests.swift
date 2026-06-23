import LabanCore
import XCTest

@testable import LabanApp

final class AttentionNotificationSettingsTests: XCTestCase {
  override func setUp() {
    super.setUp()
    clearSettings()
  }

  override func tearDown() {
    clearSettings()
    super.tearDown()
  }

  func testDefaultsFavorActionNeededOnly() {
    XCTAssertTrue(AttentionNotificationSettings.isEnabled(for: .needsAction))
    XCTAssertFalse(AttentionNotificationSettings.isEnabled(for: .completion))
    XCTAssertFalse(AttentionNotificationSettings.isEnabled(for: .passive))
    XCTAssertFalse(AttentionNotificationSettings.soundEnabled)
  }

  func testSetCategoryEnabledPersistsPreference() {
    AttentionNotificationSettings.setEnabled(true, for: .completion)

    XCTAssertTrue(AttentionNotificationSettings.isEnabled(for: .completion))
    XCTAssertEqual(
      UserDefaults.standard.object(forKey: AttentionNotificationSettings.completionKey) as? Bool,
      true)
  }

  func testSetCategoryDisabledRoundTrips() {
    AttentionNotificationSettings.setEnabled(true, for: .passive)
    AttentionNotificationSettings.setEnabled(false, for: .passive)

    XCTAssertFalse(AttentionNotificationSettings.isEnabled(for: .passive))
  }

  func testLegacyKeyMigratesPassiveNotifications() {
    UserDefaults.standard.set(true, forKey: AttentionNotificationSettings.defaultsKey)

    XCTAssertTrue(AttentionNotificationSettings.isEnabled(for: .passive))
    XCTAssertTrue(AttentionNotificationSettings.isEnabled)
  }

  func testExplicitPassiveKeyOverridesLegacyKey() {
    UserDefaults.standard.set(true, forKey: AttentionNotificationSettings.defaultsKey)
    UserDefaults.standard.set(false, forKey: AttentionNotificationSettings.passiveKey)

    XCTAssertFalse(AttentionNotificationSettings.isEnabled(for: .passive))
  }

  func testSetSoundEnabledPersistsPreference() {
    AttentionNotificationSettings.setSoundEnabled(true)

    XCTAssertTrue(AttentionNotificationSettings.soundEnabled)
  }

  func testSetFiresChangeNotification() {
    let exp = expectation(
      forNotification: AttentionNotificationSettings.didChangeNotification,
      object: nil,
      handler: nil)

    AttentionNotificationSettings.setEnabled(true, for: .completion)

    wait(for: [exp], timeout: 1.0)
  }

  private func clearSettings() {
    for key in [
      AttentionNotificationSettings.defaultsKey,
      AttentionNotificationSettings.needsActionKey,
      AttentionNotificationSettings.completionKey,
      AttentionNotificationSettings.passiveKey,
      AttentionNotificationSettings.soundKey,
    ] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}
