import Darwin
import Foundation

public enum ControlAdvertisement {
  public static func directory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["LABAN_CONTROL_DIR"], !dir.isEmpty {
      return URL(fileURLWithPath: dir, isDirectory: true)
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
