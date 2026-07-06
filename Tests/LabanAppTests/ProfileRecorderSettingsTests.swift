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
    XCTAssertEqual(cfg.source, .environmentPattern)
  }

  func testUserDefaultToggleEnablesDefaultPattern() {
    let d = makeDefaults()
    ProfileRecorderSettings.set(true, defaults: d)
    let cfg = ProfileRecorderSettings.resolve(environment: [:], arguments: ["LabanApp"], defaults: d)
    XCTAssertEqual(cfg.pattern, ProfileRecorderSettings.defaultURLPattern)
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
    XCTAssertEqual(cfg.pattern, "unix:///tmp/direct.sock")
    XCTAssertEqual(cfg.source, .environmentDirectURL)
  }

  func testDirectURLEnablesWhenOnlyKeySet() {
    let cfg = ProfileRecorderSettings.resolve(
      environment: ["PROFILE_RECORDER_SERVER_URL": "unix:///tmp/direct.sock"],
      arguments: ["LabanApp"],
      defaults: makeDefaults())
    XCTAssertEqual(cfg.pattern, "unix:///tmp/direct.sock")
    XCTAssertEqual(cfg.source, .environmentDirectURL)
  }

  func testConcreteSocketPathSubstitutesPID() {
    XCTAssertEqual(
      ProfileRecorderSettings.concreteSocketPath(
        from: "unix:///tmp/laban-samples-{PID}.sock", pid: 42),
      "/tmp/laban-samples-42.sock")
  }

  func testConcreteSocketPathLeavesDirectURLUntouched() {
    XCTAssertEqual(
      ProfileRecorderSettings.concreteSocketPath(from: "unix:///tmp/direct.sock", pid: 1),
      "/tmp/direct.sock")
  }

  func testProfilerSocketCandidatesPrefersResolvedPattern() {
    let candidates = ProfileRecorderSettings.profilerSocketCandidates(
      pid: 99,
      environment: [:],
      arguments: ["LabanApp", "--profile-recorder=unix:///tmp/cli.sock"],
      defaults: makeDefaults())
    XCTAssertEqual(candidates.first, "/tmp/cli.sock")
  }

  func testProfilerSocketCandidatesIncludesDirectEnvURL() {
    let candidates = ProfileRecorderSettings.profilerSocketCandidates(
      pid: 12,
      environment: ["PROFILE_RECORDER_SERVER_URL": "unix:///tmp/env-direct.sock"],
      arguments: ["LabanApp"],
      defaults: makeDefaults())
    XCTAssertEqual(candidates.first, "/tmp/env-direct.sock")
  }
}
