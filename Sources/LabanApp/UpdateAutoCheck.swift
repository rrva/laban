import Foundation

/// Auto-check policy — pure decision logic for "should we hit the manifest now?"
/// The actual network call goes through `UpdateChecker.check`; this only gates it.
enum UpdateAutoCheck {
  static let lastCheckDefaultsKey = "LabanUpdateLastCheck"

  /// 4 hours between background checks. Manual menu action ignores this.
  static let pollInterval: TimeInterval = 4 * 60 * 60

  enum SkipReason: Equatable {
    case unstampedDevBuild
    case manifestURLMissing
    case checkedRecently
  }

  enum Decision: Equatable {
    case check
    case skip(SkipReason)
  }

  /// What prompted the check. A `launch` always checks — a fresh start is the
  /// user's clearest signal that they want the latest. The cooldown only
  /// throttles a process that is already running, so the coarse timer and the
  /// activate / wake notifications do not hammer the manifest.
  enum Trigger: Equatable {
    case launch
    case running
  }

  /// 0.0.0 means swift run / unstamped — never auto-check.
  /// A configured manifest URL is required; otherwise auto-checks are a no-op.
  /// `lastCheck` is the timestamp of the previous successful or attempted check;
  /// it only gates `running` triggers — `launch` ignores it.
  static func decide(
    version: String,
    manifestURLConfigured: Bool,
    lastCheck: Date?,
    now: Date,
    trigger: Trigger = .running,
    interval: TimeInterval = pollInterval
  ) -> Decision {
    if version == "0.0.0" {
      return .skip(.unstampedDevBuild)
    }
    if !manifestURLConfigured {
      return .skip(.manifestURLMissing)
    }
    if trigger == .running, let lastCheck, now.timeIntervalSince(lastCheck) < interval {
      return .skip(.checkedRecently)
    }
    return .check
  }

  static func loadLastCheck(defaults: UserDefaults = .standard) -> Date? {
    let value = defaults.double(forKey: lastCheckDefaultsKey)
    return value > 0 ? Date(timeIntervalSince1970: value) : nil
  }

  static func recordCheck(_ date: Date, defaults: UserDefaults = .standard) {
    defaults.set(date.timeIntervalSince1970, forKey: lastCheckDefaultsKey)
  }
}
