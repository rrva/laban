import Darwin
import Foundation
import LabanCore
import LabanTerminalCore

private enum LabandMainError: Error, CustomStringConvertible {
  case missingValue(String)
  case missingSocket
  case missingJournal
  case missingEndpoint
  case socketPathTooLong(String)
  case socketCall(String, Int32)
  case invalidFrameLength(UInt32)

  var description: String {
    switch self {
    case .missingValue(let flag):
      return "missing value for \(flag)"
    case .missingSocket:
      return "missing required --socket"
    case .missingJournal:
      return "missing required --journal"
    case .missingEndpoint:
      return "missing required --socket or --xpc-service"
    case .socketPathTooLong(let path):
      return "socket path is too long for AF_UNIX: \(path)"
    case .socketCall(let call, let errnoValue):
      return "\(call) failed: \(String(cString: strerror(errnoValue)))"
    case .invalidFrameLength(let length):
      return "invalid frame length \(length)"
    }
  }
}

private struct LabandArguments {
  var socketPath: String?
  var journalPath: String
  var xpcServiceName: String?
  var productMode: Bool

  static func parse(_ args: [String]) throws -> LabandArguments {
    var socketPath: String?
    var journalPath: String?
    var xpcServiceName: String?
    var productMode = false
    var index = 1
    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--product":
        productMode = true
      case "--socket":
        index += 1
        guard index < args.count else { throw LabandMainError.missingValue(arg) }
        socketPath = args[index]
      case "--journal":
        index += 1
        guard index < args.count else { throw LabandMainError.missingValue(arg) }
        journalPath = args[index]
      case "--xpc-service":
        index += 1
        guard index < args.count else { throw LabandMainError.missingValue(arg) }
        xpcServiceName = args[index]
      case "--help", "-h":
        print(
          "usage: laband --socket .tmp/<run-id>/laband.sock --journal .artifacts/runs/<run-id>/laband"
        )
        print("   or: laband --product --xpc-service <mach-service>")
        exit(0)
      default:
        fputs("laband: unknown argument \(arg)\n", stderr)
        exit(2)
      }
      index += 1
    }
    if productMode, journalPath == nil {
      journalPath = LabandProductPaths.default().journalDirectoryURL.path
    }
    if !productMode, socketPath == nil { throw LabandMainError.missingSocket }
    guard let journalPath else { throw LabandMainError.missingJournal }
    if socketPath == nil, xpcServiceName == nil { throw LabandMainError.missingEndpoint }
    return LabandArguments(
      socketPath: socketPath,
      journalPath: journalPath,
      xpcServiceName: xpcServiceName,
      productMode: productMode
    )
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

private enum LabandJournalEvent: String, Codable {
  case sessionCreated
  case leaseGranted
  case leaseTransferred
  case leaseRevoked
  case terminateRequested
  case sessionTerminated
}

private struct LabandJournalRecord: Codable {
  var version: Int
  var offset: UInt64
  var monoNs: UInt64
  var event: LabandJournalEvent
  var logicalSessionId: String
  var incarnationId: String
  var childPid: Int?
  var foregroundPid: Int?
  var cwd: String
  var commandDisplayName: String
  var title: String
  var rows: Int
  var cols: Int
  var lifecycleState: LabandLifecycleState
  var leaseHolder: String?
  var leaseId: String?
  var leaseEpoch: UInt64?
  var leaseExpiresAtMonoNs: UInt64?
}

private final class LabandLifecycleJournal {
  let filePath: String

  private let fd: Int32
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    self.filePath =
      URL(fileURLWithPath: directory)
      .appendingPathComponent("lifecycle.jsonl").path
    fd = Darwin.open(filePath, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    encoder.outputFormatting = [.sortedKeys]
  }

  deinit {
    Darwin.close(fd)
  }

  func replayRecords() -> [LabandJournalRecord] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    var records: [LabandJournalRecord] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      if let data = String(line).data(using: .utf8),
        let record = try? decoder.decode(LabandJournalRecord.self, from: data)
      {
        records.append(record)
      }
    }
    return records
  }

  func append(_ record: LabandJournalRecord) throws {
    try lock.withLock {
      var writable = record
      let offset = Darwin.lseek(fd, 0, SEEK_END)
      guard offset >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      writable.offset = UInt64(offset)
      let payload = try encoder.encode(writable) + Data([0x0A])
      var written = 0
      while written < payload.count {
        let count = payload.count - written
        let n = payload.withUnsafeBytes { raw -> Int in
          guard let base = raw.baseAddress else { return -1 }
          return Darwin.write(fd, base.advanced(by: written), count)
        }
        if n < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        written += n
      }
      guard Darwin.fsync(fd) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }
}

private final class ManagedLabandSession {
  private let lock = NSLock()
  let logicalSessionId: String
  let incarnationId: String
  let commandDisplayName: String
  let cwd: String
  var rows: Int
  var cols: Int
  var lifecycleState: LabandLifecycleState = .running
  var title: String
  var childPid: Int?
  var foregroundPid: Int?
  var session: Session?
  var runner: SessionRunner?
  var ringWriter: LabandSnapshotRingWriter?
  var lease: LabandLeaseInfo?
  var leaseHolder: String? { lease?.holderClientId }
  var leaseHistory: [LabandLeaseHistoryEntry] = []
  private var attachedClientIds: Set<String> = []
  private var inputSequence: UInt64 = 0

  init(
    logicalSessionId: String,
    incarnationId: String,
    commandDisplayName: String,
    cwd: String,
    rows: Int,
    cols: Int,
    title: String,
    session: Session?,
    lifecycleState: LabandLifecycleState = .running,
    childPid: Int? = nil,
    foregroundPid: Int? = nil,
    lease: LabandLeaseInfo? = nil,
    leaseHistory: [LabandLeaseHistoryEntry] = []
  ) {
    self.logicalSessionId = logicalSessionId
    self.incarnationId = incarnationId
    self.commandDisplayName = commandDisplayName
    self.cwd = cwd
    self.rows = rows
    self.cols = cols
    self.title = title
    self.lifecycleState = lifecycleState
    self.childPid = childPid
    self.foregroundPid = foregroundPid
    self.session = session
    self.lease = lease
    self.leaseHistory = leaseHistory
  }

  func recordInput() -> UInt64 {
    lock.withLock {
      inputSequence &+= 1
      if inputSequence == 0 { inputSequence = 1 }
      return inputSequence
    }
  }

  func currentInputSequence() -> UInt64 {
    lock.withLock { inputSequence }
  }

  func attachClient(_ clientId: String?) {
    guard let clientId, !clientId.isEmpty else { return }
    lock.withLock {
      _ = attachedClientIds.insert(clientId)
    }
  }

  func detachClient(_ clientId: String?) {
    guard let clientId, !clientId.isEmpty else { return }
    lock.withLock {
      _ = attachedClientIds.remove(clientId)
    }
  }

  func isClientAttached(_ clientId: String?) -> Bool {
    guard let clientId, !clientId.isEmpty else { return false }
    return lock.withLock { attachedClientIds.contains(clientId) }
  }

  func detachAllClients() {
    lock.withLock {
      attachedClientIds.removeAll()
    }
  }

  func attachedClientCount() -> Int {
    lock.withLock { attachedClientIds.count }
  }

  func publishSnapshot(ptyDrainMonoNs: UInt64 = LabandSnapshotRingLayout.monotonicNanoseconds()) {
    guard let ringWriter, lifecycleState == .running, let session, let snapshot = session.snapshot()
    else { return }
    defer { laban_snapshot_destroy(snapshot) }
    let inputSeq = currentInputSequence()
    try? ringWriter.publish(
      snapshot: UnsafePointer(snapshot),
      inputSeqApplied: inputSeq,
      echoAckSeq: inputSeq,
      ptyDrainMonoNs: ptyDrainMonoNs
    )
  }
}

private final class LabandDaemon {
  private let journalPath: String
  private let journal: LabandLifecycleJournal
  private let leaseTimeoutNs: UInt64
  private let lock = NSLock()
  private var sessions: [String: ManagedLabandSession] = [:]
  var onShutdown: (() -> Void)?

  init(journalPath: String) throws {
    self.journalPath = journalPath
    self.journal = try LabandLifecycleJournal(directory: journalPath)
    self.leaseTimeoutNs = Self.configuredLeaseTimeoutNs()
    replayJournal()
  }

  private static func configuredLeaseTimeoutNs(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> UInt64 {
    let defaultMs: UInt64 = 30_000
    guard let raw = environment["LABAN_LABAND_LEASE_TTL_MS"],
      let ms = UInt64(raw),
      ms > 0
    else {
      return defaultMs * 1_000_000
    }
    return ms * 1_000_000
  }

  func handle(_ request: LabandRequest) -> (LabandResponse, Bool) {
    guard request.protocolVersion >= LabandProtocolVersion.minimumCompatible,
      request.protocolVersion <= LabandProtocolVersion.current
    else {
      return (
        .error(
          requestId: request.requestId,
          type: request.type,
          code: "protocolVersionUnsupported",
          message:
            "protocolVersion \(request.protocolVersion) is not supported; supported range is \(LabandProtocolVersion.minimumCompatible)...\(LabandProtocolVersion.current)"
        ),
        false
      )
    }

    switch request.type {
    case .hello:
      return (hello(request), false)
    case .attachSession:
      return (attachSession(request), false)
    case .detachSession:
      return (detachSession(request), false)
    case .createSession:
      return (createSession(request), false)
    case .listSessions:
      return (listSessions(request), false)
    case .writeInput:
      return (writeInput(request), false)
    case .snapshot:
      return (snapshot(request), false)
    case .attachSnapshotRing:
      return (attachSnapshotRing(request), false)
    case .applyTheme:
      return (applyTheme(request), false)
    case .resizeSession:
      return (resizeSession(request), false)
    case .markRendered:
      return (markRendered(request), false)
    case .transferLease:
      return (transferLease(request), false)
    case .renewLease:
      return (renewLease(request), false)
    case .terminateSession:
      return (terminateSession(request), false)
    case .shutdownWhenIdle:
      let response = shutdownWhenIdle(request)
      return (response, response.ok)
    }
  }

  private func hello(_ request: LabandRequest) -> LabandResponse {
    LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      hello: LabandHelloResponse(
        protocolVersion: LabandProtocolVersion.current,
        minimumProtocolVersion: LabandProtocolVersion.minimumCompatible,
        buildVersion: "dev",
        capabilities: [
          "control-json/v1",
          "xpc-control/v1",
          "product-launch-agent/v1",
          "protocol-negotiation/v1",
          "copy-snapshot/v1",
          "theme-palette/v1",
          "snapshot-ring/v1",
          "client-attach/v1",
          "lifecycle-journal/v1",
          "lease-transfer/v1",
          "lease-token/v1",
          "lease-renew/v1",
          "single-writer/v1",
        ]
      )
    )
  }

  private func createSession(_ request: LabandRequest) -> LabandResponse {
    let rows = max(1, request.rows ?? 24)
    let cols = max(1, request.cols ?? 80)
    let cwd = request.cwd ?? FileManager.default.currentDirectoryPath
    let executable = request.executable ?? request.argv?.first
    let launchArgv: [String]?
    if let argv = request.argv, !argv.isEmpty {
      launchArgv = argv
    } else if let executable, !executable.isEmpty {
      launchArgv = [executable]
    } else {
      launchArgv = nil
    }
    let commandDisplayName =
      (launchArgv?.first ?? executable ?? "shell").split(separator: "/").last.map(String.init)
      ?? "shell"

    do {
      var size = LabanTerminalSize()
      size.rows = Int32(rows)
      size.cols = Int32(cols)
      let session = try Session.realShell(
        size: size,
        cwd: cwd,
        environment: request.environmentPatch ?? [:],
        launchArgv: launchArgv
      )
      let logicalSessionId =
        request.logicalSessionId?.isEmpty == false ? request.logicalSessionId! : UUID().uuidString
      let managed = ManagedLabandSession(
        logicalSessionId: logicalSessionId,
        incarnationId: UUID().uuidString,
        commandDisplayName: commandDisplayName,
        cwd: cwd,
        rows: rows,
        cols: cols,
        title: commandDisplayName,
        session: session
      )
      managed.attachClient(request.clientId)
      managed.runner = session.makeRunner(onDirty: { [weak managed] in
        managed?.publishSnapshot()
      })
      managed.runner?.start()
      refreshProcessMetadata(managed)
      do {
        try appendJournal(event: .sessionCreated, managed: managed)
      } catch {
        managed.runner?.stop()
        managed.session?.close()
        return .error(
          requestId: request.requestId,
          type: request.type,
          code: "journalAppendFailed",
          message: String(describing: error)
        )
      }
      if let clientId = request.clientId, !clientId.isEmpty {
        grantLease(
          to: clientId,
          managed: managed,
          now: LabandSnapshotRingLayout.monotonicNanoseconds()
        )
        do {
          try appendJournal(event: .leaseGranted, managed: managed)
        } catch {
          managed.runner?.stop()
          managed.session?.close()
          return .error(
            requestId: request.requestId,
            type: request.type,
            code: "journalAppendFailed",
            message: String(describing: error)
          )
        }
      }
      let info = sessionInfo(managed)
      lock.withLock {
        sessions[logicalSessionId] = managed
      }
      return LabandResponse(
        requestId: request.requestId,
        type: request.type,
        ok: true,
        session: info
      )
    } catch {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "createSessionFailed",
        message: String(describing: error)
      )
    }
  }

  private func attachSession(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    managed.attachClient(request.clientId)
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func detachSession(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    managed.detachClient(request.clientId)
    if let clientId = request.clientId, managed.lease?.holderClientId == clientId {
      revokeLease(managed, now: LabandSnapshotRingLayout.monotonicNanoseconds())
      do {
        try appendJournal(event: .leaseRevoked, managed: managed)
      } catch {
        return .error(
          requestId: request.requestId,
          type: request.type,
          code: "journalAppendFailed",
          message: String(describing: error)
        )
      }
    }
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func listSessions(_ request: LabandRequest) -> LabandResponse {
    let infos = lock.withLock {
      sessions.values.sorted { $0.logicalSessionId < $1.logicalSessionId }.map { managed in
        refreshProcessMetadata(managed)
        return sessionInfo(managed)
      }
    }
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      sessions: infos
    )
  }

  private func writeInput(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    guard managed.lifecycleState == .running, let session = managed.session else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "sessionNotRunning",
        message: "session is not running"
      )
    }
    if let denial = validateLease(request, managed: managed) {
      return denial
    }

    var bytes: [UInt8] = []
    if let text = request.text {
      bytes.append(contentsOf: text.utf8)
    }
    if let bytesBase64 = request.bytesBase64 {
      guard let data = Data(base64Encoded: bytesBase64) else {
        return .error(
          requestId: request.requestId,
          type: request.type,
          code: "invalidBase64",
          message: "bytesBase64 is not valid base64"
        )
      }
      bytes.append(contentsOf: data)
    }
    guard !bytes.isEmpty else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "emptyInput",
        message: "writeInput requires text or bytesBase64"
      )
    }
    _ = managed.recordInput()
    let wrote = session.write(bytes)
    guard wrote >= 0 else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "writeFailed",
        message: "failed to write input to PTY"
      )
    }
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func applyTheme(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    guard managed.lifecycleState == .running, let session = managed.session else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "sessionNotRunning",
        message: "session is not running"
      )
    }
    guard let bytesBase64 = request.bytesBase64,
      let data = Data(base64Encoded: bytesBase64)
    else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "invalidBase64",
        message: "applyTheme requires valid bytesBase64"
      )
    }

    switch request.colorScheme {
    case "dark":
      _ = session.setColorScheme(.dark)
    case "light":
      _ = session.setColorScheme(.light)
    case nil:
      break
    default:
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "invalidColorScheme",
        message: "colorScheme must be dark or light"
      )
    }

    guard session.feedOutput(Array(data)) >= 0 else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "themeApplyFailed",
        message: "failed to apply theme palette"
      )
    }
    managed.publishSnapshot()
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func attachSnapshotRing(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    guard managed.lifecycleState == .running, managed.session != nil else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "sessionNotRunning",
        message: "session is not running"
      )
    }
    do {
      managed.attachClient(request.clientId)
      let writer = try ensureSnapshotRing(managed)
      managed.publishSnapshot()
      return LabandResponse(
        requestId: request.requestId,
        type: request.type,
        ok: true,
        session: sessionInfo(managed),
        snapshotRing: writer.attachment
      )
    } catch {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "snapshotRingFailed",
        message: String(describing: error),
        retryable: true
      )
    }
  }

  private func snapshot(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    guard let snapshot = snapshotResponse(managed) else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "snapshotFailed",
        message: "failed to capture session snapshot",
        retryable: managed.lifecycleState == .running
      )
    }
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      snapshot: snapshot
    )
  }

  private func resizeSession(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    guard managed.lifecycleState == .running, let session = managed.session else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "sessionNotRunning",
        message: "session is not running"
      )
    }
    if let denial = validateLease(request, managed: managed) {
      return denial
    }
    let rows = max(1, request.rows ?? managed.rows)
    let cols = max(1, request.cols ?? managed.cols)
    var size = LabanTerminalSize()
    size.rows = Int32(rows)
    size.cols = Int32(cols)
    guard session.resize(size) == 0 else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "resizeFailed",
        message: "failed to resize session"
      )
    }
    managed.rows = rows
    managed.cols = cols
    managed.publishSnapshot()
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func terminateSession(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    refreshProcessMetadata(managed)
    do {
      try appendJournal(event: .terminateRequested, managed: managed)
    } catch {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "journalAppendFailed",
        message: String(describing: error)
      )
    }
    managed.runner?.stop()
    managed.runner = nil
    managed.session?.close()
    managed.session = nil
    managed.ringWriter = nil
    managed.detachAllClients()
    managed.lifecycleState = .terminated
    do {
      try appendJournal(event: .sessionTerminated, managed: managed)
    } catch {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "journalAppendFailed",
        message: String(describing: error)
      )
    }
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func markRendered(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    _ = managed.session?.markRendered()
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func transferLease(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    guard let holder = request.leaseHolder, !holder.isEmpty else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "missingLeaseHolder",
        message: "transferLease requires leaseHolder"
      )
    }
    if let clientId = request.clientId, clientId != holder {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "leaseHolderMismatch",
        message: "clients may only request control for themselves"
      )
    }
    let now = LabandSnapshotRingLayout.monotonicNanoseconds()
    var event: LabandJournalEvent = managed.lease == nil ? .leaseGranted : .leaseTransferred
    if let revoked = revokeExpiredLeaseIfNeeded(managed, now: now, request: request) {
      if !revoked.ok { return revoked }
      event = .leaseGranted
    }
    let priorLease = managed.lease
    let priorHistoryCount = managed.leaseHistory.count
    grantLease(to: holder, managed: managed, now: now)
    do {
      try appendJournal(event: event, managed: managed)
    } catch {
      managed.lease = priorLease
      if managed.leaseHistory.count > priorHistoryCount {
        managed.leaseHistory.removeLast(managed.leaseHistory.count - priorHistoryCount)
      }
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "journalAppendFailed",
        message: String(describing: error)
      )
    }
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func renewLease(_ request: LabandRequest) -> LabandResponse {
    guard let managed = lookup(request) else {
      return missingSession(request)
    }
    if let denial = validateLease(request, managed: managed) {
      return denial
    }
    let now = LabandSnapshotRingLayout.monotonicNanoseconds()
    managed.lease?.expiresAtMonoNs = now + leaseTimeoutNs
    return LabandResponse(
      requestId: request.requestId,
      type: request.type,
      ok: true,
      session: sessionInfo(managed)
    )
  }

  private func validateLease(
    _ request: LabandRequest,
    managed: ManagedLabandSession
  ) -> LabandResponse? {
    let now = LabandSnapshotRingLayout.monotonicNanoseconds()
    if let revoked = revokeExpiredLeaseIfNeeded(managed, now: now, request: request) {
      guard revoked.ok else { return revoked }
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "leaseExpired",
        message: "the session lease expired",
        retryable: true
      )
    }
    guard let lease = managed.lease else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "leaseRequired",
        message: "writeInput and resizeSession require the current lease id and epoch",
        retryable: true
      )
    }
    guard let requestLeaseId = request.leaseId,
      let requestEpoch = request.leaseEpoch
    else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "leaseRequired",
        message: "request is missing the current lease id or epoch",
        retryable: true
      )
    }
    guard requestLeaseId == lease.leaseId, requestEpoch == lease.epoch else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "staleLease",
        message: "request lease id or epoch does not match the current lease",
        retryable: true
      )
    }
    guard let clientId = request.clientId, clientId == lease.holderClientId else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "leaseNotHeld",
        message: "client does not hold the current session lease",
        retryable: true
      )
    }
    return nil
  }

  private func revokeExpiredLeaseIfNeeded(
    _ managed: ManagedLabandSession,
    now: UInt64,
    request: LabandRequest
  ) -> LabandResponse? {
    guard let lease = managed.lease, lease.expiresAtMonoNs <= now else { return nil }
    revokeLease(managed, now: now)
    do {
      try appendJournal(event: .leaseRevoked, managed: managed)
      return LabandResponse(requestId: request.requestId, type: request.type, ok: true)
    } catch {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "journalAppendFailed",
        message: String(describing: error)
      )
    }
  }

  private func grantLease(
    to holder: String,
    managed: ManagedLabandSession,
    now: UInt64
  ) {
    let previousEpoch = managed.lease?.epoch ?? managed.leaseHistory.compactMap(\.epoch).max() ?? 0
    let lease = LabandLeaseInfo(
      leaseId: UUID().uuidString,
      sessionId: managed.logicalSessionId,
      holderClientId: holder,
      epoch: previousEpoch + 1,
      grantedAtMonoNs: now,
      expiresAtMonoNs: now + leaseTimeoutNs
    )
    managed.lease = lease
    managed.leaseHistory.append(
      LabandLeaseHistoryEntry(
        leaseHolder: holder,
        grantedAtMonoNs: lease.grantedAtMonoNs,
        leaseId: lease.leaseId,
        epoch: lease.epoch,
        expiresAtMonoNs: lease.expiresAtMonoNs
      ))
  }

  private func revokeLease(_ managed: ManagedLabandSession, now _: UInt64) {
    managed.lease = nil
  }

  private func revokeExpiredLeaseForCatalog(_ managed: ManagedLabandSession) {
    guard managed.lifecycleState == .running, managed.session != nil else { return }
    let now = LabandSnapshotRingLayout.monotonicNanoseconds()
    guard let lease = managed.lease, lease.expiresAtMonoNs <= now else { return }
    revokeLease(managed, now: now)
    try? appendJournal(event: .leaseRevoked, managed: managed)
  }

  private func shutdownWhenIdle(_ request: LabandRequest) -> LabandResponse {
    let liveCount = lock.withLock {
      sessions.values.filter { $0.lifecycleState == .running && $0.session != nil }.count
    }
    guard liveCount == 0 else {
      return .error(
        requestId: request.requestId,
        type: request.type,
        code: "liveSessionsExist",
        message: "refusing shutdown with \(liveCount) live session(s)",
        retryable: true
      )
    }
    return LabandResponse(requestId: request.requestId, type: request.type, ok: true)
  }

  private func lookup(_ request: LabandRequest) -> ManagedLabandSession? {
    guard let sessionId = request.sessionId ?? request.logicalSessionId else { return nil }
    return lock.withLock { sessions[sessionId] }
  }

  private func missingSession(_ request: LabandRequest) -> LabandResponse {
    .error(
      requestId: request.requestId,
      type: request.type,
      code: "sessionNotFound",
      message: "sessionId or logicalSessionId did not identify a session"
    )
  }

  private func refreshProcessMetadata(_ managed: ManagedLabandSession) {
    guard managed.lifecycleState == .running, let metadata = managed.session?.processMetadata()
    else { return }
    managed.childPid = metadata.childPid
    managed.foregroundPid = metadata.foregroundPid
  }

  private func replayJournal() {
    var restored: [String: ManagedLabandSession] = [:]
    for record in journal.replayRecords() {
      switch record.event {
      case .sessionCreated:
        restored[record.logicalSessionId] = ManagedLabandSession(
          logicalSessionId: record.logicalSessionId,
          incarnationId: record.incarnationId,
          commandDisplayName: record.commandDisplayName,
          cwd: record.cwd,
          rows: record.rows,
          cols: record.cols,
          title: record.title,
          session: nil,
          lifecycleState: record.lifecycleState == .running ? .dead : record.lifecycleState,
          childPid: record.childPid,
          foregroundPid: record.foregroundPid,
          lease: leaseInfo(from: record)
        )
        if let lease = restored[record.logicalSessionId]?.lease {
          restored[record.logicalSessionId]?.leaseHistory.append(
            LabandLeaseHistoryEntry(
              leaseHolder: lease.holderClientId,
              grantedAtMonoNs: lease.grantedAtMonoNs,
              leaseId: lease.leaseId,
              epoch: lease.epoch,
              expiresAtMonoNs: lease.expiresAtMonoNs
            ))
        }
      case .leaseGranted, .leaseTransferred:
        guard let managed = restored[record.logicalSessionId],
          let lease = leaseInfo(from: record)
        else { continue }
        managed.lease = lease
        managed.leaseHistory.append(
          LabandLeaseHistoryEntry(
            leaseHolder: lease.holderClientId,
            grantedAtMonoNs: lease.grantedAtMonoNs,
            leaseId: lease.leaseId,
            epoch: lease.epoch,
            expiresAtMonoNs: lease.expiresAtMonoNs
          ))
      case .leaseRevoked:
        restored[record.logicalSessionId]?.lease = nil
      case .terminateRequested, .sessionTerminated:
        guard let managed = restored[record.logicalSessionId] else { continue }
        managed.lifecycleState = record.lifecycleState
        managed.session = nil
        managed.runner = nil
        managed.ringWriter = nil
        managed.childPid = record.childPid ?? managed.childPid
        managed.foregroundPid = record.foregroundPid ?? managed.foregroundPid
      }
    }
    sessions = restored
  }

  private func leaseInfo(from record: LabandJournalRecord) -> LabandLeaseInfo? {
    guard let holder = record.leaseHolder else { return nil }
    let epoch = record.leaseEpoch ?? 1
    return LabandLeaseInfo(
      leaseId: record.leaseId ?? "replayed-\(record.offset)-\(epoch)",
      sessionId: record.logicalSessionId,
      holderClientId: holder,
      epoch: epoch,
      grantedAtMonoNs: record.monoNs,
      expiresAtMonoNs: record.leaseExpiresAtMonoNs ?? record.monoNs
    )
  }

  private func appendJournal(event: LabandJournalEvent, managed: ManagedLabandSession) throws {
    try journal.append(
      LabandJournalRecord(
        version: 1,
        offset: 0,
        monoNs: LabandSnapshotRingLayout.monotonicNanoseconds(),
        event: event,
        logicalSessionId: managed.logicalSessionId,
        incarnationId: managed.incarnationId,
        childPid: managed.childPid,
        foregroundPid: managed.foregroundPid,
        cwd: managed.cwd,
        commandDisplayName: managed.commandDisplayName,
        title: managed.title,
        rows: managed.rows,
        cols: managed.cols,
        lifecycleState: managed.lifecycleState,
        leaseHolder: managed.leaseHolder,
        leaseId: managed.lease?.leaseId,
        leaseEpoch: managed.lease?.epoch,
        leaseExpiresAtMonoNs: managed.lease?.expiresAtMonoNs
      ))
  }

  private func sessionInfo(_ managed: ManagedLabandSession) -> LabandSessionInfo {
    revokeExpiredLeaseForCatalog(managed)
    return LabandSessionInfo(
      logicalSessionId: managed.logicalSessionId,
      incarnationId: managed.incarnationId,
      childPid: managed.childPid,
      foregroundPid: managed.foregroundPid,
      daemonProcessPid: Int(ProcessInfo.processInfo.processIdentifier),
      cwd: managed.cwd,
      commandDisplayName: managed.commandDisplayName,
      title: managed.title,
      rows: managed.rows,
      cols: managed.cols,
      lifecycleState: managed.lifecycleState,
      attachedClientCount: managed.attachedClientCount(),
      leaseHolder: managed.leaseHolder,
      lease: managed.lease,
      leaseHistory: managed.leaseHistory,
      transportMode: "control-json"
    )
  }

  private func snapshotResponse(_ managed: ManagedLabandSession) -> LabandSnapshotResponse? {
    guard managed.lifecycleState == .running, let session = managed.session,
      let snap = session.snapshot()
    else { return nil }
    defer { laban_snapshot_destroy(snap) }
    let snapshot = snap.pointee
    let title = snapshot.title.map { String(cString: $0) } ?? managed.title
    managed.title = title.isEmpty ? managed.commandDisplayName : title
    managed.rows = Int(snapshot.rows)
    managed.cols = Int(snapshot.cols)
    let visible = TerminalSnapshotText.visibleText(from: UnsafePointer(snap), mode: .fullGrid)
    let cells = snapshotCells(snapshot)
    let state: LabandLifecycleState
    switch snapshot.status {
    case 1, 2:
      state = .exited
      managed.lifecycleState = .exited
    default:
      state = managed.lifecycleState
    }
    return LabandSnapshotResponse(
      logicalSessionId: managed.logicalSessionId,
      incarnationId: managed.incarnationId,
      rows: Int(snapshot.rows),
      cols: Int(snapshot.cols),
      cursorRow: Int(snapshot.cursor_row),
      cursorCol: Int(snapshot.cursor_col),
      cursorVisible: snapshot.cursor_visible != 0,
      title: managed.title,
      lifecycleState: state,
      exitStatus: snapshot.status == 0 ? nil : Int(snapshot.exit_status),
      dirty: snapshot.dirty != 0,
      visibleText: visible,
      cells: cells
    )
  }

  private func ensureSnapshotRing(_ managed: ManagedLabandSession) throws
    -> LabandSnapshotRingWriter
  {
    if let writer = managed.ringWriter {
      return writer
    }
    let maxRows = max(managed.rows, 128)
    let maxCols = max(managed.cols, 512)
    let ringsDir = URL(fileURLWithPath: journalPath).appendingPathComponent(
      "snapshot-rings", isDirectory: true)
    let name =
      "\(hexHash(managed.logicalSessionId))-\(hexHash(managed.incarnationId)).lbndss"
    let path = ringsDir.appendingPathComponent(name).path
    let writer = try LabandSnapshotRingWriter(
      path: path,
      logicalSessionId: managed.logicalSessionId,
      incarnationId: managed.incarnationId,
      maxRows: maxRows,
      maxCols: maxCols
    )
    managed.ringWriter = writer
    return writer
  }

  private func hexHash(_ value: String) -> String {
    String(format: "%016llx", LabandSnapshotRingLayout.stableHash(value))
  }

  private func snapshotCells(_ snapshot: LabanSnapshot) -> [LabandSnapshotCell] {
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard rows > 0, cols > 0, let cells = snapshot.cells else { return [] }
    var output: [LabandSnapshotCell] = []
    output.reserveCapacity(rows * cols)
    for row in 0..<rows {
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        output.append(
          LabandSnapshotCell(
            row: row,
            col: col,
            text: cellText(cell, storage: snapshot.utf8_storage),
            flags: cell.flags,
            foregroundRGBA: cell.foreground_rgba,
            backgroundRGBA: cell.background_rgba
          )
        )
      }
    }
    return output
  }

  private func cellText(_ cell: LabanCell, storage: UnsafePointer<CChar>?) -> String {
    guard cell.utf8_length > 0, let storage else { return "" }
    let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
    let buf = UnsafeBufferPointer<UInt8>(
      start: ptr.assumingMemoryBound(to: UInt8.self),
      count: Int(cell.utf8_length)
    )
    return String(bytes: buf, encoding: .utf8) ?? ""
  }
}

private final class UnixSocketServer {
  private let socketPath: String
  private let daemon: LabandDaemon
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private var listenFD: Int32 = -1
  private let stateLock = NSLock()

  init(socketPath: String, daemon: LabandDaemon) {
    self.socketPath = socketPath
    self.daemon = daemon
    self.encoder.outputFormatting = [.sortedKeys]
  }

  func run() throws {
    listenFD = try bindUnixSocket(path: socketPath)
    while true {
      let fd = Darwin.accept(listenFD, nil, nil)
      if fd < 0 {
        let err = errno
        if currentListenFD() < 0 || err == EBADF || err == EINVAL { break }
        if err == EINTR { continue }
        throw LabandMainError.socketCall("accept", err)
      }
      Thread {
        self.handleClient(fd: fd)
      }.start()
    }
  }

  func stop() {
    let fd = stateLock.withLock { () -> Int32 in
      let old = listenFD
      listenFD = -1
      return old
    }
    if fd >= 0 {
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
    }
  }

  private func currentListenFD() -> Int32 {
    stateLock.withLock { listenFD }
  }

  private func handleClient(fd: Int32) {
    defer { Darwin.close(fd) }
    while true {
      do {
        guard let frame = try readFrame(fd: fd) else { return }
        let request = try decoder.decode(LabandRequest.self, from: frame)
        let (response, shouldShutdown) = daemon.handle(request)
        try writeFrame(fd: fd, payload: encoder.encode(response))
        if shouldShutdown {
          daemon.onShutdown?()
          return
        }
      } catch {
        let fallback = LabandResponse.error(
          requestId: "unknown",
          type: .hello,
          code: "protocolError",
          message: String(describing: error)
        )
        if let payload = try? encoder.encode(fallback) {
          try? writeFrame(fd: fd, payload: payload)
        }
        return
      }
    }
  }

  private func bindUnixSocket(path: String) throws -> Int32 {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    unlink(path)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LabandMainError.socketCall("socket", errno) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= pathCapacity else {
      Darwin.close(fd)
      throw LabandMainError.socketPathTooLong(path)
    }
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      for index in 0..<pathBytes.count {
        ptr.advanced(by: index).pointee = pathBytes[index]
      }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let err = errno
      Darwin.close(fd)
      throw LabandMainError.socketCall("bind", err)
    }
    guard Darwin.listen(fd, 32) == 0 else {
      let err = errno
      Darwin.close(fd)
      throw LabandMainError.socketCall("listen", err)
    }
    return fd
  }

  private func readFrame(fd: Int32) throws -> Data? {
    guard let header = readExact(fd: fd, count: 4) else { return nil }
    let bytes = [UInt8](header)
    let length =
      UInt32(bytes[0])
      | (UInt32(bytes[1]) << 8)
      | (UInt32(bytes[2]) << 16)
      | (UInt32(bytes[3]) << 24)
    guard length > 0 && length <= 16 * 1024 * 1024 else {
      throw LabandMainError.invalidFrameLength(length)
    }
    return readExact(fd: fd, count: Int(length))
  }

  private func writeFrame(fd: Int32, payload: Data) throws {
    var header = Data()
    let length = UInt32(payload.count)
    header.append(UInt8(length & 0xFF))
    header.append(UInt8((length >> 8) & 0xFF))
    header.append(UInt8((length >> 16) & 0xFF))
    header.append(UInt8((length >> 24) & 0xFF))
    try writeAll(fd: fd, data: header)
    try writeAll(fd: fd, data: payload)
  }

  private func readExact(fd: Int32, count: Int) -> Data? {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let n = data.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(fd, base.advanced(by: offset), count - offset)
      }
      if n == 0 { return nil }
      if n < 0 {
        if errno == EINTR { continue }
        return nil
      }
      offset += n
    }
    return data
  }

  private func writeAll(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw LabandMainError.socketCall("write", errno)
      }
      offset += n
    }
  }
}

private final class LabandXPCControlService: NSObject, LabandXPCControlProtocol {
  private let daemon: LabandDaemon
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  init(daemon: LabandDaemon) {
    self.daemon = daemon
    self.encoder.outputFormatting = [.sortedKeys]
  }

  func sendRequest(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
    do {
      let request = try decoder.decode(LabandRequest.self, from: requestData)
      let (response, shouldShutdown) = daemon.handle(request)
      reply(try encoder.encode(response))
      if shouldShutdown {
        daemon.onShutdown?()
      }
    } catch {
      let fallback = LabandResponse.error(
        requestId: "unknown",
        type: .hello,
        code: "protocolError",
        message: String(describing: error)
      )
      reply((try? encoder.encode(fallback)) ?? Data())
    }
  }
}

private final class LabandXPCListener: NSObject, NSXPCListenerDelegate {
  private let listener: NSXPCListener
  private let service: LabandXPCControlService

  init(serviceName: String, daemon: LabandDaemon) {
    self.listener = NSXPCListener(machServiceName: serviceName)
    self.service = LabandXPCControlService(daemon: daemon)
    super.init()
    self.listener.delegate = self
  }

  func resume() {
    listener.resume()
  }

  func invalidate() {
    listener.invalidate()
  }

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: LabandXPCControlProtocol.self)
    connection.exportedObject = service
    connection.resume()
    return true
  }
}

@main
struct LabandMain {
  static func main() {
    signal(SIGPIPE, SIG_IGN)
    do {
      let args = try LabandArguments.parse(CommandLine.arguments)
      try FileManager.default.createDirectory(
        atPath: args.journalPath,
        withIntermediateDirectories: true
      )
      let daemon = try LabandDaemon(journalPath: args.journalPath)
      let xpcListener = args.xpcServiceName.map {
        LabandXPCListener(serviceName: $0, daemon: daemon)
      }
      let server = args.socketPath.map { UnixSocketServer(socketPath: $0, daemon: daemon) }
      daemon.onShutdown = {
        server?.stop()
        xpcListener?.invalidate()
        CFRunLoopStop(CFRunLoopGetMain())
      }
      xpcListener?.resume()
      if let server {
        try server.run()
        if let socketPath = args.socketPath {
          unlink(socketPath)
        }
      } else {
        RunLoop.current.run()
      }
    } catch {
      fputs("laband: \(error)\n", stderr)
      exit(1)
    }
  }
}
