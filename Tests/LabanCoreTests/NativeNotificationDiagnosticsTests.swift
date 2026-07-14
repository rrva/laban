import Foundation
import XCTest

@testable import LabanCore

final class NativeNotificationDiagnosticsTests: XCTestCase {
  func testRingEvictsOldestEventsAndFiltersBySequence() {
    let store = NativeNotificationDiagnosticsStore(capacity: 2, nativeAvailable: true)

    let first = store.record(
      eventId: "event-1",
      stage: .submit,
      timestamp: Date(timeIntervalSince1970: 1))
    let second = store.record(
      eventId: "event-2",
      stage: .added,
      timestamp: Date(timeIntervalSince1970: 2))
    let third = store.record(
      eventId: "event-3",
      stage: .decision,
      timestamp: Date(timeIntervalSince1970: 3))

    XCTAssertEqual(first, 1)
    XCTAssertEqual(second, 2)
    XCTAssertEqual(third, 3)

    let snapshot = store.snapshot()
    XCTAssertEqual(snapshot.events.map(\.sequence), [2, 3])
    XCTAssertEqual(snapshot.nextSequence, 4)
    XCTAssertEqual(store.snapshot(since: 2).events.map(\.sequence), [2, 3])
  }

  func testNextSequenceCursorReturnsTheNextRecordedEvent() {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: true)
    _ = store.record(eventId: "existing", stage: .submit)

    let cursor = store.snapshot().nextSequence
    _ = store.record(eventId: "next", stage: .added)

    XCTAssertEqual(store.snapshot(since: cursor).events.map(\.eventId), ["next"])
  }

  func testRefreshLifecyclePublishesSettingsAndCounts() throws {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: true)
    let generation = try XCTUnwrap(store.beginRefresh())
    XCTAssertNil(store.beginRefresh())
    XCTAssertTrue(store.snapshot().refreshInFlight)

    let refreshedAt = Date(timeIntervalSince1970: 42)
    let settings = NativeNotificationSettingsSnapshot(
      authorizationStatus: "authorized",
      alertSetting: "enabled",
      notificationCenterSetting: "enabled",
      soundSetting: "disabled",
      alertStyle: "banner",
      canShowAlert: true)
    store.finishRefresh(
      generation: generation,
      settings: settings,
      pendingCount: 3,
      deliveredCount: 5,
      timestamp: refreshedAt)

    let snapshot = store.snapshot()
    XCTAssertFalse(snapshot.refreshInFlight)
    XCTAssertEqual(snapshot.lastRefreshedAt, refreshedAt)
    XCTAssertEqual(snapshot.settings, settings)
    XCTAssertEqual(snapshot.pendingCount, 3)
    XCTAssertEqual(snapshot.deliveredCount, 5)
  }

  func testSettingsObservationDoesNotClaimCountsWereRefreshed() {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: true)
    store.updateSettings(
      NativeNotificationSettingsSnapshot(
        authorizationStatus: "authorized",
        alertSetting: "enabled",
        notificationCenterSetting: "enabled",
        soundSetting: "enabled",
        alertStyle: "banner",
        canShowAlert: true))

    XCTAssertNotNil(store.snapshot().settings)
    XCTAssertNil(store.snapshot().lastRefreshedAt)
  }

  func testLiveFocusStateStartsUncheckedAndChangesOnlyWhenExplicitlyUpdated() {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: true)

    XCTAssertEqual(store.snapshot().focusAuthorizationStatus, .notChecked)
    XCTAssertNil(store.snapshot().focusSuppressesNotifications)
    XCTAssertNil(store.snapshot().focusCheckedAt)

    let checkedAt = Date(timeIntervalSince1970: 42)
    store.updateFocusStatus(
      NativeNotificationFocusSnapshot(
        authorizationStatus: .authorized,
        suppressesNotifications: true,
        checkedAt: checkedAt))

    XCTAssertEqual(store.snapshot().focusAuthorizationStatus, .authorized)
    XCTAssertEqual(store.snapshot().focusSuppressesNotifications, true)
    XCTAssertEqual(store.snapshot().focusCheckedAt, checkedAt)
  }

  func testHeadlessFocusStateIsUnavailable() {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: false)

    XCTAssertEqual(store.snapshot().focusAuthorizationStatus, .unavailable)
    XCTAssertNil(store.snapshot().focusSuppressesNotifications)
    XCTAssertNil(store.snapshot().focusCheckedAt)
  }

  func testStaleRefreshCannotOverwriteNewerRefresh() throws {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: true)
    let first = try XCTUnwrap(store.beginRefresh())
    store.failRefresh(generation: first)
    let second = try XCTUnwrap(store.beginRefresh())

    store.finishRefresh(
      generation: first,
      settings: nil,
      pendingCount: 99,
      deliveredCount: 99,
      timestamp: Date(timeIntervalSince1970: 1))
    XCTAssertTrue(store.snapshot().refreshInFlight)

    store.finishRefresh(
      generation: second,
      settings: nil,
      pendingCount: 1,
      deliveredCount: 2,
      timestamp: Date(timeIntervalSince1970: 2))
    XCTAssertEqual(store.snapshot().pendingCount, 1)
    XCTAssertEqual(store.snapshot().deliveredCount, 2)
  }

  func testEncodedSnapshotContainsNoNotificationContentFields() throws {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: true)
    _ = store.record(
      eventId: "event-1",
      tabId: "tab-1",
      source: "osc",
      category: "needsAction",
      stage: .willPresent,
      presentationOptions: ["banner", "list"])

    let data = try JSONEncoder().encode(store.snapshot())
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])

    XCTAssertNil(events.first?["title"])
    XCTAssertNil(events.first?["body"])
  }

  func testEncodedSnapshotIncludesNullableTopLevelSchemaFields() throws {
    let store = NativeNotificationDiagnosticsStore(capacity: 4, nativeAvailable: false)
    let data = try JSONEncoder().encode(store.snapshot())
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])

    for key in [
      "lastRefreshedAt", "settings", "pendingCount", "deliveredCount",
      "focusSuppressesNotifications", "focusCheckedAt", "identity",
    ] {
      XCTAssertTrue(object.keys.contains(key), "missing required schema field \(key)")
      XCTAssertTrue(object[key] is NSNull)
    }
    XCTAssertEqual(object["focusAuthorizationStatus"] as? String, "unavailable")
  }
}
