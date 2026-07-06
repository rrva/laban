import Foundation

/// How much terminal content to include in shared control read projections.
public enum ControlReadRedaction: String, Sendable, Equatable, Codable {
  /// Full wire (fixture token, session-observe token).
  case none
  /// App-observe file token: process/workspace metadata only (no find needles, agent metadata, etc.).
  case appObserveSummary
}

public enum ControlSessionAttachPolicy {
  /// Optional global gate for attach bootstrap injection outside explicit
  /// `isAgentAttached` launches (C10 env-secrecy fallback for future paths).
  public static var injectBootstrapIntoEnvironment: Bool {
    ProcessInfo.processInfo.environment[ControlEnvironmentKeys.attachEnvOptIn] == "1"
  }
}
