import Darwin
import Foundation

/// `laban run --wait`: the command runs in a new terminal the app owns, so the
/// CLI cannot `waitpid` it. Instead the command is wrapped in `/bin/sh`, which
/// records its own pid, runs the command, and writes the exit status to a file
/// in a private (0700) directory the CLI created. The CLI polls that file and
/// exits with the status. If the terminal closes first, the wrapper's pid is
/// gone with no status written, and the CLI reports that.
struct RunWaiter {
  enum Outcome: Equatable {
    case exited(Int32)
    case failed(String)
  }

  /// Arguments after the script: `$0` is a display name, `$1` the status
  /// directory, the rest the user's command, word for word.
  static let script = """
    d=$1; shift; printf '%s' "$$" > "$d/pid"; "$@"; rc=$?; \
    printf '%s' "$rc" > "$d/status.tmp" && mv "$d/status.tmp" "$d/status"; exit $rc
    """

  static func wrappedArgv(_ argv: [String], statusDirectory: String) -> [String] {
    ["/bin/sh", "-c", script, "laban-run", statusDirectory] + argv
  }

  var pollInterval: TimeInterval = 0.1
  /// How long the wrapper may take to start before the CLI gives up.
  var startTimeout: TimeInterval = 30
  var readFile: (String) -> String? = { path in
    try? String(contentsOfFile: path, encoding: .utf8)
  }
  var processIsAlive: (pid_t) -> Bool = { pid in
    kill(pid, 0) == 0 || errno == EPERM
  }
  var now: () -> Date = Date.init
  var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

  func makeStatusDirectory() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
      "laban-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return path
  }

  func removeStatusDirectory(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
  }

  func wait(statusDirectory: String) -> Outcome {
    let statusPath = (statusDirectory as NSString).appendingPathComponent("status")
    let pidPath = (statusDirectory as NSString).appendingPathComponent("pid")
    let started = now()
    while true {
      if let text = readFile(statusPath), let status = Int32(text) {
        return .exited(status)
      }
      if let text = readFile(pidPath), let pid = pid_t(text), pid > 0 {
        if !processIsAlive(pid) {
          // The status may have landed between the two reads.
          if let text = readFile(statusPath), let status = Int32(text) { return .exited(status) }
          return .failed("the terminal closed before the command finished")
        }
      } else if now().timeIntervalSince(started) > startTimeout {
        return .failed("the command did not start within \(Int(startTimeout)) seconds")
      }
      sleep(pollInterval)
    }
  }
}
