import Foundation
import LabanCore

public enum TokenScope: Sendable, Equatable {
  case wholeApp
  case session(String)
}

public enum ControlTokenTier: Sendable, Equatable {
  case appObserve
  case sessionObserve(sessionID: String)
  case fixture
}

public struct LabanControlPolicy: Sendable {
  private static let sessionScopedCapabilities: Set<Capability> = [
    .observeSensitive, .navigate, .propose,
  ]

  public static func grants(for tier: ControlTokenTier) -> Set<Capability> {
    switch tier {
    case .appObserve:
      return [.observe]
    case .sessionObserve:
      return [.observe, .observeSensitive, .navigate, .propose]
    case .fixture:
      return [.fixture, .observe, .observeSensitive, .navigate, .propose, .input]
    }
  }

  public static func tokenScope(for tier: ControlTokenTier) -> TokenScope {
    switch tier {
    case .appObserve, .fixture:
      return .wholeApp
    case .sessionObserve(let sessionID):
      return .session(sessionID)
    }
  }

  public static func authorize(
    intentID: String,
    catalog: IntentCatalog,
    granted: Set<Capability>,
    targetSession: String?,
    tokenScope: TokenScope
  ) -> Bool {
    guard let descriptor = catalog.descriptor(id: intentID) else {
      return false
    }
    let required = descriptor.requiredCapability
    guard granted.contains(required) else {
      return false
    }
    guard sessionScopedCapabilities.contains(required) else {
      return true
    }

    switch tokenScope {
    case .wholeApp:
      return true
    case .session(let ownSessionID):
      let effectiveTarget = targetSession ?? ownSessionID
      return effectiveTarget == ownSessionID
    }
  }
}
