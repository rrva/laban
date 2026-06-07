import Foundation

public enum AppError: Error, Equatable {
  case tabLimitReached
  case tabNotFound
  case lastTabClosed
}

public enum TabStatus: Equatable {
  case running
  case exited(code: Int)
  case exitedSignal(signal: Int)

  public var debugString: String {
    switch self {
    case .running: return "running"
    case .exited: return "exited"
    case .exitedSignal: return "exited"
    }
  }
}

public struct Tab {
  public typealias ID = String

  public let id: ID
  public var position: Int
  public var title: String {
    get { titleMetadata.displayTitle }
    set {
      guard let userTitle = TerminalTitle.sanitize(newValue) else { return }
      titleMetadata.userTitle = userTitle
      titleMetadata.displayTitle = userTitle
      titleMetadata.titleSource = .user
    }
  }
  public var isActive: Bool
  public let sessionId: Session.ID
  public var status: TabStatus = .running
  public var titleMetadata: TabTitleMetadata
  /// Last output / activity time for this tab's session. Runtime-only (never
  /// persisted) and bumped on every output tick, so it lives on Tab rather than
  /// on TabTitleMetadata: keeping it off the title struct means an output tick
  /// no longer mutates TabTitleMetadata, so it cannot invalidate the sidebar's
  /// metadata-keyed cache or force a per-tick title re-resolve. Read only by the
  /// relative-age subtitle and the debug endpoints.
  public var lastActivityAt: Date?
  public var lastOutputAt: Date?

  public init(
    id: ID,
    position: Int,
    title: String,
    isActive: Bool,
    sessionId: Session.ID,
    status: TabStatus = .running,
    lastActivityAt: Date? = nil,
    lastOutputAt: Date? = nil,
    titleMetadata: TabTitleMetadata? = nil
  ) {
    self.id = id
    self.position = position
    self.isActive = isActive
    self.sessionId = sessionId
    self.status = status
    self.lastActivityAt = lastActivityAt
    self.lastOutputAt = lastOutputAt

    if let titleMetadata {
      self.titleMetadata = TabTitleResolver.resolvedMetadata(
        titleMetadata,
        fallbackPosition: position
      )
    } else if title == "Tab \(position)" {
      self.titleMetadata = TabTitleMetadata.fallback(position: position, active: isActive)
    } else {
      let sanitized = TerminalTitle.sanitize(title) ?? "Tab \(position)"
      self.titleMetadata = TabTitleMetadata(
        userTitle: sanitized,
        displayTitle: sanitized,
        titleSource: .user,
        activityState: isActive ? .active : .background
      )
    }
  }
}
