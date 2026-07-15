import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class TerminalTransparencySettingsTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testMissingKeysUseShippedOpaqueDefaults() throws {
    let defaults = try makeDefaults()

    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 1,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .none))
  }

  func testIndividualSettersPersistAndRoundTripRequestedValues() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()

    TerminalTransparencySettings.setBackgroundOpacity(
      0.7, defaults: defaults, notificationCenter: notifications)
    TerminalTransparencySettings.setApplyToExplicitCellBackgrounds(
      true, defaults: defaults, notificationCenter: notifications)
    TerminalTransparencySettings.setBackdropStyle(
      .systemBlur, defaults: defaults, notificationCenter: notifications)

    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.7,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .systemBlur))
    XCTAssertEqual(
      defaults.double(forKey: TerminalTransparencySettings.backgroundOpacityKey), 0.7)
    XCTAssertEqual(
      defaults.object(
        forKey: TerminalTransparencySettings.applyToExplicitCellBackgroundsKey) as? Bool,
      true)
    XCTAssertEqual(
      defaults.string(forKey: TerminalTransparencySettings.backdropStyleKey),
      TerminalBackdropStyle.systemBlur.rawValue)
  }

  func testStoredOpacityIsClampedOnRead() throws {
    let defaults = try makeDefaults()

    defaults.set(-4.0, forKey: TerminalTransparencySettings.backgroundOpacityKey)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults).backgroundOpacity,
      0)

    defaults.set(4.0, forKey: TerminalTransparencySettings.backgroundOpacityKey)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults).backgroundOpacity,
      1)
  }

  func testMalformedStoredOpacityUsesSafeOpaqueValue() throws {
    let defaults = try makeDefaults()

    defaults.set("not-an-opacity", forKey: TerminalTransparencySettings.backgroundOpacityKey)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults).backgroundOpacity,
      1)
  }

  func testSetterClampsBeforePersistence() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()

    TerminalTransparencySettings.setBackgroundOpacity(
      -1, defaults: defaults, notificationCenter: notifications)
    XCTAssertEqual(
      defaults.double(forKey: TerminalTransparencySettings.backgroundOpacityKey), 0)

    TerminalTransparencySettings.setBackgroundOpacity(
      2, defaults: defaults, notificationCenter: notifications)
    XCTAssertEqual(
      defaults.double(forKey: TerminalTransparencySettings.backgroundOpacityKey), 1)
  }

  func testAtomicConfigurationChangePostsExactlyOneNotification() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    var count = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in count += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.setRequestedConfiguration(
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.8,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .systemBlur),
      defaults: defaults,
      notificationCenter: notifications)

    XCTAssertEqual(count, 1)
  }

  func testEqualSliderUpdatesAreCoalescedWithoutNotifications() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    var count = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in count += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.setBackgroundOpacity(
      0.7, defaults: defaults, notificationCenter: notifications)
    TerminalTransparencySettings.setBackgroundOpacity(
      0.7, defaults: defaults, notificationCenter: notifications)
    TerminalTransparencySettings.setBackgroundOpacity(
      0.7, defaults: defaults, notificationCenter: notifications)

    XCTAssertEqual(count, 1)
  }

  func testDifferentSliderValuesEachPostOneLogicalChange() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    var count = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in count += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.setBackgroundOpacity(
      0.9, defaults: defaults, notificationCenter: notifications)
    TerminalTransparencySettings.setBackgroundOpacity(
      0.8, defaults: defaults, notificationCenter: notifications)
    TerminalTransparencySettings.setBackgroundOpacity(
      0.8, defaults: defaults, notificationCenter: notifications)

    XCTAssertEqual(count, 2)
  }

  func testClampedEquivalentSliderUpdatesAreCoalesced() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    var count = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in count += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.setBackgroundOpacity(
      2, defaults: defaults, notificationCenter: notifications)
    TerminalTransparencySettings.setBackgroundOpacity(
      3, defaults: defaults, notificationCenter: notifications)

    // The missing key already means 1.0, so neither out-of-range write changes
    // the requested value even though the store is normalized to 1.0.
    XCTAssertEqual(count, 0)
    XCTAssertEqual(
      defaults.double(forKey: TerminalTransparencySettings.backgroundOpacityKey), 1)
  }

  func testMissingKeysCanBeNormalizedWithoutFalseChangeNotification() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    var count = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in count += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.setRequestedConfiguration(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      defaults: defaults,
      notificationCenter: notifications)

    XCTAssertEqual(count, 0)
    XCTAssertNotNil(defaults.object(forKey: TerminalTransparencySettings.backgroundOpacityKey))
    XCTAssertNotNil(
      defaults.object(
        forKey: TerminalTransparencySettings.applyToExplicitCellBackgroundsKey))
    XCTAssertEqual(
      defaults.string(forKey: TerminalTransparencySettings.backdropStyleKey),
      TerminalBackdropStyle.none.rawValue)
  }

  func testInvalidBackdropStyleFallsBackToNone() throws {
    let defaults = try makeDefaults()
    defaults.set("future-private-effect", forKey: TerminalTransparencySettings.backdropStyleKey)

    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults).backdropStyle,
      .none)
  }

  func testSystemBlurRequestIsPersistedWithoutInspectingAvailability() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()

    TerminalTransparencySettings.setRequestedConfiguration(
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.9,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur),
      defaults: defaults,
      notificationCenter: notifications)

    let requested = TerminalTransparencySettings.requestedConfiguration(defaults: defaults)
    let unavailable = TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: false,
      nativeFullscreen: false,
      supportsBehindWindowBlur: false,
      snapshotBackgroundCapability: .inProcess,
      headless: false)
    let headless = TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: false,
      nativeFullscreen: false,
      supportsBehindWindowBlur: true,
      snapshotBackgroundCapability: .inProcess,
      headless: true)

    XCTAssertEqual(requested.backdropStyle, .systemBlur)
    XCTAssertEqual(unavailable.backdropStyle, .none)
    XCTAssertEqual(headless.backdropStyle, .none)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults).backdropStyle,
      .systemBlur)
  }

  func testTemporaryOverrideAndLegacySessionDoNotOverwriteRequestedSettings() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let requested = TerminalTransparencyConfiguration(
      backgroundOpacity: 0.72,
      applyToExplicitCellBackgrounds: true,
      backdropStyle: .none)
    TerminalTransparencySettings.setRequestedConfiguration(
      requested,
      defaults: defaults,
      notificationCenter: notifications)

    let forced = TerminalTransparencyPolicy.resolve(
      requested: TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      reduceTransparency: true,
      nativeFullscreen: true,
      supportsBehindWindowBlur: false,
      snapshotBackgroundCapability: .legacy,
      headless: false)
    let restored = TerminalTransparencyPolicy.resolve(
      requested: TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      reduceTransparency: false,
      nativeFullscreen: false,
      supportsBehindWindowBlur: false,
      snapshotBackgroundCapability: .supported,
      headless: false)

    XCTAssertEqual(forced.forceOpaqueReason, .reduceTransparency)
    XCTAssertEqual(forced.backgroundOpacity, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults), requested)
    XCTAssertEqual(restored.backgroundOpacity, 0.72)
    XCTAssertTrue(restored.applyToExplicitCellBackgrounds)
    XCTAssertNil(restored.forceOpaqueReason)
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "TerminalTransparencySettingsTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }
}
