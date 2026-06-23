import Foundation
import LabanCore

enum AttentionNotificationPolicy {
  static func suppressionReason(
    for event: AttentionNotificationEvent,
    isTabFrontmost: (Tab.ID) -> Bool,
    isCategoryEnabled: (AttentionNotificationCategory) -> Bool
  ) -> AttentionNotificationSuppressionReason? {
    if isTabFrontmost(event.tabId) {
      return .frontmostTab
    }
    if !isCategoryEnabled(event.category) {
      return .categoryDisabled
    }
    return nil
  }

  static func suppressedDecision(
    for event: AttentionNotificationEvent,
    isTabFrontmost: (Tab.ID) -> Bool,
    isCategoryEnabled: (AttentionNotificationCategory) -> Bool
  ) -> AttentionNotificationDecision? {
    guard
      let reason = suppressionReason(
        for: event,
        isTabFrontmost: isTabFrontmost,
        isCategoryEnabled: isCategoryEnabled)
    else { return nil }
    return AttentionNotificationDecision(
      event: event, action: .suppressed, suppressionReason: reason)
  }
}
