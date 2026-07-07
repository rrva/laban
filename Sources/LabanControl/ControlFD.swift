import Darwin
import Foundation

public enum ControlFD {
  public static func setCloseOnExec(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFD)
    guard flags >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
