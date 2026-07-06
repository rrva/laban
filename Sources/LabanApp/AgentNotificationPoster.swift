import AppKit
import Foundation
import LabanCore
import UserNotifications

protocol AttentionNotificationCenterPosting {
  func getNotificationSettings(
    _ completion: @escaping (AttentionNotificationSystemSettings) -> Void)
  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @escaping (Bool, Error?) -> Void)
  func add(_ request: UNNotificationRequest, completionHandler: @escaping (Error?) -> Void)
}

struct AttentionNotificationSystemSettings: Equatable {
  var authorizationStatus: UNAuthorizationStatus
  var alertSetting: UNNotificationSetting
  var notificationCenterSetting: UNNotificationSetting
  var soundSetting: UNNotificationSetting
  var alertStyle: UNAlertStyle

  var canShowAlert: Bool {
    switch authorizationStatus {
    case .authorized, .provisional:
      return alertSetting == .enabled && alertStyle != .none
    default:
      return false
    }
  }
}

protocol AttentionNotificationPermissionExplaining: AnyObject {
  func explainNotificationsDisabled()
}

private final class SystemAttentionNotificationCenter: AttentionNotificationCenterPosting {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func getNotificationSettings(
    _ completion: @escaping (AttentionNotificationSystemSettings) -> Void
  ) {
    center.getNotificationSettings { settings in
      completion(
        AttentionNotificationSystemSettings(
          authorizationStatus: settings.authorizationStatus,
          alertSetting: settings.alertSetting,
          notificationCenterSetting: settings.notificationCenterSetting,
          soundSetting: settings.soundSetting,
          alertStyle: settings.alertStyle))
    }
  }

  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @escaping (Bool, Error?) -> Void
  ) {
    center.requestAuthorization(options: options, completionHandler: completionHandler)
  }

  func add(_ request: UNNotificationRequest, completionHandler: @escaping (Error?) -> Void) {
    center.add(request, withCompletionHandler: completionHandler)
  }
}

final class AttentionNotificationPermissionExplainer:
  AttentionNotificationPermissionExplaining
{
  private var didShowDeniedHelp = false

  func explainNotificationsDisabled() {
    guard !didShowDeniedHelp else { return }
    didShowDeniedHelp = true

    let alert = NSAlert()
    alert.messageText = L10n.tr("Notifications are off for Laban")
    alert.informativeText =
      L10n.tr(
        "Enable Laban in System Settings > Notifications, and choose Banners or Alerts, to receive tab attention notifications.")
    alert.addButton(withTitle: L10n.tr("Open Settings"))
    alert.addButton(withTitle: L10n.tr("OK"))
    let response = alert.runModal()
    if response == .alertFirstButtonReturn,
      let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    {
      NSWorkspace.shared.open(url)
    }
  }
}

/// Posts native macOS notifications for unified tab-attention events.
///
/// Authorization is requested lazily. The completion reports the actual
/// authorization/delivery outcome so AppModel's tab metadata, tab journal, and
/// debug state do not claim that a banner posted when macOS rejected it.
final class AgentNotificationPoster {
  private let center: AttentionNotificationCenterPosting
  private let permissionExplainer: AttentionNotificationPermissionExplaining
  private let requiresBundleIdentifier: Bool
  private var authorizationRequestInFlight = false
  private var authorizationWaiters: [(Bool, Error?) -> Void] = []

  init(
    center: AttentionNotificationCenterPosting = SystemAttentionNotificationCenter(),
    permissionExplainer: AttentionNotificationPermissionExplaining =
      AttentionNotificationPermissionExplainer(),
    requiresBundleIdentifier: Bool = true
  ) {
    self.center = center
    self.permissionExplainer = permissionExplainer
    self.requiresBundleIdentifier = requiresBundleIdentifier
  }

  func post(
    event: AttentionNotificationEvent,
    soundEnabled: Bool,
    completion: @escaping (AttentionNotificationDecision) -> Void
  ) {
    let body = event.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      finish(
        AttentionNotificationDecision(
          event: event, action: .suppressed, suppressionReason: .emptyBody),
        completion: completion)
      return
    }
    // UNUserNotificationCenter.current() traps without a real app bundle; guard
    // so a non-bundled host (tooling, some test rigs) cannot crash here.
    guard !requiresBundleIdentifier || Bundle.main.bundleIdentifier != nil else {
      finish(
        AttentionNotificationDecision(
          event: event, action: .suppressed, suppressionReason: .bundleUnavailable),
        completion: completion)
      return
    }

    center.getNotificationSettings { [weak self] settings in
      guard let self else { return }
      self.logSettings(settings, event: event)
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        guard settings.canShowAlert else {
          self.explainNotificationsDisabled()
          self.finish(
            AttentionNotificationDecision(
              event: event, action: .suppressed, suppressionReason: .authorizationDenied),
            completion: completion)
          return
        }
        self.submit(
          event: event,
          body: body,
          soundEnabled: soundEnabled,
          completion: completion)
      case .notDetermined:
        self.requestAuthorization { granted, error in
          if error != nil {
            self.logDelivery(
              event: event,
              outcome: "authorizationRequestFailed",
              error: error)
            self.finish(
              AttentionNotificationDecision(
                event: event, action: .suppressed, suppressionReason: .deliveryFailed),
              completion: completion)
          } else if granted {
            self.center.getNotificationSettings { settings in
              self.logSettings(settings, event: event)
              guard settings.canShowAlert else {
                self.explainNotificationsDisabled()
                self.finish(
                  AttentionNotificationDecision(
                    event: event,
                    action: .suppressed,
                    suppressionReason: .authorizationDenied),
                  completion: completion)
                return
              }
              self.submit(
                event: event,
                body: body,
                soundEnabled: soundEnabled,
                completion: completion)
            }
          } else {
            self.explainNotificationsDisabled()
            self.finish(
              AttentionNotificationDecision(
                event: event, action: .suppressed, suppressionReason: .authorizationDenied),
              completion: completion)
          }
        }
      case .denied:
        self.explainNotificationsDisabled()
        self.finish(
          AttentionNotificationDecision(
            event: event, action: .suppressed, suppressionReason: .authorizationDenied),
          completion: completion)
      @unknown default:
        self.finish(
          AttentionNotificationDecision(
            event: event, action: .suppressed, suppressionReason: .deliveryFailed),
          completion: completion)
      }
    }
  }

  private func submit(
    event: AttentionNotificationEvent,
    body: String,
    soundEnabled: Bool,
    completion: @escaping (AttentionNotificationDecision) -> Void
  ) {
    logDelivery(event: event, outcome: "submit", error: nil)
    let content = UNMutableNotificationContent()
    let trimmedTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
    content.title = trimmedTitle.isEmpty ? L10n.tr("Terminal") : trimmedTitle
    content.body = body
    content.threadIdentifier = "tab-\(event.tabId)"
    content.userInfo = [
      "tabId": event.tabId,
      "source": event.source.rawValue,
      "category": event.category.rawValue,
      "eventId": event.id,
      "dedupeKey": event.dedupeKey,
    ]
    content.interruptionLevel = event.category == .passive ? .passive : .active
    if soundEnabled {
      content.sound = .default
    }
    let request = UNNotificationRequest(
      identifier: event.id, content: content, trigger: nil)
    center.add(request) { [weak self] error in
      guard let self else { return }
      self.logDelivery(
        event: event,
        outcome: error == nil ? "added" : "addFailed",
        error: error)
      let decision =
        error == nil
        ? AttentionNotificationDecision(event: event, action: .posted)
        : AttentionNotificationDecision(
          event: event, action: .suppressed, suppressionReason: .deliveryFailed)
      self.finish(decision, completion: completion)
    }
  }

  private func requestAuthorization(_ completion: @escaping (Bool, Error?) -> Void) {
    DispatchQueue.main.async {
      if self.authorizationRequestInFlight {
        self.authorizationWaiters.append(completion)
        return
      }
      self.authorizationRequestInFlight = true
      self.authorizationWaiters.append(completion)
      self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        DispatchQueue.main.async {
          self.authorizationRequestInFlight = false
          let waiters = self.authorizationWaiters
          self.authorizationWaiters.removeAll()
          for waiter in waiters {
            waiter(granted, error)
          }
        }
      }
    }
  }

  private func explainNotificationsDisabled() {
    DispatchQueue.main.async {
      self.permissionExplainer.explainNotificationsDisabled()
    }
  }

  private func finish(
    _ decision: AttentionNotificationDecision,
    completion: @escaping (AttentionNotificationDecision) -> Void
  ) {
    DispatchQueue.main.async {
      EventLog.shared.log(
        "attention.notification.decision",
        [
          "eventId": decision.event.id,
          "tabId": decision.event.tabId,
          "category": decision.event.category.rawValue,
          "source": decision.event.source.rawValue,
          "action": decision.action.rawValue,
          "reason": decision.suppressionReason?.rawValue ?? "",
        ])
      completion(decision)
    }
  }

  private func logSettings(
    _ settings: AttentionNotificationSystemSettings,
    event: AttentionNotificationEvent
  ) {
    EventLog.shared.log(
      "attention.notification.settings",
      [
        "eventId": event.id,
        "tabId": event.tabId,
        "authorizationStatus": authorizationStatusName(settings.authorizationStatus),
        "alertSetting": notificationSettingName(settings.alertSetting),
        "notificationCenterSetting": notificationSettingName(
          settings.notificationCenterSetting),
        "soundSetting": notificationSettingName(settings.soundSetting),
        "alertStyle": alertStyleName(settings.alertStyle),
        "canShowAlert": settings.canShowAlert,
      ])
  }

  private func logDelivery(
    event: AttentionNotificationEvent,
    outcome: String,
    error: Error?
  ) {
    var payload: [String: Any] = [
      "eventId": event.id,
      "tabId": event.tabId,
      "category": event.category.rawValue,
      "source": event.source.rawValue,
      "outcome": outcome,
    ]
    if let error {
      let nsError = error as NSError
      payload["errorDomain"] = nsError.domain
      payload["errorCode"] = nsError.code
      payload["errorDescription"] = nsError.localizedDescription
    }
    EventLog.shared.log("attention.notification.delivery", payload)
  }

  private func authorizationStatusName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    @unknown default: return "unknown"
    }
  }

  private func notificationSettingName(_ setting: UNNotificationSetting) -> String {
    switch setting {
    case .notSupported: return "notSupported"
    case .disabled: return "disabled"
    case .enabled: return "enabled"
    @unknown default: return "unknown"
    }
  }

  private func alertStyleName(_ style: UNAlertStyle) -> String {
    switch style {
    case .none: return "none"
    case .banner: return "banner"
    case .alert: return "alert"
    @unknown default: return "unknown"
    }
  }
}
