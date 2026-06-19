import Foundation

/// How a freshly created terminal session should start treating Unicode display
/// width — the per-session DEC private mode 2027 (grapheme-cluster / "Unicode
/// core" width) default.
///
/// Mode 2027 changes who decides the cell width of complex Unicode (emoji,
/// flags, ZWJ sequences, combining marks): with it OFF each Unicode scalar is
/// measured on its own (legacy `wcwidth`); with it ON the engine segments the
/// stream into grapheme clusters and assigns each cluster one width, so `👩‍🌾`
/// occupies 2 cells instead of 4.
///
/// This is a *starting default* for new sessions only. A running program still
/// turns the mode on/off at runtime with `ESC [ ? 2027 h` / `l`, which overrides
/// the configured default — matching Ghostty's model. Live sessions are never
/// retroactively toggled (that would force a mid-session grid reflow).
public enum GraphemeWidthMode: String, CaseIterable, Codable, Sendable {
  /// Today's behavior and the safe default: a new session starts with mode 2027
  /// OFF; programs opt in by sending `ESC [ ? 2027 h`. Enabling clustering
  /// unilaterally is known to break shells that assume legacy `wcwidth` (the
  /// `fish` breakage documented in the mode-2027 ExecPlan Decision Log).
  case auto
  /// A new session starts with mode 2027 ON, so emoji and clusters use grapheme
  /// width immediately even for programs that never negotiate it; a program can
  /// still turn it off with `ESC [ ? 2027 l`.
  case preferGrapheme
}

public enum GraphemeWidthSettings {
  public static let defaultsKey = "LabanGraphemeWidthMode"

  /// Posted on the main queue whenever the mode changes.
  public static let didChangeNotification = Notification.Name(
    "LabanGraphemeWidthSettingsDidChange")

  /// The user's preferred starting width mode for new sessions. Defaults to
  /// `.auto` when the key is absent (fresh install) or holds an unknown value.
  public static func current(defaults: UserDefaults = .standard) -> GraphemeWidthMode {
    guard let raw = defaults.string(forKey: defaultsKey),
      let parsed = GraphemeWidthMode(rawValue: raw)
    else { return .auto }
    return parsed
  }

  public static func set(_ mode: GraphemeWidthMode, defaults: UserDefaults = .standard) {
    defaults.set(mode.rawValue, forKey: defaultsKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
