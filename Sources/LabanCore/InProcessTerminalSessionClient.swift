import Foundation
import LabanTerminalCore

public final class InProcessTerminalSessionClient: TerminalSessionClient {
  /// One session's catalog entry. Calls on this client may come from any
  /// thread, so the mutable fields live in `State` and are only read through
  /// `current` (a consistent copy) and written through `update`, both under
  /// the session's lock — the same discipline laband applies. The session
  /// lock is a leaf: nothing that blocks (stopping the runner, PTY calls)
  /// runs under it. `resizeLock` serializes resizes and is taken before the
  /// session lock, never while holding it.
  private final class ManagedSession {
    struct State {
      var rows: Int
      var cols: Int
      var lifecycleState: LabandLifecycleState = .running
      var title: String
      var childPid: Int?
      var foregroundPid: Int?
      var session: Session?
      var runner: SessionRunner?
      var leaseHolder: String?
      var leaseHistory: [LabandLeaseHistoryEntry] = []
      /// Bumped by every recorded resize, so a snapshot taken before a
      /// resize can tell that its size is stale.
      var resizeGeneration: UInt64 = 0

      var liveSession: Session? { lifecycleState == .running ? session : nil }
    }

    let logicalSessionId: String
    let incarnationId: String
    let commandDisplayName: String
    let cwd: String
    private let lock = NSLock()
    private let resizeLock = NSLock()
    private var state: State

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
      self.state = State(rows: rows, cols: cols, title: commandDisplayName, session: session)
    }

    var current: State { lock.withLock { state } }

    var liveSession: Session? { lock.withLock { state.liveSession } }

    @discardableResult
    func update<T>(_ body: (inout State) throws -> T) rethrows -> T {
      try lock.withLock { try body(&state) }
    }

    /// Resize the PTY with `apply` and record the size, one resize at a time.
    func resize(rows: Int, cols: Int, apply: () -> Bool) -> Bool {
      resizeLock.withLock {
        guard apply() else { return false }
        update { state in
          state.rows = rows
          state.cols = cols
          state.resizeGeneration &+= 1
        }
        return true
      }
    }
  }

  public let transportMode = "in-process"
  private let lock = NSLock()
  private var sessions: [String: ManagedSession] = [:]

  public init() {}

  deinit {
    lock.withLock {
      for managed in sessions.values {
        let state = managed.current
        state.runner?.stop()
        state.session?.close()
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
    let runner = session.makeRunner(onDirty: {})
    managed.update { $0.runner = runner }
    runner?.start()
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

  public func attachSession(logicalSessionId: String) throws -> LabandSessionInfo {
    guard let managed = lookup(logicalSessionId) else {
      throw TerminalSessionClientError.sessionNotFound(logicalSessionId)
    }
    return sessionInfo(managed)
  }

  public func detachSession(sessionId: String) throws -> LabandSessionInfo {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    return sessionInfo(managed)
  }

  public func writeInput(sessionId: String, bytes: [UInt8]) throws {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    guard let session = managed.liveSession else {
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
    guard let session = managed.liveSession else {
      throw TerminalSessionClientError.sessionNotRunning(sessionId)
    }
    var size = LabanTerminalSize()
    size.rows = Int32(max(1, rows))
    size.cols = Int32(max(1, cols))
    guard
      managed.resize(
        rows: Int(size.rows), cols: Int(size.cols), apply: { session.resize(size) == 0 })
    else {
      throw TerminalSessionClientError.resizeFailed(sessionId)
    }
    return sessionInfo(managed)
  }

  public func attachSnapshotRing(sessionId: String) throws -> LabandSnapshotRingAttachment {
    throw TerminalSessionClientError.protocolError(
      "snapshot rings are only available for laband sessions")
  }

  public func snapshot(sessionId: String) throws -> LabandSnapshotResponse {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    // Read the resize generation before taking the snapshot: a resize that
    // lands in between makes this snapshot's size stale.
    let before = managed.current
    guard let session = before.liveSession, let pointer = session.snapshot() else {
      throw TerminalSessionClientError.snapshotFailed(sessionId)
    }
    defer { laban_snapshot_destroy(pointer) }
    let snapshot = LabandSnapshotResponse.copying(
      logicalSessionId: managed.logicalSessionId,
      incarnationId: managed.incarnationId,
      snapshot: UnsafePointer(pointer),
      lifecycleState: before.lifecycleState
    )
    managed.update { state in
      state.title = snapshot.title.isEmpty ? managed.commandDisplayName : snapshot.title
      if state.resizeGeneration == before.resizeGeneration {
        state.rows = snapshot.rows
        state.cols = snapshot.cols
      }
      state.lifecycleState = snapshot.lifecycleState
    }
    return snapshot
  }

  public func scrollViewport(sessionId: String, deltaRows: Int) throws -> LabandSessionInfo {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    guard let session = managed.liveSession else {
      throw TerminalSessionClientError.sessionNotRunning(sessionId)
    }
    guard session.scrollViewport(deltaRows: deltaRows) == 0 else {
      throw TerminalSessionClientError.protocolError("scrollViewport failed for \(sessionId)")
    }
    return sessionInfo(managed)
  }

  public func markRendered(sessionId: String) throws {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    _ = managed.current.session?.markRendered()
  }

  public func transferLease(sessionId: String, holderClientId: String) throws -> LabandSessionInfo {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    let grantedAtMonoNs = DispatchTime.now().uptimeNanoseconds
    managed.update { state in
      state.leaseHolder = holderClientId
      state.leaseHistory.append(
        LabandLeaseHistoryEntry(leaseHolder: holderClientId, grantedAtMonoNs: grantedAtMonoNs))
    }
    return sessionInfo(managed)
  }

  public func terminate(sessionId: String) throws -> LabandSessionInfo {
    guard let managed = lookup(sessionId) else {
      throw TerminalSessionClientError.sessionNotFound(sessionId)
    }
    refreshProcessMetadata(managed)
    let (runner, session) = managed.update { state in
      let detached = (state.runner, state.session)
      state.runner = nil
      state.session = nil
      state.lifecycleState = .terminated
      return detached
    }
    runner?.stop()
    session?.close()
    return sessionInfo(managed)
  }

  private func lookup(_ sessionId: String) -> ManagedSession? {
    lock.withLock { sessions[sessionId] }
  }

  private func refreshProcessMetadata(_ managed: ManagedSession) {
    guard let metadata = managed.liveSession?.processMetadata() else { return }
    managed.update { state in
      state.childPid = metadata.childPid
      state.foregroundPid = metadata.foregroundPid
    }
  }

  private func sessionInfo(_ managed: ManagedSession) -> LabandSessionInfo {
    let state = managed.current
    return LabandSessionInfo(
      logicalSessionId: managed.logicalSessionId,
      incarnationId: managed.incarnationId,
      childPid: state.childPid,
      foregroundPid: state.foregroundPid,
      daemonProcessPid: Int(ProcessInfo.processInfo.processIdentifier),
      cwd: managed.cwd,
      commandDisplayName: managed.commandDisplayName,
      title: state.title,
      rows: state.rows,
      cols: state.cols,
      lifecycleState: state.lifecycleState,
      attachedClientCount: 0,
      leaseHolder: state.leaseHolder,
      leaseHistory: state.leaseHistory,
      transportMode: transportMode
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
