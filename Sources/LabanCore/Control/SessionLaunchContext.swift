import Foundation

/// Preallocated identity and env overrides composed before a `Session` is created (C11).
public struct SessionLaunchContext: Equatable, Sendable {
  public let sessionID: Session.ID
  public let tabID: Tab.ID?
  public let isAgentAttached: Bool
  public var environmentOverrides: [String: String]
  /// Single-use C14 bootstrap value placed in `LABAN_SESSION_ATTACH` when set.
  public var sessionObserveBootstrap: String?

  public init(
    sessionID: Session.ID,
    tabID: Tab.ID? = nil,
    isAgentAttached: Bool = false,
    environmentOverrides: [String: String] = [:],
    sessionObserveBootstrap: String? = nil
  ) {
    self.sessionID = sessionID
    self.tabID = tabID
    self.isAgentAttached = isAgentAttached
    self.environmentOverrides = environmentOverrides
    self.sessionObserveBootstrap = sessionObserveBootstrap
  }

  public static func fresh(
    tabID: Tab.ID? = nil,
    isAgentAttached: Bool = false
  ) -> SessionLaunchContext {
    SessionLaunchContext(
      sessionID: UUID().uuidString,
      tabID: tabID,
      isAgentAttached: isAgentAttached)
  }
}

public enum ControlEnvironmentKeys {
  public static let controlURL = "LABAN_CONTROL_URL"
  public static let sessionAttach = "LABAN_SESSION_ATTACH"
  /// URL of the `laban-agent` session proxy socket for descendants launched by
  /// `laban agent run -- <command>`. This is a session-scoped credential.
  public static let agentControlURL = "LABAN_AGENT_CONTROL_URL"
  /// When set to `"0"`, the GUI control server does not start (force-disable).
  public static let controlServerForceDisable = "LABAN_CONTROL_SERVER"
  /// When set to `"1"`, agent-attached sessions receive `LABAN_SESSION_ATTACH`
  /// through env for explicit development / E2E attach paths.
  public static let attachEnvOptIn = "LABAN_CONTROL_ATTACH_ENV"
  /// When set to `"1"` (or `--agent-attached-session`), the first tab is agent-attached (C13).
  public static let agentAttachedSessionAtLaunch = "LABAN_AGENT_ATTACHED_SESSION"
}
