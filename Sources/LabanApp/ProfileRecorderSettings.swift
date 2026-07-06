import Darwin
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
      Long recording: Debug → Start CPU Recording, then Export CPU Profile…
      One-shot: Debug → Capture CPU Profile…, or scripts/capture-profile
      Or: curl --unix-socket <path> -sd '{"numberOfSamples":1000,"timeInterval":"10 ms"}' \
      http://localhost/sample | swift demangle --compact > ~/laban.perf
      """
  }

  /// Expands a profiler URL pattern to a concrete UNIX socket path for `pid`.
  static func concreteSocketPath(from pattern: String, pid: Int32) -> String? {
    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let rawPath: String
    if trimmed.hasPrefix("unix://") {
      rawPath = String(trimmed.dropFirst("unix://".count))
    } else {
      rawPath = trimmed
    }
    guard !rawPath.isEmpty else { return nil }
    return rawPath.replacingOccurrences(of: "{PID}", with: String(pid))
  }

  /// Candidate UNIX socket paths for a running LabanApp process. The resolved
  /// launch pattern is checked first; default layout paths remain as fallbacks.
  static func profilerSocketCandidates(
    pid: Int32 = ProcessInfo.processInfo.processIdentifier,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    defaults: UserDefaults = .standard
  ) -> [String] {
    var seen = Set<String>()
    var candidates: [String] = []
    func append(_ path: String) {
      guard seen.insert(path).inserted else { return }
      candidates.append(path)
    }

    if let pattern = resolve(environment: environment, arguments: arguments, defaults: defaults).pattern,
      let resolved = concreteSocketPath(from: pattern, pid: pid)
    {
      append(resolved)
    }

    for path in defaultProfilerSocketCandidates(pid: pid) {
      append(path)
    }
    return candidates
  }

  private static func defaultProfilerSocketCandidates(pid: Int32) -> [String] {
    let tmpdir = (NSTemporaryDirectory() as NSString).standardizingPath
    return [
      defaultProfilingDirectory.appendingPathComponent("laban-samples-\(pid).sock").path,
      (tmpdir as NSString).appendingPathComponent("laban-samples-\(pid).sock"),
      "/tmp/laban-samples-\(pid).sock",
    ]
  }

  /// Returns the profiler socket path when the in-process server is listening.
  static func findProfilerSocket(
    pid: Int32 = ProcessInfo.processInfo.processIdentifier,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    defaults: UserDefaults = .standard
  ) -> String? {
    for path in profilerSocketCandidates(
      pid: pid, environment: environment, arguments: arguments, defaults: defaults)
    {
      var status = stat()
      guard stat(path, &status) == 0 else { continue }
      guard (status.st_mode & S_IFMT) == S_IFSOCK else { continue }
      guard profilerSocketAcceptsConnections(at: path) else { continue }
      return path
    }
    return nil
  }

  /// True when a process is accepting connections on the UNIX socket path.
  private static func profilerSocketAcceptsConnections(at path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { sunPath in
      pathBytes.withUnsafeBytes { bytes in
        memcpy(sunPath, bytes.baseAddress!, bytes.count)
      }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(fd, sockaddrPtr, addrLen) == 0
      }
    }
  }

  /// Directory for captured `.perf` files (same as `scripts/capture-profile`).
  static var profilesDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Laban/profiles", isDirectory: true)
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
