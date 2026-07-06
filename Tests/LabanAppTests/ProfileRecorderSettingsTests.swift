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
    let cfg = ProfileRecorderSettings.resolve(environment: [:], arguments: ["LabanApp"], defaults: makeDefaults())
    XCTAssertNil(cfg.pattern)
    XCTAssertEqual(cfg.source, .disabled)
  }

  func testCommandLineWins() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: ["PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/env.sock"],
      arguments: ["LabanApp", "--profile-recorder=unix:///tmp/cli.sock"],
      defaults: makeDefaults())
    XCTAssertEqual(cfg.pattern, "unix:///tmp/cli.sock")
    XCTAssertEqual(cfg.source, .commandLine)
  }

  func testBareSwitchUsesDefaultPattern() {
    let cfg = ProfileRecorderSettings.resolve(environment: [:], arguments: ["LabanApp", "--profile-recorder"], defaults: makeDefaults())
    XCTAssertEqual(cfg.pattern, ProfileRecorderSettings.defaultURLPattern)
    XCTAssertEqual(cfg.source, .commandLine)
  }

  func testEnvBeatsUserDefault() {
    let d = makeDefaults()
    ProfileRecorderSettings.set(true, defaults: d)
    let cfg = ProfileRecorderSettings.resolve(
      environment: ["PROFILE_RECORDER_SERVER_URL_PATTERN": "unix:///tmp/env.sock"],
      arguments: ["LabanApp"], defaults: d)
    XCTAssertEqual(cfg.pattern, "unix:///tmp/env.sock")
    XCTAssertEqual(cfg.source, .environment)
  }

  func testUserDefaultToggleEnablesDefaultPattern() {
    let d = makeDefaults()
    ProfileRecorderSettings.set(true, defaults: d)
    let cfg = ProfileRecorderSettings.resolve(environment: [:], arguments: ["LabanApp"], defaults: d)
    XCTAssertEqual(cfg.pattern, ProfileRecorderSettings.defaultURLPattern)
    XCTAssertEqual(cfg.source, .userDefault)
  }
}
