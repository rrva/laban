import Foundation
import LabanCore

public enum TokenScope: Sendable, Equatable {
  case wholeApp
  case session(String)
}

public enum ControlTokenTier: Sendable, Equatable {
  case appObserve
  case sessionObserve(sessionID: String)
  case approvedSession(
    sessionID: String, approvalID: String, capabilities: [Capability],
    constraint: ControlTokenConstraint)
  case fixture
}

public struct ControlTokenConstraint: Sendable, Equatable {
  public let method: String
  public let path: String
  public let query: String
  public let bodySHA256: String?
  public let resolvedRouteID: String
  public let resolvedIntentID: String

  public init(
    method: String,
    path: String,
    query: String,
    bodySHA256: String?,
    resolvedRouteID: String,
    resolvedIntentID: String
  ) {
    self.method = method
    self.path = path
    self.query = query
    self.bodySHA256 = bodySHA256
    self.resolvedRouteID = resolvedRouteID
    self.resolvedIntentID = resolvedIntentID
  }
}

public struct LabanControlPolicy: Sendable {
  public static func grants(for tier: ControlTokenTier) -> Set<Capability> {
    switch tier {
    case .appObserve:
      return [.observe]
    case .sessionObserve:
      return [.observe, .observeSensitive, .navigate, .propose]
    case .approvedSession(_, _, let capabilities, _):
      return Set(capabilities)
    case .fixture:
      return [.fixture, .observe, .observeSensitive, .navigate, .propose, .input]
    }
  }

  public static func tokenScope(for tier: ControlTokenTier) -> TokenScope {
    switch tier {
    case .appObserve, .fixture:
      return .wholeApp
    case .sessionObserve(let sessionID), .approvedSession(let sessionID, _, _, _):
      return .session(sessionID)
    }
  }

  public static func authorize(
    intentID: String,
    catalog: IntentCatalog,
    granted: Set<Capability>,
    targetSession: String?,
    tokenScope: TokenScope,
    tokenTier: ControlTokenTier? = nil,
    method: String? = nil,
    path: String? = nil,
    query: String? = nil,
    bodySHA256: String? = nil
  ) -> Bool {
    guard let descriptor = catalog.descriptor(id: intentID) else {
      return false
    }
    let required = descriptor.requiredCapability
    guard granted.contains(required) else {
      return false
    }

    switch tokenScope {
    case .wholeApp:
      return true
    case .session(let ownSessionID):
      let effectiveTarget = targetSession ?? ownSessionID
      guard effectiveTarget == ownSessionID else { return false }
      if case .approvedSession(_, _, _, let constraint) = tokenTier {
        guard let method, let path, let query else { return false }
        guard constraint.method == method else { return false }
        guard constraint.path == path else { return false }
        guard constraint.query == query else { return false }
        guard constraint.bodySHA256 == bodySHA256 else { return false }
        return true
      }
      return true
    }
  }
}
