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

  /// Returns true when the peer process appears to be the intended agent
  /// redeemer (`laban-agent`) rather than an arbitrary direct child of the
  /// shell that inherited the bootstrap env.
  ///
  /// In production the executable must live inside an app bundle's
  /// `Contents/MacOS/laban-agent`. When `allowDevBuildPath` is true, SwiftPM
  /// build-tree paths such as `.build/debug/laban-agent` are also accepted so
  /// dev/E2E workflows can use an unbundled agent.
  public static func isLabanAgentExecutable(
    _ path: String,
    allowDevBuildPath: Bool = false
  ) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard URL(fileURLWithPath: resolved).lastPathComponent == "laban-agent" else {
      return false
    }
    if isBundledAgentPath(resolved) { return true }
    if allowDevBuildPath && isDevBuildAgentPath(resolved) { return true }
    return false
  }
}