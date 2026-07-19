import Foundation

/// Where the decision to enable the in-process sampling profiler came from.
enum ProfileRecorderLaunchSource: Equatable {
  case commandLine
  case environmentDirectURL
  case environmentPattern
  case userDefault
  case disabled
}

/// The resolved profiler enable decision.
struct ProfileRecorderLaunchConfiguration: Equatable {
  var isEnabled: Bool
  var source: ProfileRecorderLaunchSource
}

/// Resolves whether Laban's in-process CPU sampling controls are enabled.
///
/// Precedence, highest first:
///   1. `--profile-recorder` (legacy URL values are accepted and ignored).
///   2. `PROFILE_RECORDER_SERVER_URL` (legacy compatibility enable gate).
///   3. `PROFILE_RECORDER_SERVER_URL_PATTERN` (legacy compatibility enable gate).
///   4. `LabanProfileRecorderEnabled` UserDefaults toggle.
/// When none is set, the profiler is disabled.
///
/// The URL-shaped legacy inputs no longer create a listener. Sampling is an
/// internal function call and happens only while a capture is active.
enum ProfileRecorderSettings {
  static let defaultsKey = "LabanProfileRecorderEnabled"
  static let directEnvKey = "PROFILE_RECORDER_SERVER_URL"
  static let envKey = "PROFILE_RECORDER_SERVER_URL_PATTERN"

  static func persisted(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: defaultsKey)
  }

  static func set(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: defaultsKey)
  }

  static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    defaults: UserDefaults = .standard
  ) -> ProfileRecorderLaunchConfiguration {
    if commandLineEnables(arguments: arguments) {
      return ProfileRecorderLaunchConfiguration(isEnabled: true, source: .commandLine)
    }
    if environment[directEnvKey]?.isEmpty == false {
      return ProfileRecorderLaunchConfiguration(isEnabled: true, source: .environmentDirectURL)
    }
    if environment[envKey]?.isEmpty == false {
      return ProfileRecorderLaunchConfiguration(isEnabled: true, source: .environmentPattern)
    }
    if persisted(defaults: defaults) {
      return ProfileRecorderLaunchConfiguration(isEnabled: true, source: .userDefault)
    }
    return ProfileRecorderLaunchConfiguration(isEnabled: false, source: .disabled)
  }

  /// Read-only Settings copy describing the listener-free capture behavior.
  static var settingsHelpText: String {
    return """
      Samples are collected in-process only while a capture is active. No profiler socket is opened.
      Long recording: Debug → Start CPU Recording, then Export CPU Profile…
      One-shot: Debug → Capture CPU Profile…
      """
  }

  /// Directory for captured `.perf` files.
  static var profilesDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Laban/profiles", isDirectory: true)
  }

  /// Legacy URL-bearing forms still enable sampling, but their value is ignored.
  private static func commandLineEnables(arguments: [String]) -> Bool {
    arguments.dropFirst().contains {
      $0 == "--profile-recorder" || $0.hasPrefix("--profile-recorder=")
    }
  }
}
