import Darwin
import Foundation

public enum ControlAdvertisement {
  public static func directory() -> URL {
    if let cDir = getenv("LABAN_CONTROL_DIR"),
      let dir = String(utf8String: cDir),
      !dir.isEmpty
    {
      return URL(fileURLWithPath: dir, isDirectory: true)
    }
    // XCTest targets run in separate worktrees and can run while a user's
    // Laban.app is live. They must never bind the shared production socket.
    // `swift test` on the command line does not set `XCTestConfigurationFilePath`,
    // but the runner is the `xctest` executable and receives `-XCTest` arguments.
    let isXCTest =
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || ProcessInfo.processInfo.processName == "xctest"
      || ProcessInfo.processInfo.arguments.contains("-XCTest")
    if isXCTest {
      // Use /tmp so the path stays short enough to fit in an 80-column test
      // terminal without wrapping and breaking string assertions.
      let url = URL(fileURLWithPath: "/tmp/laban-xctest-\(getuid())-\(getpid())")
      try? FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      return url
    }
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory())
    return base.appendingPathComponent("Laban", isDirectory: true)
  }

  public static func write(url: String, token: String, pid: Int32, runId: String) throws {
    let dir = directory()
    try ControlDirectorySecurity.rejectSymlinkDirectory(at: dir)
    try ControlDirectorySecurity.ensurePrivateDirectory(at: dir)
    let file = dir.appendingPathComponent("control.json")
    let payload: [String: Any] = [
      "pid": Int(pid),
      "runId": runId,
      "token": token,
      "url": url,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let tmp = dir.appendingPathComponent("control.json.\(getpid()).\(UUID().uuidString).tmp")

    let tmpFD = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard tmpFD >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try ControlFD.setCloseOnExec(tmpFD)
    var installed = false
    defer {
      Darwin.close(tmpFD)
      if !installed {
        try? FileManager.default.removeItem(at: tmp)
      }
    }

    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var written = 0
      while written < rawBuffer.count {
        let result = Darwin.write(tmpFD, base.advanced(by: written), rawBuffer.count - written)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        written += result
      }
    }
    guard fsync(tmpFD) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard Darwin.rename(tmp.path, file.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    installed = true
  }

  public static func remove() {
    try? FileManager.default.removeItem(
      at: directory().appendingPathComponent("control.json"))
  }
}
