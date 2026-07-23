import Foundation

/// User-configurable switch for the sidebar hover preview: a floating,
/// live, miniature rendering of a background tab's recent scrollback text,
/// shown while hovering that tab's sidebar row
/// (execplans/active/sidebar-hover-preview.md).
///
/// Ships default-OFF per the repo's opt-in posture. The effective renderer
/// being non-Slug disables the feature at the call site, independent of this
/// setting (see docs/adr/0031-sidebar-hover-preview-is-a-slug-capability.md).
///
/// CRITICAL: callers MUST read through the static accessors, never via
/// `UserDefaults.standard.bool(forKey:)` directly, to get correct
/// missing-key defaults. Pattern copied from `SpinnerMotionSmoothingSettings`.
public enum HoverPreviewSettings {
  /// User-default override: `defaults write com.rrva.Laban
  /// LabanSidebarHoverPreviewEnabled -bool YES` + relaunch.
  public static let enabledKey = "LabanSidebarHoverPreviewEnabled"

  /// Environment override for headless/debug runs
  /// (`LABAN_SIDEBAR_HOVER_PREVIEW_ENABLED=1`); wins over the user default
  /// so scenario fixtures can enable the feature without touching user defaults.
  /// While set, `setEnabled` refuses writes — the env is the control plane.
  public static let enabledEnvironmentKey = "LABAN_SIDEBAR_HOVER_PREVIEW_ENABLED"

  /// Posted on the main queue whenever the setting changes.
  public static let didChangeNotification = Notification.Name(
    "LabanSidebarHoverPreviewSettingsDidChange")

  /// Parsed env override, or `nil` when the variable is unset. Truthy values:
  /// `1` / `true` / `yes` / `on` / `enabled` (case-insensitive).
  public static func environmentOverride(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool? {
    guard let env = environment[enabledEnvironmentKey] else { return nil }
    switch env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on", "enabled":
      return true
    default:
      return false
    }
  }

  /// Whether the sidebar hover preview is enabled. Defaults to `false` when
  /// the key is absent. Env override wins over UserDefaults when present.
  public static var enabled: Bool {
    enabled(
      defaults: .standard,
      environment: ProcessInfo.processInfo.environment)
  }

  public static func enabled(
    defaults: UserDefaults,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if let override = environmentOverride(environment: environment) {
      return override
    }
    return (defaults.object(forKey: enabledKey) as? Bool) ?? false
  }

  /// Persist the setting and post `didChangeNotification`.
  ///
  /// Returns `false` without writing when `LABAN_SIDEBAR_HOVER_PREVIEW_ENABLED`
  /// is set — the env is the fixture control plane and must not be silently
  /// overridden by a UserDefaults write that `enabled` would then ignore.
  @discardableResult
  public static func setEnabled(
    _ enabled: Bool,
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    guard environmentOverride(environment: environment) == nil else { return false }
    defaults.set(enabled, forKey: enabledKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
    return true
  }
}
