import Foundation
import LabanTerminalCore

public final class InProcessTerminalSessionClient: TerminalSessionClient {
  private final class ManagedSession {
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
      session: Session
    ) {
      self.logicalSessionId = logicalSessionId
      self.incarnationId = incarnationId
      self.commandDisplayName = commandDisplayName
      self.cwd = cwd
      self.rows = rows
      self.cols = cols
      self.title = commandDisplayName
      self.session = session
    }
  }

  public let transportMode = "in-process"
  private let lock = NSLock()
  private var sessions: [String: ManagedSession] = [:]

  public init() {}

  deinit {
    lock.withLock {
      for managed in sessions.values {
        managed.runner?.stop()
        managed.session?.close()
      }
      sessions.removeAll()
    }
  }

  @discardableResult
  public func createSession(_ request: TerminalSessionLaunchRequest) throws -> LabandSessionInfo {
    let rows = max(1, request.rows)
    let cols = max(1, request.cols)
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

    var size = LabanTerminalSize()
    size.rows = Int32(rows)
    size.cols = Int32(cols)
    let session: Session
    do {
      session = try Session.realShell(
        size: size,
        cwd: cwd,
        environment: request.environmentPatch,
        launchArgv: launchArgv
      )
    } catch {
      throw TerminalSessionClientError.createFailed(String(describing: error))
    }

    let logicalSessionId =
      request.logicalSessionId?.isEmpty == false ? request.logicalSessionId! : session.id
    let managed = ManagedSession(
      logicalSessionId: logicalSessionId,
      incarnationId: UUID().uuidString,
      commandDisplayName: commandDisplayName,
      cwd: cwd,
      rows: rows,
      cols: cols,
      session: session
    )
    managed.runner = session.makeRunner(onDirty: {})
    managed.runner?.start()
    refreshProcessMetadata(managed)
    lock.withLock {
      sessions[logicalSessionId] = managed
    }
    return sessionInfo(managed)
  }

  public func listSessions() throws -> [LabandSessionInfo] {
    lock.withLock {
      sessions.values.sorted { $0.logicalSessionId < $1.logicalSessionId }.map { managed in
        refreshProcessMetadata(managed)
        return sessionInfo(managed)
      }
    }
  }

  public func writeInput(sessionId: String, bytes: [UInt8]) throws {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    guard managed.lifecycleState == .running, let session = managed.session else {
      throw TerminalSessionClientError.sessionNotRunning(sessionId)
    }
    guard bytes.isEmpty || session.write(bytes) >= 0 else {
      throw TerminalSessionClientError.writeFailed(sessionId)
    }
  }

  public func resize(sessionId: String, rows: Int, cols: Int) throws -> LabandSessionInfo {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    guard managed.lifecycleState == .running, let session = managed.session else {
      throw TerminalSessionClientError.sessionNotRunning(sessionId)
    }
    var size = LabanTerminalSize()
    size.rows = Int32(max(1, rows))
    size.cols = Int32(max(1, cols))
    guard session.resize(size) == 0 else {
      throw TerminalSessionClientError.resizeFailed(sessionId)
    }
    managed.rows = Int(size.rows)
    managed.cols = Int(size.cols)
    return sessionInfo(managed)
  }

  public func snapshot(sessionId: String) throws -> LabandSnapshotResponse {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    guard managed.lifecycleState == .running, let session = managed.session,
      let pointer = session.snapshot()
    else {
      throw TerminalSessionClientError.snapshotFailed(sessionId)
    }
    defer { laban_snapshot_destroy(pointer) }
    let snapshot = LabandSnapshotResponse.copying(
      logicalSessionId: managed.logicalSessionId,
      incarnationId: managed.incarnationId,
      snapshot: UnsafePointer(pointer),
      lifecycleState: managed.lifecycleState
    )
    managed.title = snapshot.title.isEmpty ? managed.commandDisplayName : snapshot.title
    managed.rows = snapshot.rows
    managed.cols = snapshot.cols
    managed.lifecycleState = snapshot.lifecycleState
    return snapshot
  }

  public func markRendered(sessionId: String) throws {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    _ = managed.session?.markRendered()
  }

  public func terminate(sessionId: String) throws -> LabandSessionInfo {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    refreshProcessMetadata(managed)
    managed.runner?.stop()
    managed.runner = nil
    managed.session?.close()
    managed.session = nil
    managed.lifecycleState = .terminated
    return sessionInfo(managed)
  }

  private func lookup(_ sessionId: String) -> ManagedSession? {
    lock.withLock { sessions[sessionId] }
  }

  private func refreshProcessMetadata(_ managed: ManagedSession) {
    guard managed.lifecycleState == .running, let metadata = managed.session?.processMetadata()
    else { return }
    managed.childPid = metadata.childPid
    managed.foregroundPid = metadata.foregroundPid
  }

  private func sessionInfo(_ managed: ManagedSession) -> LabandSessionInfo {
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
      transportMode: transportMode
    )
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
