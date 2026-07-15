import Foundation

/// Whether a snapshot writer can distinguish inherited terminal backgrounds
/// from explicit and inverse-video backgrounds.
public enum TerminalSnapshotBackgroundCapability: String, Codable, CaseIterable, Equatable, Sendable {
  /// The app's own terminal core writes the snapshot, so its cell semantics are
  /// known to match this build without protocol negotiation.
  case inProcess
  /// A remote writer advertised `snapshotCellExplicitBackgroundV1`.
  case supported
  /// A remote writer did not advertise explicit-background identity.
  case legacy
}

public enum LabandCapabilities {
  public static let snapshotCellExplicitBackgroundV1 = "snapshotCellExplicitBackgroundV1"
}

extension LabandHelloResponse {
  public var snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability {
    capabilities.contains(LabandCapabilities.snapshotCellExplicitBackgroundV1)
      ? .supported
      : .legacy
  }
}

extension LabandLifecycleDecision {
  /// Typed projection of the negotiated hello capability on a connect
  /// decision. Non-connect decisions have no active snapshot writer yet.
  public var snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability? {
    guard case .connect(_, _, let capabilities) = self else { return nil }
    return capabilities.contains(LabandCapabilities.snapshotCellExplicitBackgroundV1)
      ? .supported
      : .legacy
  }
}
