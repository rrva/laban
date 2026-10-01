import Foundation

/// User-configurable switch for programming-font ligatures: contextual
/// substitutions such as JetBrains Mono's `->`, `!=`, `===` drawn as one
/// joined glyph that still occupies one terminal cell per source character
/// (execplans/active/font-ligatures.md).
///
/// Ships default-OFF per the repo's opt-in posture, which also keeps the MVP
/// "no ligatures" rendering the shipped default. The effective renderer being
/// non-Slug ignores the setting (see
/// docs/adr/0037-font-ligatures-are-a-slug-capability.md).
public enum FontLigatureSettings {
  /// `defaults write com.rrva.Laban LabanFontLigaturesEnabled -bool YES`.
  public static let enabledKey = "LabanFontLigaturesEnabled"

  /// Environment override for headless/debug runs (`LABAN_FONT_LIGATURES=1`);
  /// wins over the user default so scenario fixtures can enable ligatures
  /// without touching user defaults. While set, `setEnabled` refuses writes.
  public static let enabledEnvironmentKey = "LABAN_FONT_LIGATURES"

  /// Posted whenever the setting changes.
  public static let didChangeNotification = Notification.Name(
    "LabanFontLigatureSettingsDidChange")

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

  /// A process's environment cannot change after launch; resolve it once.
  private static let cachedEnvironmentOverride: Bool? = environmentOverride()

  /// Whether ligatures are enabled. Defaults to `false` when the key is
  /// absent. Env override wins over UserDefaults when present. Renderers cache
  /// this and refresh on `didChangeNotification`; never read it per frame.
  public static var enabled: Bool {
    enabled(defaults: .standard, override: cachedEnvironmentOverride)
  }

  public static func enabled(
    defaults: UserDefaults,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    enabled(defaults: defaults, override: environmentOverride(environment: environment))
  }

  private static func enabled(defaults: UserDefaults, override: Bool?) -> Bool {
    if let override {
      return override
    }
    return (defaults.object(forKey: enabledKey) as? Bool) ?? false
  }

  /// Persist the setting and post `didChangeNotification`. Returns `false`
  /// without writing when `LABAN_FONT_LIGATURES` is set.
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
