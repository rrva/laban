import Foundation

/// Which terminal identity spawned sessions advertise via `TERM_PROGRAM` /
/// `TERM_PROGRAM_VERSION`. Ecosystem tools gate features on recognized
/// identities — OSC 9;4 progress bars notably — so a compatibility mode that
/// claims ghostty unlocks them in programs that have never heard of Laban.
public enum TerminalIdentity: String, CaseIterable, Codable, Sendable {
  /// Honest identity: `TERM_PROGRAM=Laban` with Laban's own version.
  case laban
  /// Claim ghostty 1.3.1: unlocks identity-gated features in tools that
  /// special-case known terminals and would treat Laban as a dumb unknown.
  case ghosttyCompat = "ghostty-compat"

  public var termProgram: String {
    switch self {
    case .laban: return "Laban"
    case .ghosttyCompat: return "ghostty"
    }
  }

  public var termProgramVersion: String {
    switch self {
    case .laban: return TerminalIdentitySettings.labanVersion
    case .ghosttyCompat: return "1.3.1"
    }
  }

  public var environmentOverrides: [String: String] {
    [
      "TERM_PROGRAM": termProgram,
      "TERM_PROGRAM_VERSION": termProgramVersion,
    ]
  }
}

public enum TerminalIdentitySettings {
  public static let defaultsKey = "LabanTerminalIdentity"

  /// Laban's own version for `TERM_PROGRAM_VERSION`: the marketing version
  /// when bundled, else the stamped build commit, else a dev marker (SPM
  /// test runs have no app bundle).
  public static var labanVersion: String {
    let info = Bundle.main.infoDictionary
    return (info?["CFBundleShortVersionString"] as? String)
      ?? (info?["LABANBuildCommit"] as? String)
      ?? "dev"
  }

  public static func identity(defaults: UserDefaults = .standard) -> TerminalIdentity {
    guard let raw = defaults.string(forKey: defaultsKey),
      let parsed = TerminalIdentity(rawValue: raw)
    else { return .laban }
    return parsed
  }

  public static func set(_ identity: TerminalIdentity, defaults: UserDefaults = .standard) {
    defaults.set(identity.rawValue, forKey: defaultsKey)
  }
}

extension ShellIntegrationLaunch {
  /// The launch with the configured terminal identity merged in. Identity
  /// values lose to explicit per-launch overrides of the same names.
  public func withTerminalIdentity(_ identity: TerminalIdentity) -> ShellIntegrationLaunch {
    var launch = self
    launch.environmentOverrides.merge(identity.environmentOverrides) { current, _ in current }
    return launch
  }
}
