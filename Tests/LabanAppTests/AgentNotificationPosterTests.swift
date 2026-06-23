import LabanCore
import UserNotifications
import XCTest

@testable import LabanApp

final class AgentNotificationPosterTests: XCTestCase {
  func testNotDeterminedAuthorizationRequestsPermissionThenPostsWhenGranted() {
    let center = FakeAttentionNotificationCenter(status: .notDetermined)
    center.authorizationGrant = true
    let explainer = FakePermissionExplainer()
    let poster = AgentNotificationPoster(
      center: center,
      permissionExplainer: explainer,
      requiresBundleIdentifier: false)
    let exp = expectation(description: "decision")

    poster.post(event: makeEvent(), soundEnabled: true) { decision in
      XCTAssertEqual(decision.action, .posted)
      XCTAssertNil(decision.suppressionReason)
      exp.fulfill()
    }

    wait(for: [exp], timeout: 1.0)
    XCTAssertEqual(center.requestAuthorizationCallCount, 1)
    XCTAssertEqual(center.addedRequests.count, 1)
    XCTAssertEqual(center.addedRequests[0].content.body, "Approval requested")
    XCTAssertEqual(center.addedRequests[0].content.threadIdentifier, "tab-tab-1")
    XCTAssertNotNil(center.addedRequests[0].content.sound)
    XCTAssertEqual(explainer.showCount, 0)
  }

  func testDeniedAuthorizationSuppressesAndExplainsHowToEnableNotifications() {
    let center = FakeAttentionNotificationCenter(status: .denied)
    let explainer = FakePermissionExplainer()
    let poster = AgentNotificationPoster(
      center: center,
      permissionExplainer: explainer,
      requiresBundleIdentifier: false)
    let exp = expectation(description: "decision")

    poster.post(event: makeEvent(), soundEnabled: false) { decision in
      XCTAssertEqual(decision.action, .suppressed)
      XCTAssertEqual(decision.suppressionReason, .authorizationDenied)
      exp.fulfill()
    }

    wait(for: [exp], timeout: 1.0)
    XCTAssertTrue(center.addedRequests.isEmpty)
    XCTAssertEqual(explainer.showCount, 1)
  }

  func testAuthorizedButAlertStyleNoneSuppressesAndExplains() {
    let center = FakeAttentionNotificationCenter(status: .authorized)
    center.settings.alertStyle = .none
    let explainer = FakePermissionExplainer()
    let poster = AgentNotificationPoster(
      center: center,
      permissionExplainer: explainer,
      requiresBundleIdentifier: false)
    let exp = expectation(description: "decision")

    poster.post(event: makeEvent(), soundEnabled: false) { decision in
      XCTAssertEqual(decision.action, .suppressed)
      XCTAssertEqual(decision.suppressionReason, .authorizationDenied)
      exp.fulfill()
    }

    wait(for: [exp], timeout: 1.0)
    XCTAssertTrue(center.addedRequests.isEmpty)
    XCTAssertEqual(explainer.showCount, 1)
  }

  func testNotificationAddErrorRecordsDeliveryFailure() {
    let center = FakeAttentionNotificationCenter(status: .authorized)
    center.addError = TestError()
    let poster = AgentNotificationPoster(
      center: center,
      permissionExplainer: FakePermissionExplainer(),
      requiresBundleIdentifier: false)
    let exp = expectation(description: "decision")

    poster.post(event: makeEvent(), soundEnabled: false) { decision in
      XCTAssertEqual(decision.action, .suppressed)
      XCTAssertEqual(decision.suppressionReason, .deliveryFailed)
      exp.fulfill()
    }

    wait(for: [exp], timeout: 1.0)
    XCTAssertEqual(center.addedRequests.count, 1)
  }

  private func makeEvent() -> AttentionNotificationEvent {
    AttentionNotificationEvent(
      id: "event-1",
      tabId: "tab-1",
      source: .osc,
      category: .needsAction,
      title: "Tab 1",
      body: "Approval requested",
      dedupeKey: "test")
  }
}

private final class FakeAttentionNotificationCenter: AttentionNotificationCenterPosting {
  var settings: AttentionNotificationSystemSettings
  var authorizationGrant = true
  var authorizationError: Error?
  var addError: Error?
  var addedRequests: [UNNotificationRequest] = []
  var requestAuthorizationCallCount = 0

  init(status: UNAuthorizationStatus) {
    self.settings = AttentionNotificationSystemSettings(
      authorizationStatus: status,
      alertSetting: .enabled,
      notificationCenterSetting: .enabled,
      soundSetting: .enabled,
      alertStyle: .banner)
  }

  func getNotificationSettings(
    _ completion: @escaping (AttentionNotificationSystemSettings) -> Void
  ) {
    completion(settings)
  }

  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @escaping (Bool, Error?) -> Void
  ) {
    requestAuthorizationCallCount += 1
    settings.authorizationStatus = authorizationGrant ? .authorized : .denied
    completionHandler(authorizationGrant, authorizationError)
  }

  func add(_ request: UNNotificationRequest, completionHandler: @escaping (Error?) -> Void) {
    addedRequests.append(request)
    completionHandler(addError)
  }
}

private final class FakePermissionExplainer: AttentionNotificationPermissionExplaining {
  var showCount = 0

  func explainNotificationsDisabled() {
    showCount += 1
  }
}

private struct TestError: Error {}
