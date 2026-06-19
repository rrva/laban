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
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    let requests = (0..<5).compactMap { index in
      var policy = GPUCellPayloadFailureNotificationPolicy(
        defaults: defaults,
        rateLimit: 60)
      return policy.notificationRequest(
        for: failure(reason: "failure-\(index)", row: index, col: index + 1),
        dumpPath: "/tmp/dump-\(index)",
        now: now.addingTimeInterval(Double(index)))
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
      rateLimit: 60)

    let request = policy.notificationRequest(
      for: failure(reason: "unsupported-scalar"),
      dumpPath: "/tmp/dump",
      now: Date(timeIntervalSinceReferenceDate: 1_000))

    XCTAssertNil(request)
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
