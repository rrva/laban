import LabanCore
import XCTest

@testable import LabanApp

final class AttentionNotificationPolicyTests: XCTestCase {
  func testFrontmostTabSuppressesBeforeCategorySetting() {
    let event = makeEvent(category: .needsAction)
    let decision = AttentionNotificationPolicy.suppressedDecision(
      for: event,
      isTabFrontmost: { _ in true },
      isCategoryEnabled: { _ in false })

    XCTAssertEqual(decision?.action, .suppressed)
    XCTAssertEqual(decision?.suppressionReason, .frontmostTab)
  }

  func testDisabledCategorySuppresses() {
    let event = makeEvent(category: .completion)
    let decision = AttentionNotificationPolicy.suppressedDecision(
      for: event,
      isTabFrontmost: { _ in false },
      isCategoryEnabled: { $0 != .completion })

    XCTAssertEqual(decision?.action, .suppressed)
    XCTAssertEqual(decision?.suppressionReason, .categoryDisabled)
  }

  func testAllowedBackgroundEventIsNotSuppressed() {
    let event = makeEvent(category: .needsAction)
    let decision = AttentionNotificationPolicy.suppressedDecision(
      for: event,
      isTabFrontmost: { _ in false },
      isCategoryEnabled: { $0 == .needsAction })

    XCTAssertNil(decision)
  }

  private func makeEvent(
    category: AttentionNotificationCategory
  ) -> AttentionNotificationEvent {
    AttentionNotificationEvent(
      id: "event-1",
      tabId: "tab-1",
      source: .tabAttention,
      category: category,
      title: "Tab 1",
      body: "Tab needs attention.",
      dedupeKey: "test")
  }
}
