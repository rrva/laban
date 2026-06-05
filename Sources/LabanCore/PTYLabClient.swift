import Darwin
import Foundation

/// Typed daemon response error. Callers can pattern-match on `code` to
/// react to specific failure modes (e.g. `.inputBackpressure` to retry
/// with a smaller chunk or wait for the child to drain input) without
/// scraping the message. See docs/adr/0008.
public struct LabptyResponseError: Error, Equatable, CustomStringConvertible {
  public let code: LabptyErrorCode
  public let rawCode: UInt16
  public let message: String

  public init(code: LabptyErrorCode, message: String) {
    self.code = code
    self.rawCode = code.rawValue
    self.message = message
  }

  public init(rawCode: UInt16, message: String) {
    self.code = LabptyErrorCode(rawValue: rawCode) ?? .internalError
    self.rawCode = rawCode
    self.message = message
  }

  public var description: String { message }
}

public final class LabptyTerminalSessionClient: TerminalSessionClient {
  public let transportMode = "labpty"

  private let socketPath: String
  private let rpcTimeoutMilliseconds: Int
  private var fd: Int32
  private let clientId = UUID().uuidString
  private var nextSequence: UInt64 = 1
  private let lock = NSLock()
  private var handlesBySessionId: [String: UInt64] = [:]
  private var descriptorsByHandle: [UInt64: LabptySessionDescriptor] = [:]
  private var negotiatedCapabilities: Set<String>?
  /// Optional self-heal hook. If a reconnect fails mid-session (typically
  /// because labpty crashed), this is invoked to bring a fresh daemon back up
  /// before retrying the connect. labpty has no crash persistence, so prior
  /// sessions are gone; this only keeps the app from wedging against a dead
  /// socket. nil for transient/throwaway clients (e.g. reachability probes).
  private let ensureDaemonRunning: (() throws -> Void)?

  public init(
    socketPath: String,
    rpcTimeoutMilliseconds: Int = 2_000,
    ensureDaemonRunning: (() throws -> Void)? = nil
  ) throws {
    self.socketPath = socketPath
    self.rpcTimeoutMilliseconds = rpcTimeoutMilliseconds
    self.ensureDaemonRunning = ensureDaemonRunning
    fd = try Self.connect(socketPath: socketPath, timeoutMilliseconds: rpcTimeoutMilliseconds)
  }

  deinit {
    close()
  }

  public func close() {
    lock.withLock {
      closeLocked()
    }
  }

  public func hello() throws -> LabptyHelloResponse {
    try lock.withLock {
      try withReconnectRetryLocked(operation: .hello) {
        try helloLocked()
      }
    }
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

  /// Claim an already-open session this connection did not create (the
  /// reattach-after-restart and adopt-orphan flows), so the daemon counts
  /// this connection in the session's `connectedClients`. Idempotent.
  @discardableResult
  public func attachLabptySession(handle: UInt64) throws -> LabptySessionDescriptor {
    let descriptor: LabptySessionDescriptor = try send(
      operation: .attachSession,
      payload: handlePayload(handle),
      decode: LabptySessionDescriptor.decode)
    remember(descriptor)
    return descriptor
  }

  /// Release a session claim without terminating the session, dropping
  /// this connection from `connectedClients`. Used when a tab closes but
  /// the underlying shell should keep running. Idempotent.
  @discardableResult
  public func detachLabptySession(handle: UInt64) throws -> LabptySessionDescriptor {
    let descriptor: LabptySessionDescriptor = try send(
      operation: .detachSession,
      payload: handlePayload(handle),
      decode: LabptySessionDescriptor.decode)
    remember(descriptor)
    return descriptor
  }

  private func handlePayload(_ handle: UInt64) -> Data {
    var writer = LabptyPayloadWriter()
    writer.appendUInt64(handle)
    return writer.data
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
    if let descriptor = try listLabptySessions().first(where: {
      $0.logicalSessionId == logicalSessionId
    }) {
      return labandInfo(from: descriptor)
    }
    throw TerminalSessionClientError.sessionNotFound(logicalSessionId)
  }

  public func detachSession(sessionId: String) throws -> LabandSessionInfo {
    return try labandInfo(from: descriptorForSessionId(sessionId))
  }

  public func writeInput(sessionId: String, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    try withFreshHandleRetry(sessionId: sessionId) { handle in
      try writeInput(handle: handle, bytes: bytes)
    }
  }

  public func resize(sessionId: String, rows: Int, cols: Int) throws -> LabandSessionInfo {
    try labandInfo(
      from: withFreshHandleRetry(sessionId: sessionId) { handle in
        try resize(handle: handle, rows: rows, cols: cols)
      })
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
    try labandInfo(
      from: withFreshHandleRetry(sessionId: sessionId) { handle in
        try terminate(handle: handle)
      })
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

  /// Idempotent control RPCs whose effect is safe to replay after a connection
  /// drop. The daemon force-closes an established client mid-response when its
  /// single-threaded event loop stalls past the 250 ms idle deadline (it has
  /// staged a response but not flushed it — the `force-expiring established
  /// client … write_total>0 write_sent=0` stderr line), which surfaces here as
  /// ECONNRESET even though the daemon is alive and the socket is still bound.
  /// A plain reconnect to the same socket then succeeds. openSession,
  /// writeInput, signalSession and terminateSession are excluded: their
  /// outcome after an unacknowledged drop is unknown, so replaying one could
  /// duplicate a session, re-inject input, or double-deliver a signal.
  private static let reconnectRetryableOperations: Set<LabptyOperation> = [
    .hello, .listSessions, .ping, .attachSession, .detachSession, .resizeSession,
  ]
  /// Total control-RPC attempts before surfacing the drop. The 20/40/80/160/320
  /// ms backoff between tries spans several daemon idle-deadline windows so a
  /// transient event-loop stall (a blocking handler such as fork/reap in open)
  /// clears before the final attempt.
  private static let maxReconnectAttempts = 6

  private func send<T>(
    operation: LabptyOperation,
    payload: Data,
    decode: (Data) throws -> T
  ) throws -> T {
    try lock.withLock {
      // Negotiate first, under hello's own idempotent retry policy. A transient
      // reset during this implicit hello must be recovered even when the caller
      // is a non-idempotent op (openSession/writeInput): re-negotiating is
      // always safe; it's only the op itself we must never replay. Folding the
      // hello into the op's wrapper would let .openSession's non-retryable
      // policy swallow a recoverable negotiation drop.
      if operation != .hello {
        try ensureNegotiatedLocked()
      }
      return try withReconnectRetryLocked(operation: operation) {
        // After an in-op reconnect, closeLocked cleared the negotiation, so a
        // retryable op re-negotiates here before replaying. A non-retryable op
        // never loops, so this runs at most once on the already-established
        // link and is a no-op (capabilities still set from above).
        if operation != .hello && negotiatedCapabilities == nil {
          _ = try helloLocked()
        }
        return try sendLocked(operation: operation, payload: payload, decode: decode)
      }
    }
  }

  /// Negotiate hello if not already done, retrying the *negotiation itself*
  /// under hello's idempotent reconnect policy. Must be called with `lock` held.
  private func ensureNegotiatedLocked() throws {
    guard negotiatedCapabilities == nil else { return }
    try withReconnectRetryLocked(operation: .hello) {
      _ = try helloLocked()
    }
  }

  /// Run a control round-trip, transparently reconnecting and replaying it when
  /// the daemon force-closes the connection mid-response (see
  /// `reconnectRetryableOperations`). Must be called with `lock` held. Only
  /// idempotent operations are replayed; everything else propagates the drop on
  /// the first failure. Never respawns the daemon — a plain reconnect to the
  /// still-bound socket is enough, since the loop stalled, it did not die.
  private func withReconnectRetryLocked<T>(
    operation: LabptyOperation,
    _ body: () throws -> T
  ) throws -> T {
    var attempt = 0
    while true {
      do {
        return try body()
      } catch {
        attempt += 1
        guard attempt < Self.maxReconnectAttempts,
          Self.reconnectRetryableOperations.contains(operation),
          Self.isTransientConnectionDrop(error)
        else { throw error }
        // sendLocked already closed the fd on the failing read/write; force it
        // shut regardless so the next iteration reconnects to the live socket.
        // This never respawns the daemon: ensureConnectedLocked only invokes
        // the respawn hook when connect() itself fails, and against a still-
        // bound socket it won't. Back off first to let the stalled event loop
        // drain its blocking handler and flush pending writes.
        closeLocked()
        usleep(UInt32(20_000) << (attempt - 1))
      }
    }
  }

  /// True for errors that mean "the connection dropped" rather than "the daemon
  /// rejected the request": a force-close (ECONNRESET / EPIPE), an I/O timeout
  /// against a stalled loop (ETIMEDOUT / EAGAIN), or a socket that went away
  /// (ENOTCONN / ECONNREFUSED). A `LabptyResponseError` is an application-level
  /// verdict (e.g. session-not-found) and is deliberately never retried here.
  private static func isTransientConnectionDrop(_ error: Error) -> Bool {
    guard let code = (error as? POSIXError)?.code else { return false }
    switch code {
    case .ECONNRESET, .EPIPE, .ENOTCONN, .ECONNREFUSED, .ETIMEDOUT, .EAGAIN:
      return true
    default:
      return false
    }
  }

  private func helloLocked() throws -> LabptyHelloResponse {
    let payload = try LabptyHelloRequest(clientId: clientId).encode()
    let response: LabptyHelloResponse = try sendLocked(
      operation: .hello,
      payload: payload,
      decode: LabptyHelloResponse.decode)
    try validateHello(response)
    negotiatedCapabilities = Set(response.capabilities)
    return response
  }

  private func validateHello(_ response: LabptyHelloResponse) throws {
    guard response.protocolMajor == LabptyFrameHeader.abiMajor else {
      throw LabptyProtocolError.versionMismatch
    }
    let capabilities = Set(response.capabilities)
    let missing = LabptyCapabilities.phase1.filter { !capabilities.contains($0) }
    guard missing.isEmpty else {
      throw TerminalSessionClientError.protocolError(
        "labpty missing required capabilities: \(missing.sorted().joined(separator: ","))")
    }
  }

  private func sendLocked<T>(
    operation: LabptyOperation,
    payload: Data,
    decode: (Data) throws -> T
  ) throws -> T {
    try ensureConnectedLocked()
    let sequence = nextSequence
    nextSequence += 1
    do {
      try writeAll(
        LabptyFraming.encodeRequest(operation: operation, sequence: sequence, payload: payload))
    } catch {
      closeLocked()
      throw error
    }
    let response: LabptyFrame
    do {
      response = try LabptyFraming.decode(try readFrame())
    } catch {
      closeLocked()
      throw error
    }
    guard response.header.sequence == sequence else {
      closeLocked()
      throw TerminalSessionClientError.protocolError("labpty response sequence mismatch")
    }
    guard response.header.responseCode == .ok else {
      throw LabptyResponseError(
        rawCode: response.header.codeRaw,
        message: Self.labptyErrorMessage(codeRaw: response.header.codeRaw))
    }
    return try decode(response.payload)
  }

  private func ensureConnectedLocked() throws {
    if fd >= 0 { return }
    do {
      fd = try Self.connect(socketPath: socketPath, timeoutMilliseconds: rpcTimeoutMilliseconds)
    } catch {
      // The socket is gone — labpty most likely crashed mid-session. If we
      // were handed a relaunch hook, spawn a fresh daemon on demand and retry
      // the connect once. Sessions from the dead daemon are not recovered
      // (labpty keeps its catalog in memory only); higher layers re-create
      // sessions against the new daemon. Without a hook we surface the error.
      guard let ensureDaemonRunning else { throw error }
      try ensureDaemonRunning()
      fd = try Self.connect(socketPath: socketPath, timeoutMilliseconds: rpcTimeoutMilliseconds)
    }
  }

  private func closeLocked() {
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
    }
    handlesBySessionId.removeAll()
    descriptorsByHandle.removeAll()
    negotiatedCapabilities = nil
  }

  private func cachedDescriptor(forSessionId sessionId: String) -> LabptySessionDescriptor? {
    lock.withLock {
      guard let handle = handlesBySessionId[sessionId] else { return nil }
      return descriptorsByHandle[handle]
    }
  }

  private func handleForSessionId(_ sessionId: String) throws -> UInt64 {
    if let handle = lock.withLock({ handlesBySessionId[sessionId] }) {
      return handle
    }
    _ = try listLabptySessions()
    if let handle = lock.withLock({ handlesBySessionId[sessionId] }) {
      return handle
    }
    throw TerminalSessionClientError.sessionNotFound(sessionId)
  }

  private func descriptorForSessionId(_ sessionId: String) throws -> LabptySessionDescriptor {
    if let descriptor = cachedDescriptor(forSessionId: sessionId) {
      return descriptor
    }
    _ = try listLabptySessions()
    if let descriptor = cachedDescriptor(forSessionId: sessionId) {
      return descriptor
    }
    throw TerminalSessionClientError.sessionNotFound(sessionId)
  }

  private func withFreshHandleRetry<T>(
    sessionId: String,
    _ operation: (UInt64) throws -> T
  ) throws -> T {
    let handle = try handleForSessionId(sessionId)
    do {
      return try operation(handle)
    } catch {
      guard isLabptySessionNotFound(error) else { throw error }
      forgetSessionId(sessionId)
      let freshHandle = try handleForSessionId(sessionId)
      guard freshHandle != handle else { throw error }
      return try operation(freshHandle)
    }
  }

  private func isLabptySessionNotFound(_ error: Error) -> Bool {
    if let response = error as? LabptyResponseError {
      return response.code == .sessionNotFound
    }
    if case TerminalSessionClientError.protocolError(let message) = error {
      return message == Self.labptyErrorMessage(codeRaw: LabptyErrorCode.sessionNotFound.rawValue)
    }
    return false
  }

  private func forgetSessionId(_ sessionId: String) {
    lock.withLock {
      if let handle = handlesBySessionId.removeValue(forKey: sessionId) {
        descriptorsByHandle.removeValue(forKey: handle)
      }
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
      // labpty no longer carries a foreground pid in its descriptor; fall
      // back to the child pid so callers that only have a labpty descriptor
      // still see a meaningful "running as" value. LabanApp paths that
      // need the actual foreground process resolve it via libproc.
      foregroundPid: descriptor.childPid > 0 ? Int(descriptor.childPid) : nil,
      daemonProcessPid: -1,
      cwd: "",
      commandDisplayName: "labpty",
      title: "",
      rows: Int(descriptor.rows),
      cols: Int(descriptor.cols),
      lifecycleState: descriptor.alive ? .running : .exited,
      // Use the daemon's real popcount(attached_clients) (ADR 0010), not a
      // faked liveness restatement — matches AppSessionCoordinator's path.
      attachedClientCount: Int(descriptor.connectedClients),
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

  private static func labptyErrorMessage(codeRaw: UInt16) -> String {
    "labpty error \(codeRaw)"
  }

  private static func connect(socketPath: String, timeoutMilliseconds: Int) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    try setTimeout(fd: fd, option: SO_RCVTIMEO, milliseconds: timeoutMilliseconds)
    try setTimeout(fd: fd, option: SO_SNDTIMEO, milliseconds: timeoutMilliseconds)
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

  private static func setTimeout(fd: Int32, option: Int32, milliseconds: Int) throws {
    let clamped = max(1, milliseconds)
    var timeout = timeval(
      tv_sec: clamped / 1000,
      tv_usec: Int32((clamped % 1000) * 1000))
    let result = setsockopt(
      fd,
      SOL_SOCKET,
      option,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size))
    guard result == 0 else {
      let err = errno
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
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
    guard totalLength <= LabptyFrameHeader.maxFrameBytes else {
      throw LabptyProtocolError.oversizeFrame
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
