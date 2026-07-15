import Foundation
import LabanCore
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
          backgroundOpacity: 0.90,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .systemBlur,
          backgroundImageScaling: .fit)),
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
        backgroundOpacity: 0.90,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .systemBlur),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.90,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .none),
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
      defaults: defaults,
      notificationCenter: notifications)

    XCTAssertEqual(notificationCount, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedSettings(defaults: defaults),
      TerminalTransparencyRequestedSettings(
        configuration: TerminalTransparencyConfiguration(
          backgroundOpacity: 0.90,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .systemBlur,
          backgroundImageScaling: .stretch),
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
    persistence.applyPreset(.frosted)
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))

    XCTAssertEqual(notificationCount, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.90,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundImageScaling: .fill))
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

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "FrostedPresetTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }
}
