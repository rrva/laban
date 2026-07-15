import AppKit
import LabanCore
import XCTest

@testable import LabanApp

@MainActor
final class TerminalTransparencySettingsUITests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for key in [
      TerminalTransparencySettings.backgroundOpacityKey,
      TerminalTransparencySettings.applyToExplicitCellBackgroundsKey,
      TerminalTransparencySettings.backdropStyleKey,
    ] {
      UserDefaults.standard.removeObject(forKey: key)
    }
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testAppearanceControlsExposePercentRangeLabelAndExplicitCellChoice() {
    TerminalTransparencySettings.setRequestedConfiguration(
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.73,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .none))
    let controller = makeController()
    let controls = controller.transparencyControlsForTesting

    XCTAssertEqual(controls.slider.minValue, 0)
    XCTAssertEqual(controls.slider.maxValue, 100)
    XCTAssertTrue(controls.slider.isContinuous)
    XCTAssertEqual(controls.slider.doubleValue, 73)
    XCTAssertEqual(controls.valueLabel.stringValue, "73%")
    XCTAssertEqual(controls.explicitCellCheckbox.state, .on)
    XCTAssertEqual(controls.slider.accessibilityLabel(), L10n.tr("Background opacity"))
    XCTAssertEqual(
      controls.slider.accessibilityValueDescription(),
      String(format: L10n.tr("Background opacity: %lld percent"), Int64(73)))
  }

  func testSliderAndCheckboxDriveRequestedSettings() {
    let controller = makeController()
    let controls = controller.transparencyControlsForTesting
    controls.slider.doubleValue = 42
    controls.slider.sendAction(controls.slider.action, to: controls.slider.target)
    XCTAssertEqual(controls.valueLabel.stringValue, "42%")
    controller.flushPendingTransparencyPersistenceForTesting()
    XCTAssertEqual(TerminalTransparencySettings.requestedConfiguration.backgroundOpacity, 0.42)

    controls.explicitCellCheckbox.state = .on
    controls.explicitCellCheckbox.sendAction(
      controls.explicitCellCheckbox.action,
      to: controls.explicitCellCheckbox.target)
    XCTAssertTrue(
      TerminalTransparencySettings.requestedConfiguration.applyToExplicitCellBackgrounds)
  }

  func testContinuousSliderBurstCoalescesToOnePersistenceNotification() throws {
    let suiteName = "TerminalTransparencySettingsUITests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let notifications = NotificationCenter()
    let persistence = TerminalTransparencyLivePersistence(
      defaults: defaults,
      notificationCenter: notifications,
      delay: 0.02)
    var count = 0
    let token = notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in count += 1 }
    defer { notifications.removeObserver(token) }

    persistence.scheduleBackgroundOpacity(0.91)
    persistence.scheduleBackgroundOpacity(0.72)
    persistence.scheduleBackgroundOpacity(0.43)
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))

    XCTAssertEqual(count, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: defaults)
        .backgroundOpacity,
      0.43)
  }

  private func makeController() -> SettingsWindowController {
    SettingsWindowController(
      theme: ThemeMenuController(),
      renderer: RendererModeMenuController(applySelection: { _ in }),
      backend: TerminalBackendMenuController(),
      onChangeFont: {},
      onChangeCJKFont: {},
      onTestNotification: {},
      focusStatusSnapshot: { .notChecked },
      onCheckFocusStatus: { completion in completion(.notChecked) })
  }
}
