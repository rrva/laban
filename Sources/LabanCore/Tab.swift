enum AppError: Error {
    case tabLimitReached
    case tabNotFound
}

struct Tab {
    typealias ID = String

    let id: ID
    var position: Int
    var title: String
    var isActive: Bool
    let sessionId: Session.ID
}
