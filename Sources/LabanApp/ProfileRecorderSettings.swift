import Foundation

/// Where the decision to enable the in-process sampling profiler came from.
enum ProfileRecorderLaunchSource: Equatable {
  case commandLine
  case environmentDirectURL
  case environmentPattern
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
///   2. `PROFILE_RECORDER_SERVER_URL` environment variable.
///   3. `PROFILE_RECORDER_SERVER_URL_PATTERN` environment variable.
///   4. `LabanProfileRecorderEnabled` UserDefaults toggle (uses `defaultURLPattern`).
/// When none is set, the profiler is disabled.
enum ProfileRecorderSettings {
  static let defaultsKey = "LabanProfileRecorderEnabled"
  static let directEnvKey = "PROFILE_RECORDER_SERVER_URL"
  static let envKey = "PROFILE_RECORDER_SERVER_URL_PATTERN"

  /// Per-user directory that holds the default profiler socket. Restricted to
  /// the owning user (mode 0700) because on macOS connecting to a UNIX socket
  /// is not gated by the socket file's own mode — only the directory is.
  static var defaultProfilingDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Laban/profiling", isDirectory: true)
  }

  /// The default `unix://` URL pattern. Falls back to the per-user temporary
  /// directory (also 0700 on macOS) when the Application Support path would
  /// exceed the AF_UNIX `sun_path` limit (~104 bytes on macOS).
  static var defaultURLPattern: String {
    let preferred = defaultProfilingDirectory.appendingPathComponent("laban-samples-{PID}.sock").path
    // Worst-case concrete length uses a 7-digit PID in place of the 5-char token.
    if preferred.replacingOccurrences(of: "{PID}", with: "1234567").utf8.count <= 100 {
      return "unix://\(preferred)"
    }
    let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("laban-samples-{PID}.sock")
    return "unix://\(tmp)"
  }

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
    if let raw = environment[directEnvKey], !raw.isEmpty {
      return ProfileRecorderLaunchConfiguration(pattern: raw, source: .environmentDirectURL)
    }
    if let raw = environment[envKey], !raw.isEmpty {
      return ProfileRecorderLaunchConfiguration(pattern: raw, source: .environmentPattern)
    }
    if persisted(defaults: defaults) {
      return ProfileRecorderLaunchConfiguration(pattern: defaultURLPattern, source: .userDefault)
    }
    return ProfileRecorderLaunchConfiguration(pattern: nil, source: .disabled)
  }

  /// Creates the default profiling directory with mode 0700 if it does not
  /// exist. Safe to call repeatedly. Only relevant when the default pattern is
  /// in use; explicit overrides are the caller's responsibility.
  static func prepareDefaultDirectoryIfNeeded(for pattern: String) {
    guard pattern == defaultURLPattern,
      defaultURLPattern.contains(defaultProfilingDirectory.path)
    else { return }
    try? FileManager.default.createDirectory(
      at: defaultProfilingDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  /// Read-only Settings copy: default socket pattern and capture commands.
  static var settingsHelpText: String {
    let pattern = defaultURLPattern
    return """
      Default socket: \(pattern)
      Capture: scripts/capture-profile
      Or: curl --unix-socket <path> -sd '{"numberOfSamples":1000,"timeInterval":"10 ms"}' \
      http://localhost/sample | swift demangle --compact > ~/laban.perf
      """
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
