import Darwin
import Foundation

public final class LabandTerminalSessionClient: TerminalSessionClient {
  public let transportMode = "laband"

  private let socketPath: String
  private var fd: Int32
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let clientId = UUID().uuidString
  public var clientIdentifier: String { clientId }
  private let autoRenewLeases: Bool
  private var ringReaders: [String: LabandSnapshotRingReader] = [:]
  private var attachedSessionIds: Set<String> = []
  private var leasesBySession: [String: LabandLeaseInfo] = [:]
  private let leaseRenewalQueue = DispatchQueue(label: "laband-lease-renewal")
  private var leaseRenewalTimer: DispatchSourceTimer?

  public init(socketPath: String, autoRenewLeases: Bool = true) throws {
    self.socketPath = socketPath
    self.autoRenewLeases = autoRenewLeases
    self.fd = try Self.connect(socketPath: socketPath)
  }

  deinit {
    close()
  }

  public func close() {
    let sessions = lock.withLock { Array(attachedSessionIds) }
    for sessionId in sessions {
      _ = try? detachSession(sessionId: sessionId)
    }
    lock.withLock {
      attachedSessionIds.removeAll()
      ringReaders.removeAll()
      leasesBySession.removeAll()
      leaseRenewalTimer?.cancel()
      leaseRenewalTimer = nil
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
        clientId: clientId,
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
    lock.withLock {
      _ = attachedSessionIds.insert(session.logicalSessionId)
    }
    updateLeaseCache(from: session)
    return session
  }

  public func listSessions() throws -> [LabandSessionInfo] {
    let response = try send(LabandRequest(requestId: UUID().uuidString, type: .listSessions))
    let sessions = response.sessions ?? []
    for session in sessions { updateLeaseCache(from: session) }
    return sessions
  }

  public func attachSession(logicalSessionId: String) throws -> LabandSessionInfo {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .attachSession,
        clientId: clientId,
        logicalSessionId: logicalSessionId
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("attachSession response missing session")
    }
    lock.withLock {
      _ = attachedSessionIds.insert(session.logicalSessionId)
    }
    updateLeaseCache(from: session)
    return session
  }

  public func detachSession(sessionId: String) throws -> LabandSessionInfo {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .detachSession,
        clientId: clientId,
        sessionId: sessionId
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("detachSession response missing session")
    }
    lock.withLock {
      attachedSessionIds.remove(session.logicalSessionId)
      _ = ringReaders.removeValue(forKey: session.logicalSessionId)
    }
    updateLeaseCache(from: session)
    return session
  }

  public func writeInput(sessionId: String, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    let lease = currentLease(sessionId: sessionId)
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .writeInput,
        clientId: clientId,
        sessionId: sessionId,
        bytesBase64: Data(bytes).base64EncodedString(),
        leaseId: lease?.leaseId,
        leaseEpoch: lease?.epoch
      )
    )
    if let session = response.session { updateLeaseCache(from: session) }
  }

  public func resize(sessionId: String, rows: Int, cols: Int) throws -> LabandSessionInfo {
    let lease = currentLease(sessionId: sessionId)
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .resizeSession,
        clientId: clientId,
        rows: rows,
        cols: cols,
        sessionId: sessionId,
        leaseId: lease?.leaseId,
        leaseEpoch: lease?.epoch
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("resizeSession response missing session")
    }
    updateLeaseCache(from: session)
    return session
  }

  public func attachSnapshotRing(sessionId: String) throws -> LabandSnapshotRingAttachment {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .attachSnapshotRing,
        clientId: clientId,
        sessionId: sessionId
      )
    )
    guard let attachment = response.snapshotRing else {
      throw TerminalSessionClientError.protocolError("attachSnapshotRing response missing payload")
    }
    let session = response.session
    let logicalSessionId = session?.logicalSessionId ?? sessionId
    let incarnationId = session?.incarnationId ?? ""
    let reader = try LabandSnapshotRingReader(
      attachment: attachment,
      logicalSessionId: logicalSessionId,
      incarnationId: incarnationId
    )
    lock.withLock {
      ringReaders[sessionId] = reader
      _ = attachedSessionIds.insert(logicalSessionId)
    }
    if let session { updateLeaseCache(from: session) }
    return attachment
  }

  public func snapshot(sessionId: String) throws -> LabandSnapshotResponse {
    if let ringSnapshot = try readRingSnapshot(sessionId: sessionId) {
      return ringSnapshot
    }
    if (try? attachSnapshotRing(sessionId: sessionId)) != nil,
      let ringSnapshot = try readRingSnapshot(sessionId: sessionId)
    {
      return ringSnapshot
    }
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

  public func scrollViewport(sessionId: String, deltaRows: Int) throws -> LabandSessionInfo {
    let lease = currentLease(sessionId: sessionId)
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .scrollViewport,
        clientId: clientId,
        sessionId: sessionId,
        deltaRows: deltaRows,
        leaseId: lease?.leaseId,
        leaseEpoch: lease?.epoch
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("scrollViewport response missing session")
    }
    updateLeaseCache(from: session)
    return session
  }

  public func snapshotRingReader(sessionId: String) throws -> LabandSnapshotRingReader {
    if let reader = lock.withLock({ ringReaders[sessionId] }) {
      return reader
    }
    _ = try attachSnapshotRing(sessionId: sessionId)
    guard let reader = lock.withLock({ ringReaders[sessionId] }) else {
      throw TerminalSessionClientError.protocolError("snapshot ring reader was not attached")
    }
    return reader
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

  public func applyTheme(
    sessionId: String,
    paletteBytes: [UInt8],
    colorScheme: TerminalColorScheme
  ) throws {
    guard !paletteBytes.isEmpty else { return }
    let colorSchemeName: String
    switch colorScheme {
    case .dark:
      colorSchemeName = "dark"
    case .light:
      colorSchemeName = "light"
    }
    _ = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .applyTheme,
        clientId: clientId,
        sessionId: sessionId,
        bytesBase64: Data(paletteBytes).base64EncodedString(),
        colorScheme: colorSchemeName
      )
    )
  }

  public func transferLease(sessionId: String, holderClientId: String) throws -> LabandSessionInfo {
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .transferLease,
        clientId: clientId,
        sessionId: sessionId,
        leaseHolder: holderClientId
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("transferLease response missing session")
    }
    updateLeaseCache(from: session)
    return session
  }

  @discardableResult
  public func renewLease(sessionId: String) throws -> LabandSessionInfo {
    guard let lease = currentLease(sessionId: sessionId) else {
      throw TerminalSessionClientError.protocolError("no local lease for \(sessionId)")
    }
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .renewLease,
        clientId: clientId,
        sessionId: sessionId,
        leaseId: lease.leaseId,
        leaseEpoch: lease.epoch
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("renewLease response missing session")
    }
    updateLeaseCache(from: session)
    return session
  }

  public func terminate(sessionId: String) throws -> LabandSessionInfo {
    lock.withLock {
      attachedSessionIds.remove(sessionId)
      _ = ringReaders.removeValue(forKey: sessionId)
    }
    let response = try send(
      LabandRequest(
        requestId: UUID().uuidString,
        type: .terminateSession,
        clientId: clientId,
        sessionId: sessionId
      )
    )
    guard let session = response.session else {
      throw TerminalSessionClientError.protocolError("terminateSession response missing session")
    }
    updateLeaseCache(from: session)
    return session
  }

  public func currentLease(sessionId: String) -> LabandLeaseInfo? {
    lock.withLock { leasesBySession[sessionId] }
  }

  private func readRingSnapshot(sessionId: String) throws -> LabandSnapshotResponse? {
    guard let reader = lock.withLock({ ringReaders[sessionId] }) else { return nil }
    do {
      return try reader.latestSnapshot()
    } catch LabandSnapshotRingError.noCompletedSnapshot {
      return nil
    }
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

  private func updateLeaseCache(from session: LabandSessionInfo) {
    lock.withLock {
      if let lease = session.lease, lease.holderClientId == clientId {
        leasesBySession[session.logicalSessionId] = lease
      } else {
        leasesBySession.removeValue(forKey: session.logicalSessionId)
      }
    }
    configureLeaseRenewalTimer()
  }

  private func configureLeaseRenewalTimer() {
    guard autoRenewLeases else { return }
    lock.withLock {
      if leasesBySession.isEmpty {
        leaseRenewalTimer?.cancel()
        leaseRenewalTimer = nil
        return
      }
      guard leaseRenewalTimer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: leaseRenewalQueue)
      timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
      timer.setEventHandler { [weak self] in
        self?.renewOwnedLeasesIfNeeded()
      }
      leaseRenewalTimer = timer
      timer.resume()
    }
  }

  private func renewOwnedLeasesIfNeeded() {
    let leases = lock.withLock { Array(leasesBySession.values) }
    let now = DispatchTime.now().uptimeNanoseconds
    for lease in leases {
      let ttl =
        lease.expiresAtMonoNs > lease.grantedAtMonoNs
        ? lease.expiresAtMonoNs - lease.grantedAtMonoNs
        : 0
      let renewMargin = max(ttl / 3, 1_000_000_000)
      if lease.expiresAtMonoNs <= now + renewMargin {
        _ = try? renewLease(sessionId: lease.sessionId)
      }
    }
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

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
