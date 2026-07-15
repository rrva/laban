import Foundation
import LabanCore

public struct ControlSecurityContext: Sendable, Equatable {
  public let intentID: String?
  public let capability: Capability?
  public let surface: Surface
  public let sessionID: String?
  public let timestamp: Date

  public init(
    intentID: String?,
    capability: Capability?,
    surface: Surface,
    sessionID: String?,
    timestamp: Date = Date()
  ) {
    self.intentID = intentID
    self.capability = capability
    self.surface = surface
    self.sessionID = sessionID
    self.timestamp = timestamp
  }
}

public enum ControlSecurityDenyReason: String, Sendable, Equatable {
  case peerCredential
  case unauthorized
  case forbiddenCapability
  case forbiddenScope
  case surfaceUnavailable
}

public protocol ControlSecurityObserver: AnyObject, Sendable {
  func didAuthorize(_ context: ControlSecurityContext)
  func didDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason)
  func didPrivilegedActivity(_ context: ControlSecurityContext)
  func didAttachAuthorize(_ context: ControlSecurityContext)
  func didAttachRequest(_ context: ControlSecurityContext)
  func didAttachApprove(_ context: ControlSecurityContext, mode: String)
  func didAttachDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason)
  func didAttachRevoke(_ context: ControlSecurityContext)
  func didAttachAutoApprove(_ context: ControlSecurityContext, approvalID: String)
}

extension ControlSecurityObserver {
  public func didAttachAuthorize(_ context: ControlSecurityContext) {}
  public func didAttachRequest(_ context: ControlSecurityContext) {}
  public func didAttachApprove(_ context: ControlSecurityContext, mode: String) {}
  public func didAttachDeny(_ context: ControlSecurityContext, reason: ControlSecurityDenyReason) {}
  public func didAttachRevoke(_ context: ControlSecurityContext) {}
  public func didAttachAutoApprove(_ context: ControlSecurityContext, approvalID: String) {}
}

extension LabanControlPolicy {
  public static let privilegedCapabilities: Set<Capability> = [
    .observeSensitive, .navigate, .propose, .diagnosticControl,
  ]

  public static func isPrivileged(_ capability: Capability) -> Bool {
    privilegedCapabilities.contains(capability)
  }
}
