import Foundation
import LabanCore

/// User preferences for posting native macOS notifications from tab attention
/// events. The legacy `defaultsKey` continues to migrate the old BEL-only
/// checkbox into passive/BEL notifications.
enum AttentionNotificationSettings {
  static let defaultsKey = "LabanAttentionSystemNotifications"
  static let needsActionKey = "LabanAttentionNotifyNeedsAction"
  static let completionKey = "LabanAttentionNotifyCompletion"
  static let passiveKey = "LabanAttentionNotifyPassive"
  static let soundKey = "LabanAttentionNotifySound"
  static let didChangeNotification = Notification.Name(
    "LabanAttentionNotificationSettingsDidChange")

  static var needsActionEnabled: Bool {
    bool(forKey: needsActionKey, defaultValue: true)
  }

  static var completionEnabled: Bool {
    bool(forKey: completionKey, defaultValue: false)
  }

  static var passiveEnabled: Bool {
    if let explicit = UserDefaults.standard.object(forKey: passiveKey) as? Bool {
      return explicit
    }
    return (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? false
  }

  static var soundEnabled: Bool {
    bool(forKey: soundKey, defaultValue: false)
  }

  static var isEnabled: Bool {
    passiveEnabled
  }

  static func setEnabled(_ enabled: Bool) {
    setEnabled(enabled, for: .passive)
  }

  static func isEnabled(for category: AttentionNotificationCategory) -> Bool {
    switch category {
    case .needsAction:
      return needsActionEnabled
    case .completion:
      return completionEnabled
    case .passive:
      return passiveEnabled
    }
  }

  static func setEnabled(_ enabled: Bool, for category: AttentionNotificationCategory) {
    let key: String
    switch category {
    case .needsAction:
      key = needsActionKey
    case .completion:
      key = completionKey
    case .passive:
      key = passiveKey
    }
    UserDefaults.standard.set(enabled, forKey: key)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  static func setSoundEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: soundKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
    (UserDefaults.standard.object(forKey: key) as? Bool) ?? defaultValue
  }
}
