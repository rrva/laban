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

  public init(
    id: ID,
    position: Int,
    title: String,
    isActive: Bool,
    sessionId: Session.ID,
    status: TabStatus = .running,
    titleMetadata: TabTitleMetadata? = nil
  ) {
    self.id = id
    self.position = position
    self.isActive = isActive
    self.sessionId = sessionId
    self.status = status

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
