import XCTest

@testable import LabanCore

/// The tab sidebar can be switched off, handing its width back to the terminal
/// grid. Width is the whole mechanism: every geometry, hit-test and
/// mouse-routing site already keys off `sidebarWidth`, so zero disables the
/// surface without a second flag threaded through them.
final class SidebarVisibilitySettingsTests: XCTestCase {
  private func defaults(_ name: String) -> UserDefaults {
    let suite = "laban-sidebar-visibility-\(name)-\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
  }

  /// The sidebar is shipped MVP behaviour, so a missing key must read as
  /// visible. Reading the key straight off `UserDefaults` would return `false`
  /// and silently hide it — which is why callers must use the accessor.
  func testMissingKeyDefaultsToVisible() {
    XCTAssertTrue(
      SidebarVisibilitySettings.visible(defaults: defaults("missing"), environment: [:]))
  }

  func testPersistedValueRoundTrips() {
    let d = defaults("roundtrip")
    XCTAssertTrue(SidebarVisibilitySettings.setVisible(false, defaults: d, environment: [:]))
    XCTAssertFalse(SidebarVisibilitySettings.visible(defaults: d, environment: [:]))
    XCTAssertTrue(SidebarVisibilitySettings.setVisible(true, defaults: d, environment: [:]))
    XCTAssertTrue(SidebarVisibilitySettings.visible(defaults: d, environment: [:]))
  }

  /// The env override is the fixture control plane: it wins over the stored
  /// value, and a write while it is set is refused rather than silently ignored.
  func testEnvironmentOverrideWinsAndBlocksWrites() {
    let d = defaults("env")
    d.set(true, forKey: SidebarVisibilitySettings.visibleKey)
    let hidden = [SidebarVisibilitySettings.visibleEnvironmentKey: "0"]
    XCTAssertFalse(SidebarVisibilitySettings.visible(defaults: d, environment: hidden))
    XCTAssertFalse(SidebarVisibilitySettings.setVisible(true, defaults: d, environment: hidden))

    let shown = [SidebarVisibilitySettings.visibleEnvironmentKey: "1"]
    d.set(false, forKey: SidebarVisibilitySettings.visibleKey)
    XCTAssertTrue(SidebarVisibilitySettings.visible(defaults: d, environment: shown))
  }

  func testEnvironmentTruthySpellings() {
    for raw in ["1", "true", "YES", "on", "Enabled"] {
      XCTAssertEqual(
        SidebarVisibilitySettings.environmentOverride(
          environment: [SidebarVisibilitySettings.visibleEnvironmentKey: raw]), true, raw)
    }
    for raw in ["0", "false", "no", "off", "garbage", ""] {
      XCTAssertEqual(
        SidebarVisibilitySettings.environmentOverride(
          environment: [SidebarVisibilitySettings.visibleEnvironmentKey: raw]), false, raw)
    }
    XCTAssertNil(SidebarVisibilitySettings.environmentOverride(environment: [:]))
  }

  /// Zero width is what disables every sidebar surface — hit tests
  /// (`pt.x < sidebarWidth`), the terminal's column count
  /// (`termW = w - sidebarWidth …`), and the command builder's early return.
  func testEffectiveWidthIsZeroWhenHidden() {
    XCTAssertEqual(SidebarVisibilitySettings.effectiveWidth(200, visible: true), 200)
    XCTAssertEqual(SidebarVisibilitySettings.effectiveWidth(200, visible: false), 0)
  }

  func testSettingPostsChangeNotification() {
    let d = defaults("notify")
    expectation(forNotification: SidebarVisibilitySettings.didChangeNotification, object: nil)
    XCTAssertTrue(SidebarVisibilitySettings.setVisible(false, defaults: d, environment: [:]))
    waitForExpectations(timeout: 1)
  }
}
