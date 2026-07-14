import UserNotifications
import XCTest

@testable import LabanApp

final class NativeNotificationResponseHandlerTests: XCTestCase {
  func testDefaultTapFocusesOriginatingTabAndActivatesApplication() {
    var activated = 0
    var focusedTabIds: [String] = []
    var completions = 0
    let handler = makeHandler(
      activateApplication: { activated += 1 },
      focusTab: {
        focusedTabIds.append($0)
        return true
      })

    handler.handle(
      actionIdentifier: UNNotificationDefaultActionIdentifier,
      userInfo: ["tabId": "tab-2"],
      completion: { completions += 1 })

    XCTAssertEqual(focusedTabIds, ["tab-2"])
    XCTAssertEqual(activated, 1)
    XCTAssertEqual(completions, 1)
  }

  func testDefaultTapWithStaleTabActivatesWithoutSelectingAnotherTab() {
    var activated = 0
    var focusedTabIds: [String] = []
    var completions = 0
    let handler = makeHandler(
      activateApplication: { activated += 1 },
      focusTab: {
        focusedTabIds.append($0)
        return false
      })

    handler.handle(
      actionIdentifier: UNNotificationDefaultActionIdentifier,
      userInfo: ["tabId": "closed-tab"],
      completion: { completions += 1 })

    XCTAssertEqual(focusedTabIds, ["closed-tab"])
    XCTAssertEqual(activated, 1)
    XCTAssertEqual(completions, 1)
  }

  func testDefaultTapWithMissingOrMalformedTabIdOnlyActivatesApplication() {
    for userInfo: [AnyHashable: Any] in [[:], ["tabId": 42], ["tabId": ""]] {
      var activated = 0
      var focusCalls = 0
      var completions = 0
      let handler = makeHandler(
        activateApplication: { activated += 1 },
        focusTab: { _ in
          focusCalls += 1
          return true
        })

      handler.handle(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        userInfo: userInfo,
        completion: { completions += 1 })

      XCTAssertEqual(focusCalls, 0)
      XCTAssertEqual(activated, 1)
      XCTAssertEqual(completions, 1)
    }
  }

  func testNonDefaultActionDoesNothingAndStillCompletesExactlyOnce() {
    var activated = 0
    var focusCalls = 0
    var completions = 0
    let handler = makeHandler(
      activateApplication: { activated += 1 },
      focusTab: { _ in
        focusCalls += 1
        return true
      })

    handler.handle(
      actionIdentifier: UNNotificationDismissActionIdentifier,
      userInfo: ["tabId": "tab-2"],
      completion: { completions += 1 })

    XCTAssertEqual(focusCalls, 0)
    XCTAssertEqual(activated, 0)
    XCTAssertEqual(completions, 1)
  }

  func testCompletionRunsAfterMainThreadRoutingOperation() throws {
    var pendingOperation: (() -> Void)?
    var completions = 0
    let handler = NativeNotificationResponseHandler(
      activateApplication: {},
      focusTab: { _ in true },
      runOnMain: { pendingOperation = $0 })

    handler.handle(
      actionIdentifier: UNNotificationDefaultActionIdentifier,
      userInfo: ["tabId": "tab-2"],
      completion: { completions += 1 })

    XCTAssertEqual(completions, 0)
    try XCTUnwrap(pendingOperation)()
    XCTAssertEqual(completions, 1)
  }

  private func makeHandler(
    activateApplication: @escaping () -> Void,
    focusTab: @escaping (String) -> Bool
  ) -> NativeNotificationResponseHandler {
    NativeNotificationResponseHandler(
      activateApplication: activateApplication,
      focusTab: focusTab,
      runOnMain: { $0() })
  }
}
