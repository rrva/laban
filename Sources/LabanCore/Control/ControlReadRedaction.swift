import Foundation

/// How much terminal content to include in shared control read projections.
public enum ControlReadRedaction: String, Sendable, Equatable, Codable {
  /// Full wire (fixture token).
  case none
  /// App-observe file token: process/workspace metadata only (no find needles, agent metadata, etc.).
  case appObserveSummary
  /// Session-observe token: only session identity, no titles, process names, or workspace metadata.
  case sessionObserveSummary
}

public enum ControlSessionAttachPolicy {
  /// Agent-attached sessions receive a single-use C14 attach bootstrap in their
  /// launch environment only when `LABAN_CONTROL_ATTACH_ENV=1` is set. The
  /// redeemer verifies the peer is the `laban-agent` executable and a direct
  /// child of the registered shell PID, so inheriting the env is not sufficient
  /// to redeem.
  public static var injectBootstrapIntoEnvironment: Bool {
    true
  }
}
