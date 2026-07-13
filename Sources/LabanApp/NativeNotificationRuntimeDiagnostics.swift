import Foundation
import LabanCore
import Security
import UserNotifications

final class NativeNotificationStateRefresher: @unchecked Sendable {
  static let shared = NativeNotificationStateRefresher()

  private final class RefreshState: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: NativeNotificationSettingsSnapshot?
    private var pendingCount: Int?
    private var deliveredCount: Int?

    func setSettings(_ settings: NativeNotificationSettingsSnapshot) {
      withLock { self.settings = settings }
    }

    func setPendingCount(_ count: Int) {
      withLock { pendingCount = count }
    }

    func setDeliveredCount(_ count: Int) {
      withLock { deliveredCount = count }
    }

    func snapshot() -> (
      settings: NativeNotificationSettingsSnapshot?, pendingCount: Int?, deliveredCount: Int?
    ) {
      withLock { (settings, pendingCount, deliveredCount) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }
  }

  private let center: UNUserNotificationCenter
  private let store: NativeNotificationDiagnosticsStore

  init(
    center: UNUserNotificationCenter = .current(),
    store: NativeNotificationDiagnosticsStore = .shared
  ) {
    self.center = center
    self.store = store
  }

  func refresh() {
    store.setNativeAvailable(true)
    guard let generation = store.beginRefresh() else { return }

    let group = DispatchGroup()
    let state = RefreshState()

    group.enter()
    center.getNotificationSettings { settings in
      state.setSettings(Self.snapshot(settings))
      group.leave()
    }

    group.enter()
    center.getPendingNotificationRequests { requests in
      state.setPendingCount(requests.count)
      group.leave()
    }

    group.enter()
    center.getDeliveredNotifications { notifications in
      state.setDeliveredCount(notifications.count)
      group.leave()
    }

    group.notify(queue: .global(qos: .utility)) { [store] in
      let result = state.snapshot()
      store.finishRefresh(
        generation: generation,
        settings: result.settings,
        pendingCount: result.pendingCount,
        deliveredCount: result.deliveredCount)
    }
  }

  static func snapshot(_ settings: UNNotificationSettings)
    -> NativeNotificationSettingsSnapshot
  {
    NativeNotificationSettingsSnapshot(
      authorizationStatus: authorizationStatusName(settings.authorizationStatus),
      alertSetting: notificationSettingName(settings.alertSetting),
      notificationCenterSetting: notificationSettingName(settings.notificationCenterSetting),
      soundSetting: notificationSettingName(settings.soundSetting),
      alertStyle: alertStyleName(settings.alertStyle),
      canShowAlert: canShowAlert(settings))
  }

  static func authorizationStatusName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    @unknown default: return "unknown"
    }
  }

  static func notificationSettingName(_ setting: UNNotificationSetting) -> String {
    switch setting {
    case .notSupported: return "notSupported"
    case .disabled: return "disabled"
    case .enabled: return "enabled"
    @unknown default: return "unknown"
    }
  }

  static func alertStyleName(_ style: UNAlertStyle) -> String {
    switch style {
    case .none: return "none"
    case .banner: return "banner"
    case .alert: return "alert"
    @unknown default: return "unknown"
    }
  }

  private static func canShowAlert(_ settings: UNNotificationSettings) -> Bool {
    switch settings.authorizationStatus {
    case .authorized, .provisional:
      return settings.alertSetting == .enabled && settings.alertStyle != .none
    default:
      return false
    }
  }
}

enum NativeNotificationRuntimeIdentityProvider {
  private struct SigningDetails {
    var mode: String
    var teamIdentifier: String?
    var cdHash: String?
  }

  static func snapshot(bundle: Bundle = .main) -> NativeNotificationRuntimeIdentity {
    let signing = signingDetails()
    return NativeNotificationRuntimeIdentity(
      bundleIdentifier: bundle.bundleIdentifier,
      bundlePath: bundle.bundleURL.path,
      buildCommit: BuildInfo.commit,
      buildDate: BuildInfo.date,
      signingMode: signing.mode,
      teamIdentifier: signing.teamIdentifier,
      cdHash: signing.cdHash)
  }

  private static func signingDetails() -> SigningDetails {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else {
      return SigningDetails(mode: "unsigned", teamIdentifier: nil, cdHash: nil)
    }
    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return SigningDetails(mode: "unknown", teamIdentifier: nil, cdHash: nil)
    }

    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information) == errSecSuccess,
      let values = information as? [CFString: Any]
    else {
      return SigningDetails(mode: "unknown", teamIdentifier: nil, cdHash: nil)
    }

    let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String
    let cdHash = (values[kSecCodeInfoUnique] as? Data)?.map {
      String(format: "%02x", $0)
    }.joined()
    let mode: String
    if teamIdentifier != nil {
      mode = "teamSigned"
    } else if cdHash != nil {
      mode = "adHoc"
    } else {
      mode = "unsigned"
    }
    return SigningDetails(
      mode: mode,
      teamIdentifier: teamIdentifier,
      cdHash: cdHash)
  }
}
