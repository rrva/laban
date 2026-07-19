import XCTest

@testable import LabanApp

final class ProfileRecorderSettingsTests: XCTestCase {
  private func makeDefaults() -> UserDefaults {
    let suite = "ProfileRecorderSettingsTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
  }

  func testDisabledByDefault() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: [:], arguments: ["LabanApp"], defaults: makeDefaults())
    XCTAssertFalse(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .disabled)
  }

  func testCommandLineWins() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: ["PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/env.sock"],
      arguments: ["LabanApp", "--profile-recorder=unix:///tmp/cli.sock"],
      defaults: makeDefaults())
    XCTAssertTrue(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .commandLine)
  }

  func testBareSwitchEnables() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: [:], arguments: ["LabanApp", "--profile-recorder"], defaults: makeDefaults())
    XCTAssertTrue(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .commandLine)
  }

  func testEnvBeatsUserDefault() {
    let d = makeDefaults()
    ProfileRecorderSettings.set(true, defaults: d)
    let cfg = ProfileRecorderSettings.resolve(
      environment: ["PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/env.sock"],
      arguments: ["LabanApp"], defaults: d)
    XCTAssertTrue(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .environmentPattern)
  }

  func testUserDefaultToggleEnables() {
    let d = makeDefaults()
    ProfileRecorderSettings.set(true, defaults: d)
    let cfg = ProfileRecorderSettings.resolve(
      environment: [:], arguments: ["LabanApp"], defaults: d)
    XCTAssertTrue(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .userDefault)
  }

  func testDirectURLBeatsPattern() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: [
        "PROFILE_RECORDER_SERVER_URL": "unix:///tmp/direct.sock",
        "PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/pattern.sock",
      ],
      arguments: ["LabanApp"],
      defaults: makeDefaults())
    XCTAssertTrue(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .environmentDirectURL)
  }

  func testDirectURLEnablesWhenOnlyKeySet() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: ["PROFILE_RECORDER_SERVER_URL": "unix:///tmp/direct.sock"],
      arguments: ["LabanApp"],
      defaults: makeDefaults())
    XCTAssertTrue(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .environmentDirectURL)
  }

  func testLegacyURLValuesDoNotAffectEnablement() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--profile-recorder=not-a-url"],
      defaults: makeDefaults())
    XCTAssertTrue(cfg.isEnabled)
    XCTAssertEqual(cfg.source, .commandLine)
  }
}
