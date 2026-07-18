import Foundation
import LabanCore
import LabanRenderer
import XCTest

@testable import LabanApp

@MainActor
final class FrostedPresetTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testPresetDerivationRequiresExactOpaqueOrFrostedConfiguration() {
    XCTAssertEqual(
      TerminalTransparencyPreset.derive(
        from: TerminalTransparencyConfiguration(
          backgroundOpacity: 1,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .none,
          backgroundImageScaling: .stretch)),
      .opaque)
    XCTAssertEqual(
      TerminalTransparencyPreset.derive(
        from: TerminalTransparencyConfiguration(
          backgroundOpacity: 0.80,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .systemBlur,
          backgroundImageScaling: .fit,
          backgroundBlur: 0.20)),
      .frosted)

    for configuration in [
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.99,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .none),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 1,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .none),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 1,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .systemBlur,
        backgroundBlur: 0.20),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .none,
        backgroundBlur: 0.20),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundBlur: 0.21),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.90,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .image),
    ] {
      XCTAssertEqual(TerminalTransparencyPreset.derive(from: configuration), .custom)
    }
  }

  func testFrostedAppliesOneAtomicChangeAndPreservesManagedImageAndScaling() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let managedImage = try XCTUnwrap(
      TerminalManagedBackgroundImage(
        identifier: "image-preserved.png",
        displayName: "Aurora.png"))
    TerminalTransparencySettings.setRequestedSettings(
      TerminalTransparencyRequestedSettings(
        configuration: TerminalTransparencyConfiguration(
          backgroundOpacity: 0.37,
          applyToExplicitCellBackgrounds: true,
          backdropStyle: .image,
          backgroundImageScaling: .stretch),
        managedBackgroundImage: managedImage),
      defaults: defaults,
      notificationCenter: notifications)
    var notificationCount = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.applyPreset(
      .frosted,
      themeIsDark: true,
      defaults: defaults,
      notificationCenter: notifications)

    XCTAssertEqual(notificationCount, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedSettings(defaults: defaults),
      TerminalTransparencyRequestedSettings(
        configuration: TerminalTransparencyConfiguration(
          backgroundOpacity: 0.80,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .systemBlur,
          backgroundImageScaling: .stretch,
          backgroundBlur: 0.20),
        managedBackgroundImage: managedImage))
    XCTAssertEqual(TerminalTransparencySettings.preset(defaults: defaults), .frosted)
  }

  func testPresetReplacesPendingSliderWriteWithOneNotification() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let persistence = TerminalTransparencyLivePersistence(
      defaults: defaults,
      notificationCenter: notifications,
      delay: 0.02)
    var notificationCount = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { notifications.removeObserver(token) }

    persistence.scheduleBackgroundOpacity(0.42)
    persistence.applyPreset(.frosted, themeIsDark: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))

    XCTAssertEqual(notificationCount, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundImageScaling: .fill,
        backgroundBlur: 0.20))
  }

  func testOpaquePresetIsAtomicAndThemeNeutral() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    defaults.set("Solarized Dark", forKey: "LabanThemeCurrent")
    defaults.set(true, forKey: "LabanThemeFollowsSystemAppearance")
    TerminalTransparencySettings.setRequestedConfiguration(
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.31,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .systemBlur,
        backgroundImageScaling: .fit),
      defaults: defaults,
      notificationCenter: notifications)

    TerminalTransparencySettings.applyPreset(
      .opaque,
      themeIsDark: true,
      defaults: defaults,
      notificationCenter: notifications)

    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 1,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .none,
        backgroundImageScaling: .fit))
    XCTAssertEqual(defaults.string(forKey: "LabanThemeCurrent"), "Solarized Dark")
    XCTAssertEqual(defaults.object(forKey: "LabanThemeFollowsSystemAppearance") as? Bool, true)
  }

  func testPresetDefaultsIgnoreAllLocaleAndInputSourceHints() throws {
    let defaults = try makeDefaults()
    defaults.set(["zh-Hans", "ja"], forKey: "AppleLanguages")
    defaults.set("zh_CN", forKey: "AppleLocale")
    defaults.set("CN", forKey: "AppleRegion")
    defaults.set(
      "com.apple.inputmethod.SCIM.ITABC",
      forKey: "AppleCurrentKeyboardLayoutInputSourceID")
    defaults.set("PingFang SC", forKey: "LabanCJKFontPostScriptName")

    XCTAssertEqual(TerminalTransparencySettings.preset(defaults: defaults), .opaque)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults).backdropStyle,
      .none)
  }

  func testFrostedDerivationRequiresTerminalLikeOpacityAndBlur() {
    XCTAssertEqual(
      TerminalTransparencyPreset.derive(
        from: TerminalTransparencyConfiguration(
          backgroundOpacity: 0.80,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .systemBlur,
          backgroundBlur: 0.20)),
      .frosted)
    XCTAssertEqual(
      TerminalTransparencyPreset.derive(
        from: TerminalTransparencyConfiguration(
          backgroundOpacity: 0.80,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .systemBlur)),
      .custom)
    XCTAssertEqual(
      TerminalTransparencyPreset.derive(
        from: TerminalTransparencyConfiguration(
          backgroundOpacity: 0.80,
          applyToExplicitCellBackgrounds: true,
          backdropStyle: .systemBlur,
          backgroundBlur: 0.20)),
      .custom)
  }

  func testFrostedAppliesLightThemeOpacityAtomically() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    var notificationCount = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.applyPreset(
      .frosted,
      themeIsDark: false,
      defaults: defaults,
      notificationCenter: notifications)

    XCTAssertEqual(notificationCount, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundImageScaling: .fill,
        backgroundBlur: 0.20))
    XCTAssertEqual(TerminalTransparencySettings.preset(defaults: defaults), .frosted)
  }

  func testReresolveKeepsUniformTerminalLikeFrostedWithoutNotifications() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    TerminalTransparencySettings.applyPreset(
      .frosted,
      themeIsDark: true,
      defaults: defaults,
      notificationCenter: notifications)
    var notificationCount = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { notifications.removeObserver(token) }

    TerminalTransparencySettings.reresolveFrostedOpacityIfNeeded(
      themeIsDark: false,
      defaults: defaults,
      notificationCenter: notifications)
    TerminalTransparencySettings.reresolveFrostedOpacityIfNeeded(
      themeIsDark: true,
      defaults: defaults,
      notificationCenter: notifications)

    XCTAssertEqual(notificationCount, 0)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundBlur: 0.20))
    XCTAssertEqual(TerminalTransparencySettings.preset(defaults: defaults), .frosted)
  }

  func testReresolveLeavesOpaqueAndCustomConfigurationsUntouched() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    var notificationCount = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { notifications.removeObserver(token) }

    // Default (opaque) state.
    TerminalTransparencySettings.reresolveFrostedOpacityIfNeeded(
      themeIsDark: false,
      defaults: defaults,
      notificationCenter: notifications)
    XCTAssertEqual(notificationCount, 0)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults)
        .backgroundOpacity,
      1)

    // Custom state: System Blur with a non-Frosted opacity.
    TerminalTransparencySettings.setRequestedConfiguration(
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.42,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundImageScaling: .fill),
      defaults: defaults,
      notificationCenter: notifications)
    XCTAssertEqual(notificationCount, 1)
    TerminalTransparencySettings.reresolveFrostedOpacityIfNeeded(
      themeIsDark: false,
      defaults: defaults,
      notificationCenter: notifications)
    XCTAssertEqual(notificationCount, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults)
        .backgroundOpacity,
      0.42)
  }

  func testThemeFollowerLeavesUniformTerminalLikeFrostedUnchanged() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    TerminalTransparencySettings.applyPreset(
      .frosted,
      themeIsDark: true,
      defaults: defaults,
      notificationCenter: notifications)

    let follower = FrostedPresetThemeFollower(
      defaults: defaults,
      notificationCenter: notifications)
    var notificationCount = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { notifications.removeObserver(token) }

    let priorTheme = Theme.current
    defer { Theme.apply(priorTheme) }
    Theme.apply(Theme.catppuccinLatte)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))

    _ = follower
    XCTAssertEqual(notificationCount, 0)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundBlur: 0.20))
    XCTAssertEqual(TerminalTransparencySettings.preset(defaults: defaults), .frosted)
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "FrostedPresetTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }
}
