import Foundation

/// Turns off the macOS press-and-hold accent panel for Laban so a held key
/// repeats instead.
///
/// `TerminalBitmapView` is an `NSTextInputClient`, which is what the accent
/// panel keys off: hold an accentable letter (a, e, k, u, …) and AppKit shows
/// the diacritic picker and suppresses key repeat entirely for that press.
/// A terminal needs the opposite — shells, editors, and TUIs all treat a held
/// key as a repeating key — so opt out for this process.
///
/// The value goes into the registration domain, not Laban's own defaults
/// plist, on purpose: registration is last in the `UserDefaults` search order,
/// so nothing is written behind the user's back and an explicit
///
///     defaults write com.laban.LabanApp ApplePressAndHoldEnabled -bool true
///
/// (or the same key in `NSGlobalDomain`) still wins and brings the panel back.
enum PressAndHoldSettings {
  static let key = "ApplePressAndHoldEnabled"

  /// Register the opt-out. Must run before the first key event reaches a text
  /// input client — the input system reads the default at press time — so this
  /// belongs at the top of application launch.
  static func disableAccentPanel(defaults: UserDefaults = .standard) {
    defaults.register(defaults: [key: false])
  }
}
