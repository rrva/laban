import Darwin
import Foundation

public final class LabptyTerminalSessionClient: TerminalSessionClient {
  public let transportMode = "labpty"

  private let socketPath: String
  private var fd: Int32
  private var nextSequence: UInt64 = 1
  private let lock = NSLock()
  private var handlesBySessionId: [String: UInt64] = [:]
  private var descriptorsByHandle: [UInt64: LabptySessionDescriptor] = [:]

  public init(socketPath: String) throws {
    self.socketPath = socketPath
    fd = try Self.connect(socketPath: socketPath)
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
      handlesBySessionId.removeAll()
      descriptorsByHandle.removeAll()
    }
  }

  public func hello() throws -> LabptyHelloResponse {
    let payload = try LabptyHelloRequest(clientId: UUID().uuidString).encode()
    return try send(operation: .hello, payload: payload, decode: LabptyHelloResponse.decode)
  }

  public func openSession(_ request: LabptyOpenSessionRequest) throws -> LabptySessionDescriptor {
    let descriptor: LabptySessionDescriptor = try send(
      operation: .openSession,
      payload: try request.encode(),
      decode: LabptySessionDescriptor.decode)
    remember(descriptor)
    return descriptor
  }

  public func listLabptySessions() throws -> [LabptySessionDescriptor] {
    let response: LabptyListSessionsResponse = try send(
      operation: .listSessions,
      payload: Data(),
      decode: LabptyListSessionsResponse.decode)
    for descriptor in response.sessions {
      remember(descriptor)
    }
    return response.sessions
  }

  public func writeInput(handle: UInt64, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    let request = LabptyWriteInputRequest(ptyHandle: handle, bytes: Data(bytes))
    try sendNoPayload(operation: .writeInput, payload: try request.encode())
  }

  public func resize(handle: UInt64, rows: Int, cols: Int) throws -> LabptySessionDescriptor {
    let request = LabptyResizeSessionRequest(
      ptyHandle: handle,
      rows: UInt32(rows),
      cols: UInt32(cols))
    let descriptor: LabptySessionDescriptor = try send(
      operation: .resizeSession,
      payload: request.encode(),
      decode: LabptySessionDescriptor.decode)
    remember(descriptor)
    return descriptor
  }

  public func signal(handle: UInt64, signal: Int32) throws -> LabptySessionDescriptor {
    let request = LabptySignalSessionRequest(ptyHandle: handle, signal: signal)
    let descriptor: LabptySessionDescriptor = try send(
      operation: .signalSession,
      payload: request.encode(),
      decode: LabptySessionDescriptor.decode)
    remember(descriptor)
    return descriptor
  }

  public func terminate(handle: UInt64) throws -> LabptySessionDescriptor {
    let descriptor: LabptySessionDescriptor = try send(
      operation: .terminateSession,
      payload: LabptyTerminateSessionRequest(ptyHandle: handle).encode(),
      decode: LabptySessionDescriptor.decode)
    remember(descriptor)
    return descriptor
  }

  @discardableResult
  public func createSession(_ request: TerminalSessionLaunchRequest) throws -> LabandSessionInfo {
    let descriptor = try openSession(
      LabptyOpenSessionRequest(
        rows: UInt32(request.rows),
        cols: UInt32(request.cols),
        argv: launchArgv(from: request),
        envp: request.environmentPatch.map { "\($0.key)=\($0.value)" }.sorted(),
        cwd: request.cwd ?? "",
        logicalSessionId: request.logicalSessionId ?? ""))
    return labandInfo(from: descriptor)
  }

  public func listSessions() throws -> [LabandSessionInfo] {
    try listLabptySessions().map(labandInfo)
  }

  public func attachSession(logicalSessionId: String) throws -> LabandSessionInfo {
    if let descriptor = try listLabptySessions().first(where: { $0.logicalSessionId == logicalSessionId }) {
      return labandInfo(from: descriptor)
    }
    throw TerminalSessionClientError.sessionNotFound(logicalSessionId)
  }

  public func detachSession(sessionId: String) throws -> LabandSessionInfo {
    guard let handle = handlesBySessionId[sessionId],
      let descriptor = descriptorsByHandle[handle]
    else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    return labandInfo(from: descriptor)
  }

  public func writeInput(sessionId: String, bytes: [UInt8]) throws {
    guard let handle = handlesBySessionId[sessionId] else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    try writeInput(handle: handle, bytes: bytes)
  }

  public func resize(sessionId: String, rows: Int, cols: Int) throws -> LabandSessionInfo {
    guard let handle = handlesBySessionId[sessionId] else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    return try labandInfo(from: resize(handle: handle, rows: rows, cols: cols))
  }

  public func attachSnapshotRing(sessionId: String) throws -> LabandSnapshotRingAttachment {
    throw unsupported()
  }

  public func snapshot(sessionId: String) throws -> LabandSnapshotResponse {
    throw unsupported()
  }

  public func scrollViewport(sessionId: String, deltaRows: Int) throws -> LabandSessionInfo {
    throw unsupported()
  }

  public func markRendered(sessionId: String) throws {
    throw unsupported()
  }

  public func transferLease(sessionId: String, holderClientId: String) throws -> LabandSessionInfo {
    throw unsupported()
  }

  public func terminate(sessionId: String) throws -> LabandSessionInfo {
    guard let handle = handlesBySessionId[sessionId] else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    return try labandInfo(from: terminate(handle: handle))
  }

  private func unsupported<T>() -> T {
    fatalError("unreachable generic unsupported call")
  }

  private func unsupported() -> TerminalSessionClientError {
    .protocolError("not supported for labpty transport")
  }

  private func sendNoPayload(operation: LabptyOperation, payload: Data) throws {
    let _: Data = try send(operation: operation, payload: payload) { payload in
      payload
    }
  }

  private func send<T>(
    operation: LabptyOperation,
    payload: Data,
    decode: (Data) throws -> T
  ) throws -> T {
    try lock.withLock {
      guard fd >= 0 else {
        throw TerminalSessionClientError.protocolError("socket is closed")
      }
      let sequence = nextSequence
      nextSequence += 1
      try writeAll(LabptyFraming.encodeRequest(operation: operation, sequence: sequence, payload: payload))
      let response = try LabptyFraming.decode(try readFrame())
      guard response.header.sequence == sequence else {
        throw TerminalSessionClientError.protocolError("labpty response sequence mismatch")
      }
      guard response.header.responseCode == .ok else {
        throw TerminalSessionClientError.protocolError(
          "labpty error \(response.header.codeRaw)")
      }
      return try decode(response.payload)
    }
  }

  private func remember(_ descriptor: LabptySessionDescriptor) {
    lock.withLock {
      handlesBySessionId[descriptor.logicalSessionId] = descriptor.ptyHandle
      descriptorsByHandle[descriptor.ptyHandle] = descriptor
    }
  }

  private func labandInfo(from descriptor: LabptySessionDescriptor) -> LabandSessionInfo {
    LabandSessionInfo(
      logicalSessionId: descriptor.logicalSessionId,
      incarnationId: String(descriptor.ptyHandle),
      childPid: Int(descriptor.childPid),
      foregroundPid: descriptor.foregroundPid >= 0 ? Int(descriptor.foregroundPid) : nil,
      daemonProcessPid: -1,
      cwd: "",
      commandDisplayName: "labpty",
      title: "",
      rows: Int(descriptor.rows),
      cols: Int(descriptor.cols),
      lifecycleState: descriptor.alive ? .running : .exited,
      attachedClientCount: descriptor.alive ? 1 : 0,
      leaseHolder: nil,
      transportMode: transportMode)
  }

  private func launchArgv(from request: TerminalSessionLaunchRequest) -> [String] {
    if let argv = request.argv, !argv.isEmpty {
      return argv
    }
    if let executable = request.executable, !executable.isEmpty {
      return [executable]
    }
    return []
  }

  private static func connect(socketPath: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
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
    let header = try readExact(count: LabptyFrameHeader.headerByteCount)
    let headerBytes = [UInt8](header)
    let totalLength = Int(
      UInt32(headerBytes[8])
        | (UInt32(headerBytes[9]) << 8)
        | (UInt32(headerBytes[10]) << 16)
        | (UInt32(headerBytes[11]) << 24)
    )
    guard totalLength >= LabptyFrameHeader.headerByteCount else {
      throw LabptyProtocolError.truncatedFrame
    }
    let payload = try readExact(count: totalLength - LabptyFrameHeader.headerByteCount)
    return header + payload
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
