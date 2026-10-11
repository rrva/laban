import Darwin
import Foundation
import LabanControl
import XCTest

final class ControlUDSClientConnectTests: XCTestCase {
  /// A server may answer and close a connection before the client gets to run
  /// another line (the agent proxy rejects a forbidden or excess peer the
  /// moment it accepts). Darwin refuses `setsockopt` on a socket whose peer
  /// has already closed (EINVAL), so SO_NOSIGPIPE set *after* connect loses
  /// that race and the caller reports a connection failure instead of reading
  /// the server's answer. `connect` must hand back a socket that is already
  /// SIGPIPE-safe.
  func testConnectReturnsSocketThatIsNoSigPipeEvenAfterPeerCloses() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-uds-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("s.sock").path

    let listener = try bindListener(path: path)
    defer { Darwin.close(listener) }

    let clientFD = try ControlUDSClient.connect(socketPath: path)
    defer { Darwin.close(clientFD) }

    // The server answers and closes before the client does anything else.
    let serverFD = Darwin.accept(listener, nil, nil)
    XCTAssertGreaterThanOrEqual(serverFD, 0)
    Darwin.close(serverFD)

    var value: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    XCTAssertEqual(getsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &value, &length), 0)
    XCTAssertEqual(value, 1, "connect must set SO_NOSIGPIPE before the peer can close")
  }

  private func bindListener(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (index, byte) in bytes.enumerated() where index < dest.count {
        dest[index] = UInt8(bitPattern: byte)
      }
    }
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(fd, 1) == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return fd
  }
}
