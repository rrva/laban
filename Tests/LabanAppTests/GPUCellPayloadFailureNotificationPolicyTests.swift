import Foundation
import LabanRenderer
import XCTest

@testable import LabanApp

final class GPUCellPayloadFailureNotificationPolicyTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testDistinctFailuresAreGloballyRateLimited() throws {
    let defaults = try makeDefaults()
    // Drive the injected monotonic clock deterministically: advance it 1s
    // between five distinct-signature failures, all within the 60s limit.
    var uptimeNanoseconds: UInt64 = 1_000_000_000
    var policy = GPUCellPayloadFailureNotificationPolicy(
      defaults: defaults,
      rateLimit: 60,
      monotonicNow: { uptimeNanoseconds })

    let requests = (0..<5).compactMap { index -> GPUCellPayloadFailureNotificationPolicy.Request? in
      let request = policy.notificationRequest(
        for: failure(reason: "failure-\(index)", row: index, col: index + 1),
        dumpPath: "/tmp/dump-\(index)")
      uptimeNanoseconds += 1_000_000_000
      return request
    }

    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.identifier, GPUCellPayloadFailureNotificationPolicy.identifier)
  }

  func testPreferenceSuppressesNotifications() throws {
    let defaults = try makeDefaults()
    defaults.set(
      true,
      forKey: GPUCellPayloadFailureNotificationPolicy.notificationsDisabledDefaultsKey)
    var policy = GPUCellPayloadFailureNotificationPolicy(
      defaults: defaults,
      rateLimit: 60,
      monotonicNow: { 1_000_000_000 })

    let request = policy.notificationRequest(
      for: failure(reason: "unsupported-scalar"),
      dumpPath: "/tmp/dump")

    XCTAssertNil(request)
  }

  func testRelaunchAllowsFirstFailureAfterPriorPost() throws {
    let defaults = try makeDefaults()
    // First "launch": post a failure, then confirm a second within the limit
    // is throttled — the in-memory anchor is live.
    var firstLaunch = GPUCellPayloadFailureNotificationPolicy(
      defaults: defaults,
      rateLimit: 60,
      monotonicNow: { 10_000_000_000 })
    XCTAssertNotNil(
      firstLaunch.notificationRequest(
        for: failure(reason: "first"),
        dumpPath: "/tmp/dump"))
    XCTAssertNil(
      firstLaunch.notificationRequest(
        for: failure(reason: "second"),
        dumpPath: "/tmp/dump"))

    // "Relaunch": a fresh policy instance starts with no in-memory anchor, so
    // the first failure is surfaced even though a prior instance just posted
    // (same defaults, monotonic clock barely advanced).
    var secondLaunch = GPUCellPayloadFailureNotificationPolicy(
      defaults: defaults,
      rateLimit: 60,
      monotonicNow: { 10_000_000_001 })
    XCTAssertNotNil(
      secondLaunch.notificationRequest(
        for: failure(reason: "after-relaunch"),
        dumpPath: "/tmp/dump"))
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "GPUCellPayloadFailureNotificationPolicyTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }

  private func failure(
    reason: String,
    row: Int = 1,
    col: Int = 2
  ) -> MetalRenderer.GPUCellPayloadBuildFailure {
    MetalRenderer.GPUCellPayloadBuildFailure(
      reason: reason,
      row: row,
      col: col,
      scalarValue: UInt32(row + col),
      textPreview: reason,
      utf8RangeLowerBound: row,
      utf8RangeUpperBound: row + 1,
      utf8ByteCount: 1,
      wide: UInt8(row % 2),
      attributesRawValue: UInt16(col))
  }
}
