import Darwin
import Foundation

public enum ControlDirectorySecurityError: Error, Equatable, Sendable {
  case notDirectory
  case symlink
  case wrongOwner
  case insecurePermissions(mode: UInt16)
  case socketPathNotSocket
}

public enum ControlDirectorySecurity {
  /// Ensures a user-owned `0700` directory (following symlinks to the resolved target).
  public static func ensurePrivateDirectory(at url: URL) throws {
    let path = url.path
    var st = stat()
    if stat(path, &st) != 0 {
      if errno == ENOENT {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        return try ensurePrivateDirectory(at: url)
      }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard (st.st_mode & S_IFMT) == S_IFDIR else {
      throw ControlDirectorySecurityError.notDirectory
    }
    guard st.st_uid == getuid() else {
      throw ControlDirectorySecurityError.wrongOwner
    }
    let mode = UInt16(st.st_mode & 0o777)
    if mode != 0o700 {
      if st.st_uid == getuid() {
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: 0o700)],
          ofItemAtPath: path)
        return try ensurePrivateDirectory(at: url)
      }
      throw ControlDirectorySecurityError.insecurePermissions(mode: mode)
    }
  }

  /// Rejects a symlinked control directory itself (C16 indirection attack).
  public static func rejectSymlinkDirectory(at url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return }
    if (st.st_mode & S_IFMT) == S_IFLNK {
      throw ControlDirectorySecurityError.symlink
    }
  }

  /// Validates the control directory, then removes an existing socket file only when it is a socket.
  public static func prepareSocketPath(_ path: String) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    if isEphemeralSocketDirectory(parent) {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } else {
      try rejectSymlinkDirectory(at: parent)
      try ensurePrivateDirectory(at: parent)
    }
    var st = stat()
    if lstat(path, &st) == 0 {
      guard (st.st_mode & S_IFMT) == S_IFSOCK else {
        throw ControlDirectorySecurityError.socketPathNotSocket
      }
      unlink(path)
    } else if errno != ENOENT {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private static func isEphemeralSocketDirectory(_ url: URL) -> Bool {
    let path = url.path
    if path.hasPrefix(FileManager.default.temporaryDirectory.path) { return true }
    if path == "/tmp" || path.hasPrefix("/tmp/") { return true }
    if path.hasPrefix("/var/folders/") { return true }
    return false
  }
}
