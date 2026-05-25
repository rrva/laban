import Darwin
import Foundation
import LabanCore
import LabanTerminalCore

private enum LabandMainError: Error, CustomStringConvertible {
  case missingValue(String)
  case missingSocket
  case missingJournal
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
  var socketPath: String
  var journalPath: String

  static func parse(_ args: [String]) throws -> LabandArguments {
    var socketPath: String?
    var journalPath: String?
    var index = 1
    while index < args.count {
      let arg = args[index]
      switch arg {
      case "--socket":
        index += 1
        guard index < args.count else { throw LabandMainError.missingValue(arg) }
        socketPath = args[index]
      case "--journal":
        index += 1
        guard index < args.count else { throw LabandMainError.missingValue(arg) }
        journalPath = args[index]
      case "--help", "-h":
        print("usage: laband --socket .tmp/<run-id>/laband.sock --journal .artifacts/runs/<run-id>/laband")
        exit(0)
      default:
        fputs("laband: unknown argument \(arg)\n", stderr)
        exit(2)
      }
      index += 1
    }
    guard let socketPath else { throw LabandMainError.missingSocket }
    guard let journalPath else { throw LabandMainError.missingJournal }
    return LabandArguments(socketPath: socketPath, journalPath: journalPath)
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

private final class ManagedLabandSession {
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

  init(
    logicalSessionId: String,
    incarnationId: String,
    commandDisplayName: String,
    cwd: String,
    rows: Int,
    cols: Int,
    title: String,
    session: Session
  ) {
    self.logicalSessionId = logicalSessionId
    self.incarnationId = incarnationId
    self.commandDisplayName = commandDisplayName
    self.cwd = cwd
    self.rows = rows
    self.cols = cols
    self.title = title
    self.session = session
  }
}

private final class LabandDaemon {
  private let lock = NSLock()
  private var sessions: [String: ManagedLabandSession] = [:]
  var onShutdown: (() -> Void)?

  func handle(_ request: LabandRequest) -> (LabandResponse, Bool) {
    guard request.protocolVersion == LabandProtocolVersion.current else {
      return (
        .error(
          requestId: request.requestId,
          type: request.type,
          code: "protocolVersionUnsupported",
          message: "protocolVersion \(request.protocolVersion) is not supported"
        ),
        false
      )
    }

    switch request.type {
    case .hello:
      return (hello(request), false)
    case .createSession:
      return (createSession(request), false)
    case .listSessions:
      return (listSessions(request), false)
    case .writeInput:
      return (writeInput(request), false)
    case .snapshot:
      return (snapshot(request), false)
    case .resizeSession:
      return (resizeSession(request), false)
    case .markRendered:
      return (markRendered(request), false)
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
        buildVersion: "dev",
        capabilities: [
          "control-json/v1",
          "copy-snapshot/v1",
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
      managed.runner = session.makeRunner(onDirty: {})
      managed.runner?.start()
      refreshProcessMetadata(managed)
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
    managed.runner?.stop()
    managed.runner = nil
    managed.session?.close()
    managed.session = nil
    managed.lifecycleState = .terminated
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

  private func sessionInfo(_ managed: ManagedLabandSession) -> LabandSessionInfo {
    LabandSessionInfo(
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
      attachedClientCount: 0,
      leaseHolder: nil,
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
    daemon.onShutdown = { [weak self] in self?.stop() }
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
    let length = UInt32(bytes[0])
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
      let daemon = LabandDaemon()
      let server = UnixSocketServer(socketPath: args.socketPath, daemon: daemon)
      try server.run()
      unlink(args.socketPath)
    } catch {
      fputs("laband: \(error)\n", stderr)
      exit(1)
    }
  }
}
