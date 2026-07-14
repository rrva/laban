import AppKit
import Intents
import LabanCore
import XCTest

@testable import LabanApp

final class NativeFocusStatusMonitorTests: XCTestCase {
  func testConstructionDoesNotReadFocusState() {
    let center = FakeNativeFocusStatusCenter(status: .authorized, isFocused: true)

    _ = NativeFocusStatusMonitor(center: center)

    XCTAssertEqual(center.authorizationReadCount, 0)
    XCTAssertEqual(center.focusStatusReadCount, 0)
    XCTAssertEqual(center.authorizationRequestCount, 0)
  }

  func testAuthorizedCheckReturnsAppPerspectiveSuppressionWithoutRequesting() {
    let center = FakeNativeFocusStatusCenter(status: .authorized, isFocused: true)
    let checkedAt = Date(timeIntervalSince1970: 42)
    let monitor = NativeFocusStatusMonitor(center: center, now: { checkedAt })
    var result: NativeNotificationFocusSnapshot?

    monitor.check { result = $0 }

    XCTAssertEqual(
      result,
      NativeNotificationFocusSnapshot(
        authorizationStatus: .authorized,
        suppressesNotifications: true,
        checkedAt: checkedAt))
    XCTAssertEqual(center.authorizationReadCount, 1)
    XCTAssertEqual(center.focusStatusReadCount, 1)
    XCTAssertEqual(center.authorizationRequestCount, 0)
  }

  func testNotDeterminedCheckRequestsThenReadsWhenAuthorized() {
    let center = FakeNativeFocusStatusCenter(status: .notDetermined, isFocused: false)
    center.requestResult = .authorized
    let monitor = NativeFocusStatusMonitor(center: center)
    var result: NativeNotificationFocusSnapshot?

    monitor.check { result = $0 }

    XCTAssertEqual(result?.authorizationStatus, .authorized)
    XCTAssertEqual(result?.suppressesNotifications, false)
    XCTAssertEqual(center.authorizationRequestCount, 1)
    XCTAssertEqual(center.focusStatusReadCount, 1)
  }

  func testDeniedCheckDoesNotReadFocusValueOrRequestAgain() {
    let center = FakeNativeFocusStatusCenter(status: .denied, isFocused: true)
    let monitor = NativeFocusStatusMonitor(center: center)
    var result: NativeNotificationFocusSnapshot?

    monitor.check { result = $0 }

    XCTAssertEqual(result?.authorizationStatus, .denied)
    XCTAssertNil(result?.suppressesNotifications)
    XCTAssertEqual(center.focusStatusReadCount, 0)
    XCTAssertEqual(center.authorizationRequestCount, 0)
  }

  func testAuthorizedNilFocusValueRemainsInconclusive() {
    let center = FakeNativeFocusStatusCenter(status: .authorized, isFocused: nil)
    let monitor = NativeFocusStatusMonitor(center: center)
    var result: NativeNotificationFocusSnapshot?

    monitor.check { result = $0 }

    XCTAssertEqual(result?.authorizationStatus, .authorized)
    XCTAssertNil(result?.suppressesNotifications)
  }

  func testUnavailableCheckDoesNotTouchSystemCenter() {
    let center = FakeNativeFocusStatusCenter(status: .authorized, isFocused: true)
    let checkedAt = Date(timeIntervalSince1970: 84)
    let monitor = NativeFocusStatusMonitor(
      center: center,
      isAvailable: { false },
      now: { checkedAt })
    var result: NativeNotificationFocusSnapshot?

    monitor.check { result = $0 }

    XCTAssertEqual(
      result,
      NativeNotificationFocusSnapshot(
        authorizationStatus: .unavailable,
        suppressesNotifications: nil,
        checkedAt: checkedAt))
    XCTAssertEqual(center.authorizationReadCount, 0)
    XCTAssertEqual(center.focusStatusReadCount, 0)
    XCTAssertEqual(center.authorizationRequestCount, 0)
  }
}

final class NativeFocusTroubleshootingPresentationTests: XCTestCase {
  func testUncheckedStateExplainsExplicitTroubleshootingAndFirstPermission() {
    let presentation = NativeFocusTroubleshootingPresentation(.notChecked)

    XCTAssertTrue(presentation.message.contains("Troubleshooting only"))
    XCTAssertTrue(presentation.message.contains("may ask"))
    XCTAssertEqual(presentation.tone, .normal)
    XCTAssertEqual(presentation.buttonTitle, "Check Focus Blocking…")
    XCTAssertFalse(presentation.showsOpenSettings)
  }

  func testAuthorizedSilencedStateIsFactualWarning() {
    let checkedAt = Date(timeIntervalSince1970: 42)
    let presentation = NativeFocusTroubleshootingPresentation(
      NativeNotificationFocusSnapshot(
        authorizationStatus: .authorized,
        suppressesNotifications: true,
        checkedAt: checkedAt))

    XCTAssertTrue(presentation.message.contains("At the last check"))
    XCTAssertTrue(presentation.message.contains("was silencing Laban"))
    XCTAssertTrue(presentation.message.contains("Allowed Apps"))
    XCTAssertEqual(presentation.tone, .warning)
    XCTAssertEqual(presentation.settingsDestination, .focus)
    XCTAssertEqual(presentation.settingsButtonTitle, "Open Focus Settings")
  }

  func testAuthorizedFalseStateUsesHistoricalCopy() {
    let checkedAt = Date(timeIntervalSince1970: 42)
    let presentation = NativeFocusTroubleshootingPresentation(
      NativeNotificationFocusSnapshot(
        authorizationStatus: .authorized,
        suppressesNotifications: false,
        checkedAt: checkedAt))

    XCTAssertTrue(presentation.message.contains("At the last check"))
    XCTAssertTrue(presentation.message.contains("was not silencing Laban notifications"))
    XCTAssertFalse(presentation.message.contains("currently"))
    XCTAssertEqual(presentation.tone, .normal)
  }

  func testAuthorizedNilDoesNotClaimFocusIsOff() {
    let presentation = NativeFocusTroubleshootingPresentation(
      NativeNotificationFocusSnapshot(
        authorizationStatus: .authorized,
        suppressesNotifications: nil))

    XCTAssertTrue(presentation.message.contains("did not provide a result"))
    XCTAssertFalse(presentation.message.contains("was not silencing"))
    XCTAssertEqual(presentation.tone, .warning)
  }

  func testDeniedRestrictedAndUnavailableRemainInconclusiveWarnings() {
    for status: NativeNotificationFocusAuthorizationStatus in [
      .denied, .restricted, .unavailable, .unknown, .notDetermined,
    ] {
      let presentation = NativeFocusTroubleshootingPresentation(
        NativeNotificationFocusSnapshot(
          authorizationStatus: status,
          suppressesNotifications: nil))
      XCTAssertEqual(presentation.tone, .warning, status.rawValue)
      XCTAssertFalse(presentation.message.contains("was not silencing"), status.rawValue)
    }
  }

  func testDeniedAndActiveFocusOfferDifferentSettingsDestinations() {
    let denied = NativeFocusTroubleshootingPresentation(
      NativeNotificationFocusSnapshot(
        authorizationStatus: .denied,
        suppressesNotifications: nil,
        checkedAt: Date(timeIntervalSince1970: 42)))
    let activeFocus = NativeFocusTroubleshootingPresentation(
      NativeNotificationFocusSnapshot(
        authorizationStatus: .authorized,
        suppressesNotifications: true,
        checkedAt: Date(timeIntervalSince1970: 42)))

    XCTAssertEqual(denied.settingsDestination, .focusStatusPrivacy)
    XCTAssertEqual(denied.settingsButtonTitle, "Open Focus Status Privacy")
    XCTAssertTrue(
      denied.settingsDestination?.urls.first?.absoluteString.contains("Privacy_Focus") == true)
    XCTAssertEqual(activeFocus.settingsDestination, .focus)
    XCTAssertEqual(activeFocus.settingsButtonTitle, "Open Focus Settings")
    XCTAssertTrue(
      activeFocus.settingsDestination?.urls.first?.absoluteString.contains("Focus-Settings")
        == true)
  }

  func testRestrictedStateDoesNotOfferSettingsAction() {
    let restricted = NativeFocusTroubleshootingPresentation(
      NativeNotificationFocusSnapshot(
        authorizationStatus: .restricted,
        suppressesNotifications: nil,
        checkedAt: Date(timeIntervalSince1970: 42)))

    XCTAssertNil(restricted.settingsDestination)
    XCTAssertFalse(restricted.showsOpenSettings)
  }
}

final class NativeFocusLocalizationTests: XCTestCase {
  func testFocusTroubleshootingStringsAreLocalizedInEverySupportedLocale() throws {
    let keys = [
      "Focus troubleshooting:",
      "Check Focus Blocking…",
      "Check Again…",
      "Checking Focus…",
      "Focus is checked only when you press the troubleshooting button. Laban never reads or requests Focus Status during launch or normal notification delivery.",
      "Checks whether the current Focus is silencing Laban. The first check may ask for Focus Status permission.",
      "Troubleshooting only: check whether the current Focus is silencing Laban. This may ask for Focus Status permission.",
      "Focus Status permission was not decided, so Laban could not tell whether Focus was silencing notifications.",
      "Focus Status access was restricted, so Laban could not tell whether Focus was silencing notifications.",
      "Focus Status access was denied. Enable it in Privacy & Security to let Laban diagnose Focus blocking.",
      "Focus was silencing Laban notifications. Add Laban to the active Focus's Allowed Apps.",
      "Focus was not silencing Laban notifications.",
      "Focus Status access was authorized, but macOS did not provide a result for this build.",
      "Focus troubleshooting was unavailable in this build.",
      "macOS returned an unknown Focus Status authorization state, so Laban could not diagnose Focus blocking.",
      "At the last check (%@): %@",
      "Open Focus Status Privacy",
      "Open Focus Settings",
      "Open Privacy & Security > Focus to grant Laban Focus Status access.",
      "Open Focus settings to add Laban to the active Focus's Allowed Apps.",
      "Laban checks whether an active Focus is silencing terminal-attention notifications when you explicitly run Focus troubleshooting.",
    ]
    let locales = [
      "zh-Hans", "zh-Hant", "ja", "ko", "fr", "es", "hi", "ru", "de", "pt-BR", "it",
    ]

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let catalogURL =
      repositoryRoot.appendingPathComponent("Sources/LabanApp/Resources/Localizable.xcstrings")
    let data = try Data(contentsOf: catalogURL)
    let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let catalogStrings = try XCTUnwrap(catalog["strings"] as? [String: Any])

    for key in keys {
      let entry = try XCTUnwrap(catalogStrings[key] as? [String: Any], "missing key: \(key)")
      let localizations = try XCTUnwrap(
        entry["localizations"] as? [String: Any], "missing localizations: \(key)")

      for locale in locales {
        let localization = try XCTUnwrap(
          localizations[locale] as? [String: Any], "missing \(locale): \(key)")
        let unit = try XCTUnwrap(
          localization["stringUnit"] as? [String: Any], "missing unit for \(locale): \(key)")
        XCTAssertEqual(unit["state"] as? String, "translated", "\(locale): \(key)")
        let value = try XCTUnwrap(unit["value"] as? String, "missing value for \(locale): \(key)")
        XCTAssertFalse(value.isEmpty, "\(locale): \(key)")
        XCTAssertNotEqual(value, key, "untranslated \(locale): \(key)")
      }
    }

    XCTAssertEqual(Set(catalogStrings.keys).intersection(keys).count, keys.count)
  }
}

final class NativeFocusTroubleshootingLayoutTests: XCTestCase {
  func testFrenchFocusActionsStackVerticallyWithinSettingsWidth() {
    let checkButton = NSButton(
      title: "Vérifier le blocage par Concentration…", target: nil, action: nil)
    let settingsButton = NSButton(
      title: "Ouvrir la confidentialité de Concentration", target: nil, action: nil)
    let column = SettingsWindowController.makeFocusTroubleshootingButtonColumn(
      checkButton: checkButton,
      settingsButton: settingsButton)

    XCTAssertEqual(column.orientation, .vertical)
    XCTAssertEqual(column.alignment, .leading)
    XCTAssertEqual(column.arrangedSubviews, [checkButton, settingsButton])

    let label = NSTextField(labelWithString: "Dépannage de Concentration :")
    let fixedSettingsMargins: CGFloat = 20 + 20 + 12 + 12 + 10
    let availableActionWidth = 560 - fixedSettingsMargins - label.fittingSize.width
    XCTAssertLessThanOrEqual(
      column.fittingSize.width,
      availableActionWidth,
      "the longest French Focus action must fit beside its grid label")
    XCTAssertLessThan(
      column.fittingSize.width,
      checkButton.fittingSize.width + 8 + settingsButton.fittingSize.width,
      "vertical actions must consume the widest intrinsic width, not their combined width")
  }
}

private final class FakeNativeFocusStatusCenter: NativeFocusStatusCenterAccess {
  private let status: INFocusStatusAuthorizationStatus
  private let isFocused: Bool?
  var requestResult: INFocusStatusAuthorizationStatus = .denied
  var authorizationReadCount = 0
  var focusStatusReadCount = 0
  var authorizationRequestCount = 0

  init(status: INFocusStatusAuthorizationStatus, isFocused: Bool?) {
    self.status = status
    self.isFocused = isFocused
  }

  var authorizationStatus: INFocusStatusAuthorizationStatus {
    authorizationReadCount += 1
    return status
  }

  var focusStatusIsFocused: Bool? {
    focusStatusReadCount += 1
    return isFocused
  }

  func requestAuthorization(
    completion: @escaping (INFocusStatusAuthorizationStatus) -> Void
  ) {
    authorizationRequestCount += 1
    completion(requestResult)
  }
}
