import Darwin
import Foundation

public enum ControlProcessInfo {
  /// Returns the executable path for the given PID, or nil if unavailable.
  public static func executablePath(for pid: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = proc_pidpath(pid, &path, UInt32(path.count))
    guard result > 0 else { return nil }
    return String(cString: path)
  }

  /// Returns true when the executable path is inside any `.app` bundle's
  /// `Contents/MacOS/laban-agent`. This covers production installs regardless
  /// of where the `.app` lives on disk.
  private static func isBundledAgentPath(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    guard let appIdx = components.lastIndex(where: { $0.hasSuffix(".app") }),
      appIdx + 3 < components.count,
      components[appIdx + 1] == "Contents",
      components[appIdx + 2] == "MacOS",
      components[appIdx + 3] == "laban-agent"
    else {
      return false
    }
    return true
  }

  /// Returns true when the executable path is inside the SwiftPM build tree,
  /// e.g. `.build/<arch>/<config>/laban-agent` or `.build/<config>/laban-agent`.
  private static func isDevBuildAgentPath(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    guard let buildIdx = components.lastIndex(where: { $0 == ".build" }),
      buildIdx + 2 < components.count,
      components.last == "laban-agent"
    else {
      return false
    }
    return true
  }

  /// Returns the packaged app's expected agent executable path when running
  /// from a `.app` bundle. SwiftPM/test processes return nil and must pass an
  /// explicit expected path if they want C14 attach redemption to work.
  public static func defaultExpectedAgentExecutablePath() -> String? {
    let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
    guard bundleURL.pathExtension == "app" else { return nil }
    return
      bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent("laban-agent")
      .path
  }

  /// Returns true when the peer process executable is exactly the expected
  /// `laban-agent` path. This rejects spoofed bundles such as
  /// `/tmp/Evil.app/Contents/MacOS/laban-agent` even though they match the app
  /// bundle shape.
  public static func isLabanAgentExecutable(
    _ path: String,
    expectedExecutablePath: String? = defaultExpectedAgentExecutablePath(),
    allowDevBuildPath: Bool = false
  ) -> Bool {
    let resolved = canonicalPath(path)
    guard URL(fileURLWithPath: resolved).lastPathComponent == "laban-agent" else {
      return false
    }
    guard let expectedExecutablePath,
      resolved == canonicalPath(expectedExecutablePath)
    else {
      return false
    }
    if isBundledAgentPath(resolved) { return true }
    if allowDevBuildPath && isDevBuildAgentPath(resolved) { return true }
    return false
  }

  private static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }
}
