import Foundation
import XCTest

@testable import LabanCore

final class HoverPreviewSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-hover-preview-tests"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultIsDisabled() {
    XCTAssertFalse(HoverPreviewSettings.enabled(defaults: defaults, environment: [:]))
  }

  func testSetEnabledPersistsAndReadsBack() {
    HoverPreviewSettings.setEnabled(true, defaults: defaults, environment: [:])
    XCTAssertTrue(HoverPreviewSettings.enabled(defaults: defaults, environment: [:]))
    XCTAssertEqual(defaults.object(forKey: HoverPreviewSettings.enabledKey) as? Bool, true)
  }

  func testRoundTrip() {
    HoverPreviewSettings.setEnabled(true, defaults: defaults, environment: [:])
    XCTAssertTrue(HoverPreviewSettings.enabled(defaults: defaults, environment: [:]))
    HoverPreviewSettings.setEnabled(false, defaults: defaults, environment: [:])
    XCTAssertFalse(HoverPreviewSettings.enabled(defaults: defaults, environment: [:]))
  }

  func testEnvironmentOverrideTruthyValues() {
    for value in ["1", "true", "yes", "on", "enabled", "TRUE", " YES "] {
      XCTAssertEqual(
        HoverPreviewSettings.environmentOverride(
          environment: [HoverPreviewSettings.enabledEnvironmentKey: value]),
        true, "expected \(value) to parse as truthy")
    }
  }

  func testEnvironmentOverrideFalsyValues() {
    for value in ["0", "false", "no", "off", "garbage"] {
      XCTAssertEqual(
        HoverPreviewSettings.environmentOverride(
          environment: [HoverPreviewSettings.enabledEnvironmentKey: value]),
        false, "expected \(value) to parse as falsy")
    }
  }

  func testEnvironmentOverrideAbsentIsNil() {
    XCTAssertNil(HoverPreviewSettings.environmentOverride(environment: [:]))
  }

  func testEnvironmentOverrideWinsOverUserDefault() {
    defaults.set(false, forKey: HoverPreviewSettings.enabledKey)
    let environment = [HoverPreviewSettings.enabledEnvironmentKey: "1"]
    XCTAssertTrue(HoverPreviewSettings.enabled(defaults: defaults, environment: environment))
  }

  func testSetEnabledRefusesWriteWhenEnvironmentOverrideIsSet() {
    let environment = [HoverPreviewSettings.enabledEnvironmentKey: "1"]
    let didWrite = HoverPreviewSettings.setEnabled(
      false, defaults: defaults, environment: environment)
    XCTAssertFalse(didWrite)
    XCTAssertNil(defaults.object(forKey: HoverPreviewSettings.enabledKey))
  }

  func testSetFiresChangeNotification() {
    let exp = expectation(
      forNotification: HoverPreviewSettings.didChangeNotification,
      object: nil, handler: nil)
    HoverPreviewSettings.setEnabled(true, defaults: defaults, environment: [:])
    wait(for: [exp], timeout: 1.0)
  }
}
