import Foundation

/// Persistent user preference for agent-attached startup behavior.
///
/// When enabled, the first session on launch is created as agent-attached and
/// agent-attached sessions receive the C14 attach bootstrap. This is the
/// Settings UI equivalent of `--agent-attached-session`.
enum AgentAttachedSessionSettings {
  static let defaultsKey = "LabanAgentAttachedSessionEnabled"

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: defaultsKey)
  }

  static func set(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: defaultsKey)
  }
}
