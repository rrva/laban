import Foundation

/// Whether macOS Option should map to terminal Alt/Meta.
///
/// Laban historically preserved current macOS behavior where Option-modified
/// input is handled by AppKit as text first (`Option` + symbol yields a
/// Unicode character, and the session sees the character bytes). Enabling this
/// setting makes Option pass through to the terminal key encoder as `ALT`,
/// which is the behavior required by many terminal apps and shells.
public enum OptionKeySettings {
  public static let defaultsKey = "LabanOptionAsMeta"

  /// Posted whenever any caller writes the setting.
  public static let didChangeNotification = Notification.Name("LabanOptionKeySettingsDidChange")

  /// Whether the setting is enabled for newly created key events. Defaults to
  /// `false` (Option acts as text, matching today).
  public static func current(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: defaultsKey) as? Bool ?? false
  }

  /// Persist the setting and notify observers.
  public static func set(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}

