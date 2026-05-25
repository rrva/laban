import Darwin
import Foundation

public final class LabandTerminalSessionClient: TerminalSessionClient {
  public let transportMode = "laband"

  private let socketPath: String
  private var fd: Int32
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(socketPath: String) throws {
    self.socketPath = socketPath
    self.fd = try Self.connect(socketPath: socketPath)
  }

  deinit {
    close()
  }

  public func close() {
    lock.withLock {
      if fd >= 0 {
        Darwin.close(fd)
        fd = -1
      }
    }
  }

  public func hello() throws -> LabandHelloResponse {
    let response = try send(LabandRequest(requestId: UUID().uuidString, type: .hello))
    guard let hello = response.hello else {
      throw TerminalSessionClientError.protocolError("hello response missing payload")
    }
    return hello
  }

  @discardableResult
  public func createSession(_ request: TerminalSessionLaunchRequest) throws -> LabandSessionInfo {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .createSession,
        executable: request.executable,
        argv: request.argv,
        cwd: request.cwd,
        environmentPatch: request.environmentPatch,
        rows: request.rows,
        cols: request.cols,
        logicalSessionId: request.logicalSessionId
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("createSession response missing session")
    }
    return session
  }

  public func listSessions() throws -> [LabandSessionInfo] {
    let response = try send(LabandRequest(requestId: UUID().uuidString, type: .listSessions))
    return response.sessions ?? []
  }

  public func writeInput(sessionId: String, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    _ = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .writeInput,
        sessionId: sessionId,
        bytesBase64: Data(bytes).base64EncodedString()
      )
    )
  }

  public func resize(sessionId: String, rows: Int, cols: Int) throws -> LabandSessionInfo {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .resizeSession,
        rows: rows,
        cols: cols,
        sessionId: sessionId
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("resizeSession response missing session")
    }
    return session
  }

  public func snapshot(sessionId: String) throws -> LabandSnapshotResponse {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .snapshot,
        sessionId: sessionId
      )
    )
    guard let snapshot = response.snapshot else {
      throw TerminalSessionClientError.protocolError("snapshot response missing payload")
    }
    return snapshot
  }

  public func markRendered(sessionId: String) throws {
    _ = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .markRendered,
        sessionId: sessionId
      )
    )
  }

  public func terminate(sessionId: String) throws -> LabandSessionInfo {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .terminateSession,
        sessionId: sessionId
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("terminateSession response missing session")
    }
    return session
  }

  public func shutdownWhenIdle() throws {
    _ = try send(LabandRequest(requestId: UUID().uuidString, type: .shutdownWhenIdle))
  }

  private func send(_ request: LabandRequest) throws -> LabandResponse {
    try lock.withLock {
      guard fd >= 0 else {
        throw TerminalSessionClientError.protocolError("socket is closed")
      }
      try writeFrame(encoder.encode(request))
      let response = try decoder.decode(LabandResponse.self, from: readFrame())
      guard response.ok else {
        let message = response.error.map { "\($0.code): \($0.message)" } ?? "unknown error"
        throw TerminalSessionClientError.protocolError(message)
      }
      return response
    }
  }

  private static func connect(socketPath: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      for index in 0..<pathBytes.count {
        ptr.advanced(by: index).pointee = pathBytes[index]
      }
    }
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let err = errno
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
    return fd
  }

  private func readFrame() throws -> Data {
    let header = try readExact(count: 4)
    let bytes = [UInt8](header)
    let length = Int(
      UInt32(bytes[0])
        | (UInt32(bytes[1]) << 8)
        | (UInt32(bytes[2]) << 16)
        | (UInt32(bytes[3]) << 24)
    )
    guard length > 0 && length <= 16 * 1024 * 1024 else {
      throw TerminalSessionClientError.protocolError("invalid frame length \(length)")
    }
    return try readExact(count: length)
  }

  private func writeFrame(_ payload: Data) throws {
    let length = UInt32(payload.count)
    var header = Data()
    header.append(UInt8(length & 0xFF))
    header.append(UInt8((length >> 8) & 0xFF))
    header.append(UInt8((length >> 16) & 0xFF))
    header.append(UInt8((length >> 24) & 0xFF))
    try writeAll(header)
    try writeAll(payload)
  }

  private func readExact(count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let n = data.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(fd, base.advanced(by: offset), count - offset)
      }
      if n == 0 { throw POSIXError(.ECONNRESET) }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
    return data
  }

  private func writeAll(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
