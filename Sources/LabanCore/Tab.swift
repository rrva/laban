public enum AppError: Error, Equatable {
  case tabLimitReached
  case tabNotFound
}

public struct Tab {
  public typealias ID = String

  public let id: ID
  public var position: Int
  public var title: String
  public var isActive: Bool
  public let sessionId: Session.ID
}
