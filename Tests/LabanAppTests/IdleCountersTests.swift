import Foundation
import XCTest

@testable import LabanApp

final class IdleCountersTests: XCTestCase {
  func testIdleCountersAreDisabledByDefault() {
    let suiteName = "IdleCountersTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(IdleCounters.isEnabled(defaults: defaults, environment: [:]))
  }

  func testIdleCountersCanBeEnabledByDefaultsOrEnvironment() {
    let suiteName = "IdleCountersTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: IdleCounters.enabledDefaultKey)
    XCTAssertTrue(IdleCounters.isEnabled(defaults: defaults, environment: [:]))
    XCTAssertTrue(
      IdleCounters.isEnabled(
        defaults: defaults,
        environment: [IdleCounters.enabledEnvironmentKey: "1"]))
    XCTAssertFalse(
      IdleCounters.isEnabled(
        defaults: defaults,
        environment: [IdleCounters.enabledEnvironmentKey: "0"]))
  }
}
