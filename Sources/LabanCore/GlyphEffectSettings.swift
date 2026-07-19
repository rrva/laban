import Foundation

/// User-configurable switch for the per-glyph animation channel
/// (execplans/active/per-glyph-animation-channel.md): ink-bloom type-in and
/// the visual bell shake.
///
/// Ships default-OFF per the repo's opt-in posture (ADR 0017/0022/0027);
/// promotion to default-on is a separate spec.md decision. Reduce Motion
/// force-disables the effects at the call site (see
/// `GlyphEffectTimeline.effectiveKind`), independent of this setting.
///
/// CRITICAL: callers MUST read through the static accessors, never via
/// `UserDefaults.standard.bool(forKey:)` directly, to get correct
/// missing-key defaults. Pattern copied from `CursorSettings`.
public enum GlyphEffectSettings {
  /// User-default override: `defaults write com.rrva.Laban
  /// LabanGlyphEffectsEnabled -bool YES` + relaunch.
  public static let enabledKey = "LabanGlyphEffectsEnabled"
  /// Environment override for headless/debug runs
  /// (`LABAN_GLYPH_EFFECTS_ENABLED=1`); wins over the user default so
  /// scenario fixtures can enable effects without touching user defaults.
  public static let enabledEnvironmentKey = "LABAN_GLYPH_EFFECTS_ENABLED"

  /// Posted on the main queue whenever the setting changes.
  public static let didChangeNotification = Notification.Name("LabanGlyphEffectSettingsDidChange")

  /// Whether per-glyph effects are enabled. Defaults to `false` when the key
  /// is absent.
  public static var enabled: Bool {
    if let env = ProcessInfo.processInfo.environment[enabledEnvironmentKey] {
      return env == "1" || env.lowercased() == "true" || env.lowercased() == "yes"
    }
    return (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? false
  }

  public static func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: enabledKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
