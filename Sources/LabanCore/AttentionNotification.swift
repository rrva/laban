import Foundation

/// User-facing class of a tab attention event. These are policy inputs for
/// native notifications; tab metadata remains the source of truth for sidebar
/// state.
public enum AttentionNotificationCategory: String, Codable, Equatable, Sendable {
  case needsAction
  case completion
  case passive
}

public enum AttentionNotificationSource: String, Codable, Equatable, Sendable {
  case bell
  case osc
  case tabAttention
}

public struct AttentionNotificationEvent: Codable, Equatable, Sendable {
  public var id: String
  public var tabId: Tab.ID
  public var source: AttentionNotificationSource
  public var category: AttentionNotificationCategory
  public var title: String
  public var body: String
  public var dedupeKey: String
  public var createdAt: Date

  public init(
    id: String = UUID().uuidString,
    tabId: Tab.ID,
    source: AttentionNotificationSource,
    category: AttentionNotificationCategory,
    title: String,
    body: String,
    dedupeKey: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.tabId = tabId
    self.source = source
    self.category = category
    self.title = title
    self.body = body
    self.dedupeKey = dedupeKey
    self.createdAt = createdAt
  }
}

public enum AttentionNotificationAction: String, Codable, Equatable, Sendable {
  case posted
  case suppressed
}

public enum AttentionNotificationSuppressionReason: String, Codable, Equatable, Sendable {
  case frontmostTab
  case categoryDisabled
  case emptyBody
  case bundleUnavailable
  case authorizationDenied
  case deliveryFailed
  case restoreSuppression
  /// The agent's debounced OSC arrived inside an await episode whose title-flip
  /// banner already announced the wait; a non-urgent merge carries no new call
  /// to action, so a second banner would be a duplicate.
  case mergedIntoAwaitEpisode
}

public struct AttentionNotificationDecision: Codable, Equatable, Sendable {
  public var event: AttentionNotificationEvent
  public var action: AttentionNotificationAction
  public var suppressionReason: AttentionNotificationSuppressionReason?
  public var decidedAt: Date

  public init(
    event: AttentionNotificationEvent,
    action: AttentionNotificationAction,
    suppressionReason: AttentionNotificationSuppressionReason? = nil,
    decidedAt: Date = Date()
  ) {
    self.event = event
    self.action = action
    self.suppressionReason = suppressionReason
    self.decidedAt = decidedAt
  }
}

extension AttentionNotificationCategory {
  public init?(_ attention: TabAttention) {
    switch attention {
    case .none: return nil
    case .needsAction: self = .needsAction
    case .done: self = .completion
    case .passive: self = .passive
    }
  }
}
