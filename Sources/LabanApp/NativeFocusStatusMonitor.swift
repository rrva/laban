import Foundation
import Intents
import LabanCore

protocol NativeFocusStatusCenterAccess: AnyObject {
  var authorizationStatus: INFocusStatusAuthorizationStatus { get }
  var focusStatusIsFocused: Bool? { get }

  func requestAuthorization(
    completion: @escaping (INFocusStatusAuthorizationStatus) -> Void)
}

final class SystemNativeFocusStatusCenter: NativeFocusStatusCenterAccess {
  private let center: INFocusStatusCenter

  init(center: INFocusStatusCenter = .default) {
    self.center = center
  }

  var authorizationStatus: INFocusStatusAuthorizationStatus {
    center.authorizationStatus
  }

  var focusStatusIsFocused: Bool? {
    center.focusStatus.isFocused
  }

  func requestAuthorization(
    completion: @escaping (INFocusStatusAuthorizationStatus) -> Void
  ) {
    center.requestAuthorization(completionHandler: completion)
  }
}

/// Performs one explicit Focus troubleshooting check.
///
/// Nothing in this type runs until Settings calls `check`. In particular,
/// launch, notification submission, native notification refresh, and debug
/// endpoint polling must not read or request Focus Status.
final class NativeFocusStatusMonitor {
  static let shared = NativeFocusStatusMonitor()

  private let center: NativeFocusStatusCenterAccess
  private let isAvailable: () -> Bool
  private let now: () -> Date

  init(
    center: NativeFocusStatusCenterAccess = SystemNativeFocusStatusCenter(),
    isAvailable: @escaping () -> Bool = { true },
    now: @escaping () -> Date = Date.init
  ) {
    self.center = center
    self.isAvailable = isAvailable
    self.now = now
  }

  func check(completion: @escaping (NativeNotificationFocusSnapshot) -> Void) {
    guard isAvailable() else {
      completion(
        NativeNotificationFocusSnapshot(
          authorizationStatus: .unavailable,
          suppressesNotifications: nil,
          checkedAt: now()))
      return
    }

    let status = center.authorizationStatus
    guard status == .notDetermined else {
      completion(snapshot(for: status))
      return
    }

    let now = self.now
    center.requestAuthorization { [weak self] resolvedStatus in
      guard let self else {
        completion(
          NativeNotificationFocusSnapshot(
            authorizationStatus: .unavailable,
            suppressesNotifications: nil,
            checkedAt: now()))
        return
      }
      completion(self.snapshot(for: resolvedStatus))
    }
  }

  private func snapshot(
    for status: INFocusStatusAuthorizationStatus
  ) -> NativeNotificationFocusSnapshot {
    let authorizationStatus = Self.authorizationStatus(status)
    let suppressesNotifications =
      authorizationStatus == .authorized ? center.focusStatusIsFocused : nil
    return NativeNotificationFocusSnapshot(
      authorizationStatus: authorizationStatus,
      suppressesNotifications: suppressesNotifications,
      checkedAt: now())
  }

  static func authorizationStatus(
    _ status: INFocusStatusAuthorizationStatus
  ) -> NativeNotificationFocusAuthorizationStatus {
    switch status {
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    case .denied: return .denied
    case .authorized: return .authorized
    @unknown default: return .unknown
    }
  }
}

enum NativeFocusSettingsDestination: Equatable {
  case focusStatusPrivacy
  case focus

  var urls: [URL] {
    let candidates: [String]
    switch self {
    case .focusStatusPrivacy:
      candidates = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Focus",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Focus",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
      ]
    case .focus:
      candidates = [
        "x-apple.systempreferences:com.apple.Focus-Settings.extension"
      ]
    }
    return candidates.compactMap(URL.init(string:))
  }
}

struct NativeFocusTroubleshootingPresentation: Equatable {
  enum Tone: Equatable {
    case normal
    case warning
  }

  var message: String
  var tone: Tone
  var buttonTitle: String
  var settingsDestination: NativeFocusSettingsDestination?
  var settingsButtonTitle: String?
  var settingsToolTip: String?

  var showsOpenSettings: Bool { settingsDestination != nil }

  init(_ snapshot: NativeNotificationFocusSnapshot) {
    buttonTitle =
      snapshot.authorizationStatus == .notChecked
      ? L10n.tr("Check Focus Blocking…")
      : L10n.tr("Check Again…")
    settingsDestination = nil
    settingsButtonTitle = nil
    settingsToolTip = nil

    let statusMessage: String

    switch (snapshot.authorizationStatus, snapshot.suppressesNotifications) {
    case (.notChecked, _):
      statusMessage = L10n.tr(
        "Troubleshooting only: check whether the current Focus is silencing Laban. This may ask for Focus Status permission."
      )
      tone = .normal
    case (.notDetermined, _):
      statusMessage = L10n.tr(
        "Focus Status permission was not decided, so Laban could not tell whether Focus was silencing notifications."
      )
      tone = .warning
    case (.restricted, _):
      statusMessage = L10n.tr(
        "Focus Status access was restricted, so Laban could not tell whether Focus was silencing notifications."
      )
      tone = .warning
    case (.denied, _):
      statusMessage = L10n.tr(
        "Focus Status access was denied. Enable it in Privacy & Security to let Laban diagnose Focus blocking."
      )
      tone = .warning
      settingsDestination = .focusStatusPrivacy
      settingsButtonTitle = L10n.tr("Open Focus Status Privacy")
      settingsToolTip = L10n.tr(
        "Open Privacy & Security > Focus to grant Laban Focus Status access.")
    case (.authorized, .some(true)):
      statusMessage = L10n.tr(
        "Focus was silencing Laban notifications. Add Laban to the active Focus's Allowed Apps.")
      tone = .warning
      settingsDestination = .focus
      settingsButtonTitle = L10n.tr("Open Focus Settings")
      settingsToolTip = L10n.tr(
        "Open Focus settings to add Laban to the active Focus's Allowed Apps.")
    case (.authorized, .some(false)):
      statusMessage = L10n.tr("Focus was not silencing Laban notifications.")
      tone = .normal
    case (.authorized, .none):
      statusMessage = L10n.tr(
        "Focus Status access was authorized, but macOS did not provide a result for this build.")
      tone = .warning
    case (.unavailable, _):
      statusMessage = L10n.tr("Focus troubleshooting was unavailable in this build.")
      tone = .warning
    case (.unknown, _):
      statusMessage = L10n.tr(
        "macOS returned an unknown Focus Status authorization state, so Laban could not diagnose Focus blocking."
      )
      tone = .warning
    }

    if let checkedAt = snapshot.checkedAt {
      let formattedDate = DateFormatter.localizedString(
        from: checkedAt, dateStyle: .short, timeStyle: .short)
      message = String(
        format: L10n.tr("At the last check (%@): %@"),
        formattedDate,
        statusMessage)
    } else {
      message = statusMessage
    }
  }
}
