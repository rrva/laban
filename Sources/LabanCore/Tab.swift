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
  public var title: String
  public var isActive: Bool
  public let sessionId: Session.ID
  public var status: TabStatus = .running
}
