import Foundation
import LabanCore
import LabanTerminalCore

/// The mutable half of a `ManagedLabandSession`. Every field is read and
/// written only through the owning session's lock (`current` / `update`), so a
/// client thread can never observe a torn String, array or reference while
/// another client thread writes it. (laban#44)
struct ManagedLabandSessionState {
  var rows: Int
  var cols: Int
  var lifecycleState: LabandLifecycleState
  var title: String
  var childPid: Int?
  var foregroundPid: Int?
  /// Human-readable foreground-process metadata polled from the daemon-side
  /// libghostty session. Mirrors `Session.ProcessMetadata`. Not persisted to
  /// the journal because it is derived from the live foreground PID and is
  /// cheap to re-derive after replay.
  var foregroundProcess: String?
  var foregroundCommand: String?
  var foregroundArguments: [String]?
  var foregroundCwd: String?
  /// Monotonic timestamp (ns) of the last successful foreground-process poll.
  /// Used to throttle sysctl/proc-table calls — the catalog refresh fires on
  /// every `sessionInfo()` read, but the actual poll happens at most once per
  /// `foregroundProcessPollIntervalNs`.
  var lastForegroundProcessPollMonoNs: UInt64 = 0
  var session: Session?
  var runner: SessionRunner?
  var ringWriter: LabandSnapshotRingWriter?
  var lease: LabandLeaseInfo?
  var leaseHolder: String? { lease?.holderClientId }
  var leaseHistory: [LabandLeaseHistoryEntry]
  /// Bumped by every recorded resize, so a snapshot taken before a resize
  /// can tell that its size is stale.
  var resizeGeneration: UInt64 = 0

  var liveSession: Session? { lifecycleState == .running ? session : nil }
}

/// Each socket client runs `LabandDaemon.handle` on its own thread, so a
/// session's mutable state is shared across threads and guarded by `lock`.
///
/// Lock order: `LabandDaemon.lock` may be held while taking a session's lock
/// (`listSessions`, the `createSession` id reservation), never the reverse.
/// The session lock is a leaf: code holding it never takes the daemon lock,
/// another session's lock, or the journal lock, and never blocks (it does not
/// stop a runner, poll the PTY, or touch files). Read with `current` (a
/// consistent copy) and write with `update`, which applies a multi-field
/// change atomically. `ringCreationLock` and `resizeLock` only serialize
/// snapshot-ring creation and resizes; each is taken before the session lock,
/// never while holding it, and never together.
final class ManagedLabandSession {
  private let lock = NSLock()
  private let ringCreationLock = NSLock()
  private let resizeLock = NSLock()
  let logicalSessionId: String
  let incarnationId: String
  let commandDisplayName: String
  let cwd: String
  private var state: ManagedLabandSessionState
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
    self.state = ManagedLabandSessionState(
      rows: rows,
      cols: cols,
      lifecycleState: lifecycleState,
      title: title,
      childPid: childPid,
      foregroundPid: foregroundPid,
      session: session,
      lease: lease,
      leaseHistory: leaseHistory
    )
  }

  /// A consistent copy of the mutable state, taken under the session lock.
  var current: ManagedLabandSessionState {
    lock.withLock { state }
  }

  /// The PTY session when the session is running, else nil.
  var liveSession: Session? {
    lock.withLock { state.liveSession }
  }

  var isLive: Bool { liveSession != nil }

  /// Apply a change to the mutable state atomically. `body` runs under the
  /// session lock, so it must not block or take any other lock.
  @discardableResult
  func update<T>(_ body: (inout ManagedLabandSessionState) throws -> T) rethrows -> T {
    try lock.withLock { try body(&state) }
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

  /// Return the session's snapshot-ring writer, creating it with `make` the
  /// first time. Returns nil when the session is not running, both before
  /// and after creation, so a terminate racing an attach cannot leave a new
  /// writer on a terminated session.
  ///
  /// `make` creates, truncates and maps the ring file, so it runs outside the
  /// session lock and a runner publishing a snapshot never waits on that
  /// file I/O. `ringCreationLock` keeps two attaches from each creating a
  /// writer: both would open the same path, and the second would truncate
  /// the ring the first had already handed out.
  func snapshotRingWriter(
    make: (_ rows: Int, _ cols: Int) throws -> LabandSnapshotRingWriter
  ) rethrows -> LabandSnapshotRingWriter? {
    try ringCreationLock.withLock {
      let existing = current
      guard existing.liveSession != nil else { return nil }
      if let writer = existing.ringWriter { return writer }
      let writer = try make(existing.rows, existing.cols)
      return lock.withLock { () -> LabandSnapshotRingWriter? in
        guard state.liveSession != nil else { return nil }
        state.ringWriter = writer
        return writer
      }
    }
  }

  /// A lease this session handed out, with what it replaced, so a grant whose
  /// journal append fails can be rolled back.
  struct LeaseGrant {
    let lease: LabandLeaseInfo
    let priorLease: LabandLeaseInfo?
  }

  /// Grant a fresh lease to `holder`, one epoch past the previous lease.
  func grantLease(to holder: String, now: UInt64, timeoutNs: UInt64) -> LeaseGrant {
    update { state in
      let previousEpoch =
        state.lease?.epoch ?? state.leaseHistory.compactMap(\.epoch).max() ?? 0
      let lease = LabandLeaseInfo(
        leaseId: UUID().uuidString,
        sessionId: logicalSessionId,
        holderClientId: holder,
        epoch: previousEpoch + 1,
        grantedAtMonoNs: now,
        expiresAtMonoNs: now + timeoutNs
      )
      let grant = LeaseGrant(lease: lease, priorLease: state.lease)
      state.lease = lease
      state.leaseHistory.append(
        LabandLeaseHistoryEntry(
          leaseHolder: holder,
          grantedAtMonoNs: lease.grantedAtMonoNs,
          leaseId: lease.leaseId,
          epoch: lease.epoch,
          expiresAtMonoNs: lease.expiresAtMonoNs
        ))
      return grant
    }
  }

  /// Undo a grant whose journal append failed. The grant's history entry is
  /// dropped either way, but the prior lease comes back only while this
  /// grant is still the current lease: another client may have been granted
  /// the lease since, and that newer grant must stand.
  func rollBackLeaseGrant(_ grant: LeaseGrant) {
    update { state in
      if state.lease?.leaseId == grant.lease.leaseId {
        state.lease = grant.priorLease
      }
      state.leaseHistory.removeAll { $0.leaseId == grant.lease.leaseId }
    }
  }

  /// Resize the PTY with `apply` and record the new size, one resize at a
  /// time, so the recorded size is the one the PTY ended up with even when
  /// resizes from several connections overlap. `apply` returns whether the
  /// PTY accepted the size; it runs outside the session lock.
  func resize(rows: Int, cols: Int, apply: () -> Bool) -> Bool {
    resizeLock.withLock {
      guard apply() else { return false }
      recordResize(rows: rows, cols: cols)
      return true
    }
  }

  /// Record the size a resize applied to the PTY.
  func recordResize(rows: Int, cols: Int) {
    update { state in
      state.rows = rows
      state.cols = cols
      state.resizeGeneration &+= 1
    }
  }

  /// Record what a snapshot showed. `resizeGeneration` is the session's
  /// generation read before the snapshot was taken; when a resize has been
  /// recorded since, the snapshot's size is older than the recorded one and
  /// is ignored. Returns the recorded title and lifecycle state.
  func recordSnapshot(
    title snapshotTitle: String?,
    rows: Int,
    cols: Int,
    childExited: Bool,
    resizeGeneration: UInt64
  ) -> (title: String, lifecycleState: LabandLifecycleState) {
    update { state in
      let title = snapshotTitle ?? state.title
      state.title = title.isEmpty ? commandDisplayName : title
      if resizeGeneration == state.resizeGeneration {
        state.rows = rows
        state.cols = cols
      }
      if childExited {
        state.lifecycleState = .exited
      }
      return (state.title, state.lifecycleState)
    }
  }

  /// Clear the lease when `shouldRevoke` accepts it; returns whether it did.
  func revokeLease(where shouldRevoke: (LabandLeaseInfo) -> Bool) -> Bool {
    update { state in
      guard let lease = state.lease, shouldRevoke(lease) else { return false }
      state.lease = nil
      return true
    }
  }

  func publishSnapshot(ptyDrainMonoNs: UInt64 = LabandSnapshotRingLayout.monotonicNanoseconds()) {
    let (ringWriter, session) = lock.withLock { (state.ringWriter, state.liveSession) }
    guard let ringWriter, let session, let snapshot = session.snapshot()
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
