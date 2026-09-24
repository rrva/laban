import Foundation
import LabanTerminalCore

/// Whether terminal sessions support the Kitty graphics protocol (inline
/// images). On by default; `defaults write <domain> LabanKittyGraphicsEnabled
/// -bool NO` turns it off, and the `LABAN_KITTY_GRAPHICS=0|1` environment
/// variable overrides both for debugging. A disabled session neither stores
/// images nor answers protocol queries, so programs fall back to text.
///
/// The terminal core reads the setting when a session is created, so hosts
/// call `applyProcessWide()` at startup before any session exists
/// (execplans/active/kitty-graphics-rendering.md).
public enum KittyGraphicsSettings {
  public static let defaultsKey = "LabanKittyGraphicsEnabled"
  public static let environmentKey = "LABAN_KITTY_GRAPHICS"

  public static func isEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    switch environment[environmentKey] {
    case "1": return true
    case "0": return false
    default: break
    }
    guard defaults.object(forKey: defaultsKey) != nil else { return true }
    return defaults.bool(forKey: defaultsKey)
  }

  /// Hands the setting to the terminal core for sessions created from now on.
  public static func applyProcessWide(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    laban_set_kitty_graphics_enabled(isEnabled(defaults: defaults, environment: environment))
  }
}
