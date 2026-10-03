import Foundation

/// Whether rows holding right-to-left text (Hebrew, Arabic, ...) are shown in
/// visual order (implicit BiDi). On by default; applications that do their
/// own BiDi reordering can be served by turning it off, which restores the
/// strictly left-to-right, logical-order display.
public enum BidiDisplaySettings {
  public static let defaultsKey = "LabanBidiDisplay"

  /// Posted on the main queue whenever the setting changes.
  public static let didChangeNotification = Notification.Name(
    "LabanBidiDisplaySettingsDidChange")

  public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: defaultsKey) as? Bool ?? true
  }

  public static func set(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
