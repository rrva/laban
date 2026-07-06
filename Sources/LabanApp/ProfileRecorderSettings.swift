import Foundation

/// Where the decision to enable the in-process sampling profiler came from.
enum ProfileRecorderLaunchSource: Equatable {
  case commandLine
  case environment
  case userDefault
  case disabled
}

/// The resolved profiler launch decision. `pattern == nil` means "off".
struct ProfileRecorderLaunchConfiguration: Equatable {
  var pattern: String?
  var source: ProfileRecorderLaunchSource
}

/// Resolves whether (and where) the in-process sampling profiler server listens.
///
/// Precedence, highest first:
///   1. `--profile-recorder` / `--profile-recorder=<url>` command-line switch.
///   2. `PROFILE_RECORDER_SERVER_URL_PATTERN` environment variable.
///   3. `LabanProfileRecorderEnabled` UserDefaults toggle (uses `defaultURLPattern`).
/// When none is set, the profiler is disabled.
enum ProfileRecorderSettings {
  static let defaultsKey = "LabanProfileRecorderEnabled"
  static let envKey = "PROFILE_RECORDER_SERVER_URL_PATTERN"
  static let defaultURLPattern = "unix:///tmp/laban-samples-{PID}.sock"

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
    if let pattern = commandLinePattern(arguments: arguments) {
      return ProfileRecorderLaunchConfiguration(pattern: pattern, source: .commandLine)
    }
    if let raw = environment[envKey], !raw.isEmpty {
      return ProfileRecorderLaunchConfiguration(pattern: raw, source: .environment)
    }
    if persisted(defaults: defaults) {
      return ProfileRecorderLaunchConfiguration(pattern: defaultURLPattern, source: .userDefault)
    }
    return ProfileRecorderLaunchConfiguration(pattern: nil, source: .disabled)
  }

  /// Returns the URL pattern requested on the command line, or nil if the
  /// switch is absent. Accepts `--profile-recorder`, `--profile-recorder=<url>`,
  /// and `--profile-recorder <url>`.
  private static func commandLinePattern(arguments: [String]) -> String? {
    var index = 1
    while index < arguments.count {
      let arg = arguments[index]
      if arg == "--profile-recorder" {
        // Optional following value that is not itself another flag.
        if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
          return arguments[index + 1]
        }
        return defaultURLPattern
      }
      if arg.hasPrefix("--profile-recorder=") {
        let value = String(arg.dropFirst("--profile-recorder=".count))
        return value.isEmpty ? defaultURLPattern : value
      }
      index += 1
    }
    return nil
  }
}
