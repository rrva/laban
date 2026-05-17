import Foundation

/// Persistent kill switch for the workspace persistence subsystem.
///
/// The single user-facing toggle "Restore on Launch" lives here. It gates
/// every save and load path through `PersistenceCoordinator` and
/// `PersistenceStore`, the M1 transcript writers, and the M2 agent
/// detector + JSONL mirror. When off, on-disk state is left in place so
/// the user can re-enable and recover.
///
/// CRITICAL: callers MUST read through `isEnabled`, never via
/// `UserDefaults.standard.bool(forKey:)` directly. `bool(forKey:)` returns
/// `false` for a missing key, which would invert the intended default
/// on fresh installs. The helper uses `object(forKey:) as? Bool ?? true`
/// so an absent key yields `true`.
public enum RestoreOnLaunchSettings {
  public static let key = "LabanRestoreOnLaunch"

  public static var isEnabled: Bool {
    (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
  }

  public static func set(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: key)
  }
}
