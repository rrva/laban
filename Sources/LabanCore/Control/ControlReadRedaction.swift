import Foundation

/// How much terminal content to include in shared control read projections.
public enum ControlReadRedaction: String, Sendable, Equatable, Codable {
  /// Full wire (fixture token, session-observe token).
  case none
  /// App-observe file token: process/workspace metadata only (no find needles, agent metadata, etc.).
  case appObserveSummary
}

public enum ControlSessionAttachPolicy {
  /// C10 env-secrecy fallback: bootstrap injection is opt-in until the macOS/SIP matrix gate passes.
  public static var injectBootstrapIntoEnvironment: Bool {
    ProcessInfo.processInfo.environment[ControlEnvironmentKeys.attachEnvOptIn] == "1"
  }
}
