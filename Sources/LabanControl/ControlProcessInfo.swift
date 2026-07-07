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

  /// Returns true when the peer process appears to be the intended agent
  /// redeemer (`laban-agent`) rather than an arbitrary direct child of the
  /// shell that inherited the bootstrap env.
  public static func isLabanAgentExecutable(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    return url.lastPathComponent == "laban-agent"
  }
}
