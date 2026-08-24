import Foundation

/// User-configurable switch for the tab sidebar. Turning it off hides the
/// sidebar entirely and gives its width back to the terminal grid, so the
/// terminal reflows to more columns.
///
/// Ships default-ON: the sidebar is shipped MVP behaviour
/// (`docs/product/mvp.md`), so hiding it is the opt-in change, not the default.
///
/// CRITICAL: callers MUST read through the static accessors, never via
/// `UserDefaults.standard.bool(forKey:)` directly, or a missing key reads as
/// `false` and silently hides the sidebar. Pattern copied from
/// `HoverPreviewSettings`.
public enum SidebarVisibilitySettings {
  /// User-default override: `defaults write com.laban.LabanApp
  /// LabanSidebarVisible -bool NO`.
  public static let visibleKey = "LabanSidebarVisible"

  /// Environment override for headless/debug runs (`LABAN_SIDEBAR_VISIBLE=0`);
  /// wins over the user default so scenario fixtures can pin the layout without
  /// touching user defaults. While set, `setVisible` refuses writes — the env is
  /// the control plane.
  public static let visibleEnvironmentKey = "LABAN_SIDEBAR_VISIBLE"

  /// Posted on the main queue whenever the setting changes.
  public static let didChangeNotification = Notification.Name(
    "LabanSidebarVisibilitySettingsDidChange")

  /// Parsed env override, or `nil` when the variable is unset. Truthy values:
  /// `1` / `true` / `yes` / `on` / `enabled` (case-insensitive).
  public static func environmentOverride(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool? {
    guard let env = environment[visibleEnvironmentKey] else { return nil }
    switch env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on", "enabled":
      return true
    default:
      return false
    }
  }

  /// The env override resolved once, at first use. A process's environment
  /// cannot change after launch, and `ProcessInfo.processInfo.environment`
  /// materialises the whole environment on every access, so re-parsing per read
  /// is pure waste on a value the layout path consults.
  private static let cachedEnvironmentOverride: Bool? = environmentOverride()

  /// Whether the tab sidebar is shown. Defaults to `true` when the key is
  /// absent. Env override wins over UserDefaults when present.
  public static var visible: Bool {
    visible(defaults: .standard, override: cachedEnvironmentOverride)
  }

  public static func visible(
    defaults: UserDefaults,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    visible(defaults: defaults, override: environmentOverride(environment: environment))
  }

  /// Single home for the missing-key default, shared by the cached hot path and
  /// the injectable test seam so the two cannot drift.
  private static func visible(defaults: UserDefaults, override: Bool?) -> Bool {
    if let override {
      return override
    }
    return (defaults.object(forKey: visibleKey) as? Bool) ?? true
  }

  /// Persist the setting and post `didChangeNotification`.
  ///
  /// Returns `false` without writing when `LABAN_SIDEBAR_VISIBLE` is set — the
  /// env is the fixture control plane and must not be silently overridden by a
  /// write that `visible` would then ignore.
  @discardableResult
  public static func setVisible(
    _ visible: Bool,
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    guard environmentOverride(environment: environment) == nil else { return false }
    defaults.set(visible, forKey: visibleKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
    return true
  }

  /// The sidebar's effective width: its layout width when shown, zero when
  /// hidden. Every geometry, hit-test and mouse-routing site already keys off
  /// the width (`pt.x < sidebarWidth`, `termW = w - sidebarWidth …`), so a zero
  /// width disables the whole sidebar surface without a second flag threaded
  /// through those 20-odd call sites.
  public static func effectiveWidth(_ layoutWidth: CGFloat, visible: Bool) -> CGFloat {
    visible ? layoutWidth : 0
  }
}
