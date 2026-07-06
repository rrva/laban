import Foundation

/// Persistent master toggle for the GUI control server (Phase 2 security floor).
///
/// When off, the UDS listener never starts, `control.json` is not written, and
/// no session-observe credential is injected — even if `LABAN_CONTROL_SERVER=1`
/// is set. Default is on (the 2F flip keeps this as the user's escape hatch).
public enum ControlServerSettings {
  public static let key = "LabanControlServerEnabled"

  public static var isEnabled: Bool {
    (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
  }

  public static func set(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: key)
  }
}
