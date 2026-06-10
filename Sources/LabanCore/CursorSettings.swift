import Foundation
import LabanTerminalCore

/// User-configurable cursor appearance settings.
///
/// Stores the user's preferred cursor style and blink state in `UserDefaults`.
/// A running program's DECSCUSR request overrides the style while active; these
/// settings govern the quiescent (no-override) state. Defaults are solid block
/// with blink OFF so a fully idle terminal needs zero blink wakeups.
///
/// CRITICAL: callers MUST read through the static accessors, never via
/// `UserDefaults.standard.string/bool(forKey:)` directly, to get correct
/// missing-key defaults. Pattern copied from `RestoreOnLaunchSettings`.
public enum CursorSettings {

  // MARK: - Style

  /// Cursor shape options that map directly onto the LABAN_CURSOR_STYLE_* C enum.
  public enum Style: String, CaseIterable, Sendable {
    case block
    case bar
    case underline

    /// Maps the Swift style to the C `LABAN_CURSOR_STYLE_*` constant used by
    /// `FrameProducer.cursorRects(style:cellRect:)`.
    public var labanStyleValue: Int32 {
      switch self {
      case .block:     return Int32(LABAN_CURSOR_STYLE_BLOCK)
      case .bar:       return Int32(LABAN_CURSOR_STYLE_BAR)
      case .underline: return Int32(LABAN_CURSOR_STYLE_UNDERLINE)
      }
    }
  }

  // MARK: - UserDefaults keys

  public static let styleKey = "LabanCursorStyle"
  public static let blinkKey = "LabanCursorBlink"

  // MARK: - Notification

  /// Posted on the main queue whenever either setting changes.
  public static let didChangeNotification = Notification.Name("LabanCursorSettingsDidChange")

  // MARK: - Accessors

  /// The user's preferred cursor style. Defaults to `.block` when the key is
  /// absent (fresh install or removed key).
  public static var style: Style {
    guard let raw = UserDefaults.standard.object(forKey: styleKey) as? String,
          let parsed = Style(rawValue: raw)
    else { return .block }
    return parsed
  }

  /// Whether cursor blink is enabled. Defaults to `false` (solid) when the key
  /// is absent so an idle focused terminal needs zero blink wakeups.
  public static var blinkEnabled: Bool {
    (UserDefaults.standard.object(forKey: blinkKey) as? Bool) ?? false
  }

  // MARK: - Setters

  public static func setStyle(_ style: Style) {
    UserDefaults.standard.set(style.rawValue, forKey: styleKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  public static func setBlinkEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: blinkKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
