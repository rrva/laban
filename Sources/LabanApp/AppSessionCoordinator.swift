import Darwin
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import os

struct OptionalSnapshotIncarnationTracker {
  private var expectedBySessionId: [String: String] = [:]

  mutating func prepare(sessionId: String, expectedIncarnationId: String) -> Bool {
    let previous = expectedBySessionId.updateValue(expectedIncarnationId, forKey: sessionId)
    return previous != nil && previous != expectedIncarnationId
  }

  mutating func forget(sessionId: String) {
    expectedBySessionId.removeValue(forKey: sessionId)
  }

  mutating func removeAll() {
    expectedBySessionId.removeAll()
  }
}

struct OptionalSnapshotFailurePolicy {
  static func shouldRetireClient(after error: Error) -> Bool {
    guard let sessionError = error as? TerminalSessionClientError else {
      // POSIX socket timeouts/disconnects and decode failures leave stream
      // framing untrustworthy, so the next bounded attempt must reconnect.
      return true
    }
    switch sessionError {
    case .sessionNotFound, .sessionNotRunning, .snapshotFailed, .leaseLost:
      return false
    case .createFailed, .writeFailed, .resizeFailed, .protocolError:
      return true
    }
  }
}

/// Queue-confined, reconnecting transport for optional background snapshots.
/// It deliberately owns a client separate from the interactive/render client,
/// so a stuck socket read cannot hold any lock used by AppKit's main thread.
private final class OptionalLabandSnapshotTransport: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.laban.laband.optional-snapshot",
    qos: .userInitiated)
  private let makeClient: () throws -> LabandTerminalSessionClient
  private var client: LabandTerminalSessionClient?
  private var incarnationTracker = OptionalSnapshotIncarnationTracker()
  private var closed = false

  init(makeClient: @escaping () throws -> LabandTerminalSessionClient) {
    self.makeClient = makeClient
  }

  func snapshotFrame(
    sessionId: String,
    expectedIncarnationId: String,
    completion: @escaping (Result<LabandSnapshotFrame, Error>) -> Void
  ) {
    queue.async { [self] in
      let result: Result<LabandSnapshotFrame, Error>
      do {
        guard !closed else {
          throw TerminalSessionClientError.snapshotFailed(sessionId)
        }
        if incarnationTracker.prepare(
          sessionId: sessionId,
          expectedIncarnationId: expectedIncarnationId)
        {
          // The daemon recreated this logical session. Its previous mmap stays
          // readable after unlink, so it must be discarded before consulting
          // snapshotFrame or the old incarnation can be served forever.
          client?.discardLocalSnapshotAttachment(sessionId: sessionId)
        }
        let client: LabandTerminalSessionClient
        if let existing = self.client {
          client = existing
        } else {
          let connected = try makeClient()
          self.client = connected
          client = connected
        }
        var frame = try client.snapshotFrame(sessionId: sessionId)
        if frame.snapshot.incarnationId != expectedIncarnationId {
          // Defend against an incarnation change racing the mapping update.
          // Reattach once; a second mismatch is not safe to publish.
          client.discardLocalSnapshotAttachment(sessionId: sessionId)
          frame = try client.snapshotFrame(sessionId: sessionId)
        }
        guard frame.snapshot.incarnationId == expectedIncarnationId else {
          throw TerminalSessionClientError.snapshotFailed(sessionId)
        }
        result = .success(frame)
      } catch {
        if OptionalSnapshotFailurePolicy.shouldRetireClient(after: error) {
          // A failed connection is not permanent. Retire it on this background
          // queue so the next bounded retry creates a fresh independent socket.
          let failedClient = client
          client = nil
          failedClient?.closeAfterTransportFailure()
        } else {
          // Session termination/reincarnation is local to this logical ID.
          // Keep unrelated mapped readers and the shared optional socket warm.
          client?.discardLocalSnapshotAttachment(sessionId: sessionId)
        }
        result = .failure(error)
      }
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  /// The primary client has successfully terminated the daemon session, which
  /// also removed every daemon-side attachment. Release this client's local
  /// mmap/reader without issuing a now-invalid detach RPC.
  func discardTerminatedSession(_ sessionId: String) {
    queue.async { [self] in
      incarnationTracker.forget(sessionId: sessionId)
      client?.discardLocalSnapshotAttachment(sessionId: sessionId)
    }
  }

  func detachSession(_ sessionId: String) {
    queue.async { [self] in
      incarnationTracker.forget(sessionId: sessionId)
      guard let client else { return }
      do {
        _ = try client.detachSession(sessionId: sessionId)
      } catch {
        AppLog.app.error(
          "optional snapshot detach failed for \(sessionId): \(String(describing: error))")
      }
    }
  }

  func close() {
    queue.async { [self] in
      guard !closed else { return }
      closed = true
      let client = self.client
      self.client = nil
      incarnationTracker.removeAll()
      client?.close()
    }
  }
}

final class AppSessionCoordinator {
  private let mode: TerminalSessionBackend
  private let labandClient: LabandTerminalSessionClient?
  private let optionalSnapshotTransport: OptionalLabandSnapshotTransport?
  private let labptyClient: LabptyTerminalSessionClient?
  /// Resolved at spawn time so the shell-integration overlay can self-heal
  /// (reinstall) if its per-process temp directory was deleted while the
  /// app kept running. Wraps `ShellIntegrationOverlayProvider.currentLaunch`.
  private let shellLaunchProvider: () -> ShellIntegrationLaunch
  private let cwdBySessionId: [Tab.ID: String]
  private var launchCwdOverrideBySessionId: [Tab.ID: String] = [:]
  private let supportsThemeApplication: Bool
  private let supportsViewportScroll: Bool
  private let snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability
  private var lastSentSizeBySession: [Session.ID: LabanTerminalSize] = [:]
  private var infoBySessionId: [Tab.ID: LabandSessionInfo] = [:]
  private var labptyDescriptorBySessionId: [Tab.ID: LabptySessionDescriptor] = [:]
  private var labptyFeedBySessionId: [Tab.ID: LabptyParserFeed] = [:]
  private let labptyWakeQueue = DispatchQueue(
    label: "com.laban.labpty.output-wake",
    qos: .userInteractive)
  private var labptyWakeSource: DispatchSourceRead?
  private var labptyWakeFD: Int32 = -1
  private var labptyWakeAttempted = false
  private var labptyWakeAvailable = false
  private var labptyActiveDrainSource: DispatchSourceTimer?
  private var labptyWakeLastOutputNs = DispatchTime.now().uptimeNanoseconds
  private let labptyStateLock = NSLock()
  private var labptyDegradation = LabptyOutputDegradation(
    cooldown: AppSessionCoordinator.labptyOutputDegradedCooldown)
  private var labptyRecoveryNotedSessionIds: Set<Tab.ID> = []
  private var ownedProcess: Process?
  private var themeChangeObserver: NSObjectProtocol?
  private var snapshotGenerationMonitor: LabandSnapshotGenerationMonitor?
  private var lastTabMetadataRefreshAt: Date?
  private let processIntrospector = LibprocIntrospector()
  // libproc foreground-process introspection (proc_pidinfo / getcwd / sysctl)
  // is too slow to run synchronously on the main thread every metadata poll,
  // so the walk runs off-main in a detached task and the poll reads the last
  // cached result (keyed by the session's stable child pid). State lives behind
  // an unfair lock so the render-tick read stays synchronous and lock-free of
  // GCD ceremony.
  private struct ProcMetadataState: Sendable {
    var cache: [Int32: Session.ProcessMetadata] = [:]
    var refreshInFlight = false
  }
  private let procMetadata = OSAllocatedUnfairLock(initialState: ProcMetadataState())

  var onSessionDirty: (@Sendable (Session.ID) -> Void)?

  /// Per-tab launch argv override, consulted when building a daemon session
  /// request so a tab created via `AppModel.createTab(runningArgv:)` launches
  /// that command instead of the login shell. Wired to
  /// `AppModel.launchArgv(forTab:)` by `MainWindowController`.
  var argvProvider: ((Tab.ID, Session.ID) -> [String]?)?

  /// Per-tab control env from `SessionLaunchContext`, merged into daemon
  /// spawn requests so labpty/laband inherit `LABAN_CONTROL_URL` (2F/C14).
  var launchEnvironmentProvider: ((Tab.ID, Session.ID) -> [String: String])?

  /// Called after tab metadata refresh so attach PID registration can retry
  /// when daemon `childPid` becomes available.
  var onTabMetadataRefreshed: ((AppModel) -> Void)?

  private static let labptyWakeFallbackPollMilliseconds = 1_000
  private static let labptyActivePollMilliseconds = 8
  // 500 ms, not 50 ms: parking and unparking costs a cross-process RPC to the
  // labpty daemon plus a dispatch-group fan-out over every tab's feed queue
  // plus a fresh kernel timer create on the next wake. A sub-second output
  // cadence (spinners, progress bars) resonates with a 50 ms quiet threshold
  // and drives ~10 park/unpark cycles per second. 500 ms of extra no-op 8 ms
  // polling (~60 cheap polls, made nearly free by the W3 pre-check in
  // pollAllLabptyFeeds) is far cheaper than those RPC/fan-out cycles, and true
  // idle now parks 450 ms later, which is invisible to the user.
  private static let labptyActiveQuietNanoseconds: UInt64 = 500_000_000

  convenience init(
    client: LabandTerminalSessionClient,
    shellLaunch: ShellIntegrationLaunch,
    cwdBySessionId: [Tab.ID: String] = [:],
    labandProcess: Process? = nil
  ) {
    self.init(
      client: client,
      shellLaunchProvider: { shellLaunch },
      cwdBySessionId: cwdBySessionId,
      labandProcess: labandProcess)
  }

  init(
    client: LabandTerminalSessionClient,
    shellLaunchProvider: @escaping () -> ShellIntegrationLaunch,
    cwdBySessionId: [Tab.ID: String] = [:],
    labandProcess: Process? = nil
  ) {
    self.mode = .laband
    self.labandClient = client
    self.optionalSnapshotTransport = OptionalLabandSnapshotTransport {
      try client.makeIndependentClient(ioTimeoutMilliseconds: 1_000)
    }
    self.labptyClient = nil
    self.shellLaunchProvider = shellLaunchProvider
    self.cwdBySessionId = cwdBySessionId
    self.ownedProcess = labandProcess
    let capabilities = (try? client.hello().capabilities) ?? []
    self.supportsThemeApplication = capabilities.contains("theme-palette/v1")
    self.supportsViewportScroll = capabilities.contains("viewport-scroll/v1")
    self.snapshotBackgroundCapability =
      capabilities.contains(LabandCapabilities.snapshotCellExplicitBackgroundV1)
      ? .supported
      : .legacy
    installThemeObserver()
  }

  convenience init(
    labptyClient: LabptyTerminalSessionClient,
    shellLaunch: ShellIntegrationLaunch,
    cwdBySessionId: [Tab.ID: String] = [:],
    labptyProcess: Process? = nil
  ) {
    self.init(
      labptyClient: labptyClient,
      shellLaunchProvider: { shellLaunch },
      cwdBySessionId: cwdBySessionId,
      labptyProcess: labptyProcess)
  }

  init(
    labptyClient: LabptyTerminalSessionClient,
    shellLaunchProvider: @escaping () -> ShellIntegrationLaunch,
    cwdBySessionId: [Tab.ID: String] = [:],
    labptyProcess: Process? = nil
  ) {
    self.mode = .labpty
    self.labandClient = nil
    self.optionalSnapshotTransport = nil
    self.labptyClient = labptyClient
    self.shellLaunchProvider = shellLaunchProvider
    self.cwdBySessionId = cwdBySessionId
    self.ownedProcess = labptyProcess
    self.supportsThemeApplication = false
    self.supportsViewportScroll = false
    self.snapshotBackgroundCapability = .inProcess
  }

  deinit {
    detach()
  }

  var transportMode: String {
    if let labptyClient { return labptyClient.transportMode }
    return labandClient?.transportMode ?? mode.rawValue
  }

  var terminalClient: TerminalSessionClient? {
    labptyClient ?? labandClient
  }

  func setLaunchCwd(_ cwd: String, forSession tabId: Session.ID) {
    launchCwdOverrideBySessionId[tabId] = cwd
  }

  var backend: TerminalSessionBackend { mode }

  var usesRemoteSnapshots: Bool {
    mode == .laband
  }

  /// Capability attached to frames produced through this coordinator. `labpty`
  /// feeds the app's own parser, while laband must negotiate the remote writer.
  var terminalSnapshotBackgroundCapability: TerminalSnapshotBackgroundCapability {
    snapshotBackgroundCapability
  }

  func startSnapshotGenerationMonitor(
    onGenerationAdvance: @escaping LabandSnapshotGenerationMonitor.WakeHandler
  ) {
    guard let labandClient else { return }
    snapshotGenerationMonitor?.stop()
    let monitor = LabandSnapshotGenerationMonitor(
      generationProvider: { [weak labandClient] logicalSessionId in
        labandClient?.snapshotRingGeneration(sessionId: logicalSessionId)
      },
      wakeHandler: onGenerationAdvance)
    snapshotGenerationMonitor = monitor
    for logicalSessionId in Set(infoBySessionId.values.map(\.logicalSessionId)) {
      monitor.track(sessionId: logicalSessionId)
    }
  }

  func stopSnapshotGenerationMonitor() {
    snapshotGenerationMonitor?.stop()
    snapshotGenerationMonitor = nil
  }

  func ensureSessions(for tabs: [Tab], in model: AppModel, size: LabanTerminalSize) throws {
    for tab in tabs.flatMap({ tab in tab.allSessionIds.map { tab.focusing($0) } }) {
      _ = try ensureSession(
        for: tab, session: model.session(forSessionID: tab.focusedSessionId),
        size: usesRemoteSnapshots
          ? model.terminalAreaSize : model.terminalSize(for: tab.focusedSessionId))
    }
  }

  @discardableResult
  func ensureSession(
    for tab: Tab,
    session: Session? = nil,
    size: LabanTerminalSize
  ) throws -> LabandSessionInfo {
    if mode == .labpty {
      return try ensureLabptySession(for: tab, session: session, size: size)
    }
    return try ensureLabandSession(for: tab, size: size)
  }

  func sessionInfo(for tab: Tab) -> LabandSessionInfo? {
    infoBySessionId[tab.focusedSessionId]
  }

  /// Shell leader PID for C14 attach registration on daemon-backed sessions.
  func attachShellPID(forSessionId tabId: Session.ID) -> pid_t? {
    if let info = infoBySessionId[tabId], let childPid = info.childPid, childPid > 0 {
      return pid_t(childPid)
    }
    if let descriptor = labptyDescriptorBySessionId[tabId], descriptor.childPid > 0 {
      return descriptor.childPid
    }
    return nil
  }

  func snapshot(for tab: Tab, size: LabanTerminalSize) throws -> LabandSnapshotResponse {
    try snapshotFrame(for: tab, size: size).snapshot
  }

  func snapshotGeneration(for tab: Tab, size: LabanTerminalSize) throws -> UInt64? {
    guard let labandClient else { return nil }
    let info = try ensureLabandSession(for: tab, size: size)
    return labandClient.snapshotRingGeneration(sessionId: info.logicalSessionId)
  }

  /// Probe only state that is already mapped for an established tab. This
  /// performs no daemon RPC and is therefore suitable for optional previews
  /// in the render loop.
  func snapshotGenerationFromAttachedRing(for tab: Tab) -> UInt64? {
    guard let labandClient, let info = sessionInfo(for: tab) else { return nil }
    return labandClient.snapshotRingGeneration(sessionId: info.logicalSessionId)
  }

  func snapshotFrameFromAttachedRing(for tab: Tab) throws -> LabandSnapshotFrame? {
    guard let labandClient, let info = sessionInfo(for: tab) else { return nil }
    return try labandClient.snapshotFrameFromAttachedRing(sessionId: info.logicalSessionId)
  }

  func snapshotFrame(for tab: Tab, size: LabanTerminalSize) throws -> LabandSnapshotFrame {
    guard let labandClient else {
      throw TerminalSessionClientError.snapshotFailed(tab.id)
    }
    let info = try ensureLabandSession(for: tab, size: size)
    return try labandClient.snapshotFrame(sessionId: info.logicalSessionId)
  }

  /// Resolve the tab/session mapping on the caller (normally main), then do
  /// only the thread-safe laband client read on the background queue. The
  /// completion is always returned on main so view-owned preview state never
  /// crosses queues.
  func snapshotFrameForOptionalPreview(
    for tab: Tab,
    completion: @escaping (Result<LabandSnapshotFrame, Error>) -> Void
  ) throws {
    guard let optionalSnapshotTransport else {
      throw TerminalSessionClientError.snapshotFailed(tab.id)
    }
    guard let info = sessionInfo(for: tab) else {
      throw TerminalSessionClientError.snapshotFailed(tab.id)
    }
    let logicalSessionId = info.logicalSessionId
    optionalSnapshotTransport.snapshotFrame(
      sessionId: logicalSessionId,
      expectedIncarnationId: info.incarnationId,
      completion: completion)
  }

  func write(
    _ bytes: [UInt8],
    to tab: Tab,
    session: Session? = nil,
    size: LabanTerminalSize
  ) throws {
    guard !bytes.isEmpty else { return }
    if let labptyClient {
      let descriptor = try ensureLabptyDescriptor(for: tab, session: session, size: size)
      // Input typed while a large clipboard reply is still going out queues
      // behind it (ADR 0040); the feed loop pumps both in order.
      if let session, session.queueOutputIfPending(bytes) {
        session.captureInput(bytes)
        labptyFeedBySessionId[tab.focusedSessionId]?.wake()
        return
      }
      try labptyClient.writeInput(handle: descriptor.ptyHandle, bytes: bytes)
      // The daemon owns the PTY; the app's viewer session sees output via the
      // byte ring but never these keystrokes. Tee them into the capture sink so
      // an active capture records pty-input alongside pty-output/responses.
      session?.captureInput(bytes)
      return
    }
    guard let labandClient else { return }
    let info = try ensureLabandSession(for: tab, size: size)
    snapshotGenerationMonitor?.boost(sessionId: info.logicalSessionId)
    do {
      try labandClient.writeInput(sessionId: info.logicalSessionId, bytes: bytes)
    } catch TerminalSessionClientError.leaseLost(_, let reason) {
      // The warm cache still says running, so without this the tab would
      // keep rendering output while every keystroke fails on the dead lease.
      AppLog.app.notice(
        "laband lease lost for \(info.logicalSessionId) (\(reason)); re-acquiring")
      let controlled = try reacquireControlLease(for: tab)
      try labandClient.writeInput(sessionId: controlled.logicalSessionId, bytes: bytes)
    }
    session?.captureInput(bytes)
    if let refreshed = try? labandClient.lookupSession(logicalSessionId: info.logicalSessionId) {
      store(refreshed, for: tab)
    }
  }

  func resize(tabs: [Tab], in model: AppModel, size: LabanTerminalSize) {
    resize(
      sizesBySession: Dictionary(
        uniqueKeysWithValues: tabs.flatMap(\.allSessionIds).map {
          ($0, usesRemoteSnapshots ? model.terminalAreaSize : model.terminalSize(for: $0))
        }))
  }

  func resize(sizesBySession: [Session.ID: LabanTerminalSize]) {
    for (id, size) in sizesBySession {
      if let last = lastSentSizeBySession[id], last.cols == size.cols, last.rows == size.rows {
        continue
      }
      do {
        if let client = labptyClient, let descriptor = labptyDescriptorBySessionId[id] {
          let resized = try client.resize(
            handle: descriptor.ptyHandle, rows: Int(size.rows), cols: Int(size.cols))
          labptyDescriptorBySessionId[id] = resized
          infoBySessionId[id] = labptyInfo(from: resized)
        } else if let client = labandClient, infoBySessionId[id] != nil {
          infoBySessionId[id] = try client.resize(
            sessionId: id, rows: Int(size.rows), cols: Int(size.cols))
        } else {
          continue
        }
        lastSentSizeBySession[id] = size
      } catch { AppLog.app.error("session resize failed for \(id): \(String(describing: error))") }
    }
  }

  @discardableResult
  func scrollViewport(tab: Tab, size: LabanTerminalSize, deltaRows: Int) throws -> Bool {
    guard let labandClient, supportsViewportScroll, deltaRows != 0 else { return false }
    let info = try ensureLabandSession(for: tab, size: size)
    let scrolled = try labandClient.scrollViewport(
      sessionId: info.logicalSessionId,
      deltaRows: deltaRows
    )
    store(scrolled, for: tab)
    return true
  }

  func markRendered(tab: Tab) {
    guard let labandClient, let info = sessionInfo(for: tab) else { return }
    try? labandClient.markRendered(sessionId: info.logicalSessionId)
  }

  func terminate(tab: Tab) {
    for id in tab.allSessionIds { terminateSession(tab: tab.focusing(id)) }
  }

  func terminate(sessionId: Session.ID, in tab: Tab) {
    terminateSession(tab: tab.focusing(sessionId))
  }

  private func terminateSession(tab: Tab) {
    var logicalSessionId = sessionInfo(for: tab)?.logicalSessionId
    if let labptyClient {
      if let descriptor = labptyDescriptorBySessionId[tab.focusedSessionId] {
        _ = try? labptyClient.terminate(handle: descriptor.ptyHandle)
      } else if let info = sessionInfo(for: tab) {
        _ = try? labptyClient.terminate(sessionId: info.logicalSessionId)
      }
      stopLabptyFeed(for: tab)
      removeCachedInfo(for: tab)
      return
    }

    guard let labandClient else { return }
    var didTerminate = false
    do {
      let info = try ensureLabandSession(for: tab, size: fallbackSize())
      logicalSessionId = info.logicalSessionId
      let terminated = try labandClient.terminate(sessionId: info.logicalSessionId)
      store(terminated, for: tab)
      didTerminate = true
    } catch {
      AppLog.app.error("laband terminate failed for tab \(tab.id): \(String(describing: error))")
    }
    if let logicalSessionId {
      snapshotGenerationMonitor?.untrack(sessionId: logicalSessionId)
      if didTerminate {
        optionalSnapshotTransport?.discardTerminatedSession(logicalSessionId)
      } else {
        optionalSnapshotTransport?.detachSession(logicalSessionId)
      }
    }
    removeCachedInfo(for: tab)
  }

  func sweepOrphanedSessions() {
    guard mode == .laband else { return }
    let knownIds = Set(infoBySessionId.values.map(\.logicalSessionId))
    guard let client = terminalClient else { return }
    let allSessions: [LabandSessionInfo]
    do {
      allSessions = try client.listSessions()
    } catch {
      AppLog.app.error(
        "session list failed during orphan sweep: \(String(describing: error))")
      return
    }
    for session in allSessions
    where session.lifecycleState == .running && !knownIds.contains(session.logicalSessionId) {
      do {
        _ = try client.terminate(sessionId: session.logicalSessionId)
      } catch {
        AppLog.app.error(
          "orphan sweep failed for \(session.logicalSessionId): \(String(describing: error))"
        )
      }
    }
  }

  /// Live labpty sessions that are not bound to any current tab. labpty
  /// is the upgrade-proof tier, so unlike the laband `sweepOrphanedSessions`
  /// these are not leaks to terminate: a session with no matching tab is
  /// almost always this user's own shell from a launch whose
  /// `workspace.json` was lost or desynced (a Shift-archive wipe, a crash
  /// before save). The policy is detect-and-offer-to-adopt. Returns []
  /// outside labpty mode.
  func unclaimedLabptySessions(knownSessionIds: Set<Tab.ID>) -> [LabptySessionDescriptor] {
    guard mode == .labpty, let labptyClient else { return [] }
    let descriptors: [LabptySessionDescriptor]
    do {
      descriptors = try labptyClient.listLabptySessions()
    } catch {
      AppLog.app.error(
        "labpty listSessions failed during orphan detection: \(String(describing: error))")
      return []
    }
    return descriptors.filter { $0.alive && !knownSessionIds.contains($0.logicalSessionId) }
  }

  /// Reattach each unclaimed labpty session by giving it a restored tab
  /// whose id equals the descriptor's `logicalSessionId`. That id match
  /// makes `ensureLabptyDescriptor` bind to the existing PTY instead of
  /// opening a new one, so no shell is respawned. cwd is recovered from
  /// the live child via libproc for the tab's workspace label; the
  /// persisted launch command is cosmetic because the shell already runs.
  @discardableResult
  func adoptLabptySessions(
    _ descriptors: [LabptySessionDescriptor],
    in model: AppModel,
    size: LabanTerminalSize
  ) -> [Tab] {
    guard mode == .labpty else { return [] }
    var adopted: [Tab] = []
    for descriptor in descriptors {
      let cwd =
        processIntrospector.currentWorkingDirectory(of: pid_t(descriptor.childPid))
        ?? FileManager.default.homeDirectoryForCurrentUser.path
      do {
        let tab = try model.createRestoredTab(
          id: descriptor.logicalSessionId,
          cwd: cwd,
          launchCommand: shellLaunchProvider().argv?.joined(separator: " ") ?? "",
          isActive: false)
        _ = try ensureSession(
          for: tab, session: model.session(forSessionID: tab.focusedSessionId),
          size: usesRemoteSnapshots
            ? model.terminalAreaSize : model.terminalSize(for: tab.focusedSessionId))
        adopted.append(tab)
      } catch {
        AppLog.app.error(
          "labpty adopt failed for \(descriptor.logicalSessionId): \(String(describing: error))")
      }
    }
    return adopted
  }

  /// - Parameter force: bypass the ~4 Hz idle throttle. The reattach path calls
  ///   this once eagerly (see `MainWindowController.makeAndShow`) so the first
  ///   frame paints real per-tab subrows instead of leaving them to a visible
  ///   idle render frame that must win the occlusion/cold-metadata race.
  func refreshTabMetadata(
    for tabs: [Tab], into model: AppModel, now: Date = Date(), force: Bool = false
  ) {
    if !force, let last = lastTabMetadataRefreshAt, now.timeIntervalSince(last) < 0.25 {
      return
    }
    lastTabMetadataRefreshAt = now
    if let labptyClient {
      refreshLabptyTabMetadata(tabs: tabs, model: model, client: labptyClient, now: now)
      onTabMetadataRefreshed?(model)
      return
    }
    guard let labandClient else {
      onTabMetadataRefreshed?(model)
      return
    }
    defer { onTabMetadataRefreshed?(model) }
    let infos: [LabandSessionInfo]
    do {
      infos = try labandClient.listSessions()
    } catch {
      AppLog.app.error(
        "laband listSessions failed during tab metadata refresh: \(String(describing: error))")
      return
    }
    let infoById = Dictionary(uniqueKeysWithValues: infos.map { ($0.logicalSessionId, $0) })
    for tab in tabs.flatMap({ tab in tab.allSessionIds.map { tab.focusing($0) } }) {
      guard let info = infoById[tab.focusedSessionId] else { continue }
      store(info, for: tab)
      let signals = surfaceSignals(from: info)
      _ = model.applySurfaceSignals(
        signals, forTab: tab.id, sessionId: tab.focusedSessionId, now: now)
    }
  }

  func detach() {
    removeThemeChangeObserver()
    stopSnapshotGenerationMonitor()
    cancelLabptyOutputWake()
    cancelLabptyActiveDrain()
    for feed in labptyFeedBySessionId.values {
      feed.stop()
    }
    labptyFeedBySessionId.removeAll()
    labptyClient?.close()
    optionalSnapshotTransport?.close()
    labandClient?.close()
    infoBySessionId.removeAll()
    lastSentSizeBySession.removeAll()
    labptyDescriptorBySessionId.removeAll()
    ownedProcess = nil
  }

  private func installThemeObserver() {
    themeChangeObserver = NotificationCenter.default.addObserver(
      forName: Theme.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.applyCurrentThemeToKnownSessions()
    }
  }

  private func ensureLabandSession(for tab: Tab, size: LabanTerminalSize) throws
    -> LabandSessionInfo
  {
    guard let labandClient else {
      throw TerminalSessionClientError.sessionNotFound(tab.id)
    }
    if let cached = infoBySessionId[tab.focusedSessionId], cached.lifecycleState == .running {
      return cached
    }

    if let existing = try? labandClient.lookupSession(logicalSessionId: tab.focusedSessionId),
      existing.lifecycleState == .running
    {
      let controlled = try ensureControlLease(existing)
      store(controlled, for: tab)
      attachSnapshotRing(for: controlled.logicalSessionId)
      applyCurrentTheme(to: controlled.logicalSessionId)
      return controlled
    }

    let request = launchRequest(for: tab, size: size)
    let created = try labandClient.createSession(request)
    store(created, for: tab)
    attachSnapshotRing(for: created.logicalSessionId)
    applyCurrentTheme(to: created.logicalSessionId)
    return created
  }

  private func ensureLabptySession(
    for tab: Tab,
    session: Session?,
    size: LabanTerminalSize
  ) throws -> LabandSessionInfo {
    let descriptor = try ensureLabptyDescriptor(for: tab, session: session, size: size)
    return labptyInfo(from: descriptor)
  }

  private func ensureLabptyDescriptor(
    for tab: Tab,
    session: Session?,
    size: LabanTerminalSize
  ) throws -> LabptySessionDescriptor {
    if let cached = infoBySessionId[tab.focusedSessionId], cached.lifecycleState == .running,
      let descriptor = labptyDescriptorBySessionId[tab.focusedSessionId]
    {
      if labptyFeedBySessionId[tab.focusedSessionId] == nil, let session {
        // The feed is gone but the session outlived it: a new feed re-reads
        // the byte ring from offset 0, i.e. replays historical output.
        try startLabptyFeed(
          descriptor: descriptor, tab: tab, session: session, isReattach: true)
      }
      return descriptor
    }

    guard let labptyClient else {
      throw TerminalSessionClientError.sessionNotFound(tab.id)
    }
    let existing = try labptyClient.listLabptySessions().first {
      $0.logicalSessionId == tab.focusedSessionId && $0.alive
    }
    let descriptor: LabptySessionDescriptor
    if let existing {
      // Reattaching to a session this process did not open (restart
      // reconnect or an adopted orphan): claim it so the daemon counts
      // this connection in `connectedClients`. openSession auto-attaches
      // its opener, so only the reattach branch needs an explicit claim.
      // Fall back to the listed descriptor if the claim races a teardown.
      descriptor = (try? labptyClient.attachLabptySession(handle: existing.ptyHandle)) ?? existing
    } else {
      descriptor = try labptyClient.openSession(labptyOpenRequest(for: tab, size: size))
    }
    storeLabpty(descriptor, for: tab)
    if let session {
      // A session we claimed (rather than opened) has historical output in
      // its byte ring; the feed's first read replays it.
      try startLabptyFeed(
        descriptor: descriptor, tab: tab, session: session, isReattach: existing != nil)
    }
    return descriptor
  }

  private func startLabptyFeed(
    descriptor: LabptySessionDescriptor,
    tab: Tab,
    session: Session,
    isReattach: Bool
  ) throws {
    if labptyFeedBySessionId[tab.focusedSessionId]?.ptyHandle == descriptor.ptyHandle {
      return
    }
    stopLabptyFeed(for: tab)
    // Replacing the reader must preserve the descriptor used for resize and input.
    storeLabpty(descriptor, for: tab)
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)
    let outputWakeAvailable = ensureLabptyOutputWake()
    let tabId = tab.focusedSessionId
    let feed = LabptyParserFeed(
      ptyHandle: descriptor.ptyHandle,
      reader: reader,
      session: session,
      catchUpGrid: isReattach ? (cols: Int(descriptor.cols), rows: Int(descriptor.rows)) : nil,
      onDirty: { [weak self] sessionId in
        self?.noteLabptyOutputActivity()
        self?.onSessionDirty?(sessionId)
      },
      onOverflow: { [weak self] in
        self?.markLabptyOutputDegraded(for: tabId)
      },
      onResponse: { [weak self] bytes in
        guard let client = self?.labptyClient else { return }
        do {
          try client.writeInput(handle: descriptor.ptyHandle, bytes: bytes)
        } catch {
          AppLog.app.error(
            """
            labpty terminal response write failed for pty handle \
            \(descriptor.ptyHandle): \(error)
            """)
        }
      },
      onQueuedOutput: { [weak self] bytes in
        guard let client = self?.labptyClient else { return false }
        do {
          try client.writeInput(handle: descriptor.ptyHandle, bytes: bytes)
          return true
        } catch {
          // Backpressure: keep the chunk queued and retry on the next pump.
          return false
        }
      })
    labptyFeedBySessionId[tab.focusedSessionId] = feed
    feed.start(
      pollingIntervalMilliseconds: outputWakeAvailable
        ? Self.labptyWakeFallbackPollMilliseconds
        : 4)
    if outputWakeAvailable && labptyActiveDrainSource != nil {
      feed.wake()
    }
  }

  private func stopLabptyFeed(for tab: Tab) {
    labptyFeedBySessionId.removeValue(forKey: tab.focusedSessionId)?.stop()
    labptyDescriptorBySessionId.removeValue(forKey: tab.focusedSessionId)
    clearLabptyOutputDegraded(for: tab.focusedSessionId)
  }

  private func ensureLabptyOutputWake() -> Bool {
    if labptyWakeAvailable { return true }
    if labptyWakeAttempted { return false }
    labptyWakeAttempted = true
    guard let labptyClient else { return false }
    do {
      guard let fd = try labptyClient.openOutputWakeFileDescriptor() else {
        AppLog.app.info("labpty output wake unsupported by daemon; using timer polling")
        return false
      }
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: labptyWakeQueue)
      source.setEventHandler { [weak self] in
        self?.handleLabptyOutputWake(fileDescriptor: fd)
      }
      source.setCancelHandler {
        Darwin.close(fd)
      }
      labptyWakeFD = fd
      labptyWakeSource = source
      labptyWakeAvailable = true
      source.resume()
      return true
    } catch {
      AppLog.app.error("labpty output wake setup failed: \(String(describing: error))")
      return false
    }
  }

  private func cancelLabptyOutputWake(allowRetry: Bool = true) {
    let source = labptyWakeSource
    labptyWakeSource = nil
    labptyWakeFD = -1
    labptyWakeAvailable = false
    labptyWakeAttempted = !allowRetry
    source?.setEventHandler {}
    source?.cancel()
  }

  private func fallbackToLabptyPolling() {
    cancelLabptyActiveDrain()
    cancelLabptyOutputWake(allowRetry: false)
    for feed in labptyFeedBySessionId.values {
      feed.setPollingInterval(milliseconds: 4)
    }
  }

  private func handleLabptyOutputWake(fileDescriptor fd: Int32) {
    var didReceiveWake = false
    var buffer = [UInt8](repeating: 0, count: 256)
    let bufferCount = buffer.count
    while true {
      let n = buffer.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(fd, base, bufferCount)
      }
      if n > 0 {
        didReceiveWake = true
        continue
      }
      if n == 0 {
        markLabptyOutputWakeClosed(fileDescriptor: fd)
        return
      }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { break }
      markLabptyOutputWakeClosed(fileDescriptor: fd)
      return
    }
    guard didReceiveWake else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.labptyWakeFD == fd else { return }
      self.labptyWakeLastOutputNs = DispatchTime.now().uptimeNanoseconds
      self.startLabptyActiveDrain()
      self.pollAllLabptyFeeds()
    }
  }

  private func markLabptyOutputWakeClosed(fileDescriptor fd: Int32) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.labptyWakeFD == fd else { return }
      self.fallbackToLabptyPolling()
    }
  }

  private func noteLabptyOutputActivity() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.labptyWakeLastOutputNs = DispatchTime.now().uptimeNanoseconds
      if self.labptyWakeAvailable {
        self.startLabptyActiveDrain()
      }
    }
  }

  private func startLabptyActiveDrain() {
    guard labptyWakeAvailable else { return }
    guard labptyActiveDrainSource == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(
      deadline: .now(),
      repeating: .milliseconds(Self.labptyActivePollMilliseconds),
      leeway: .milliseconds(2))
    source.setEventHandler { [weak self] in
      self?.labptyActiveDrainTick()
    }
    labptyActiveDrainSource = source
    source.resume()
  }

  private func cancelLabptyActiveDrain() {
    guard let source = labptyActiveDrainSource else { return }
    labptyActiveDrainSource = nil
    source.setEventHandler {}
    source.cancel()
  }

  private func labptyActiveDrainTick() {
    pollAllLabptyFeeds()
    let now = DispatchTime.now().uptimeNanoseconds
    guard now >= labptyWakeLastOutputNs else { return }
    guard now - labptyWakeLastOutputNs >= Self.labptyActiveQuietNanoseconds else { return }
    parkLabptyOutputWakeAfterQuiet()
  }

  private func pollAllLabptyFeeds() {
    // The only call site that uses the cheap pre-check: every other `wake()`
    // caller (daemon wake pipe, unpark response, reconnect) must stay
    // unconditional so a stale offset mirror can only cause a spurious poll,
    // never a missed one (see `wakeIfOutputPending()`'s comment).
    for feed in labptyFeedBySessionId.values {
      feed.wakeIfOutputPending()
    }
  }

  private func parkLabptyOutputWakeAfterQuiet() {
    guard labptyWakeAvailable, let labptyClient else { return }
    cancelLabptyActiveDrain()
    let feeds = Array(labptyFeedBySessionId.values)
    let group = DispatchGroup()
    let entries = OSAllocatedUnfairLock(initialState: [LabptyOutputWakeParkEntry]())
    for feed in feeds {
      group.enter()
      feed.observedWakeParkEntry { entry in
        entries.withLock { state in
          state.append(entry)
        }
        group.leave()
      }
    }
    group.notify(queue: labptyWakeQueue) { [weak self, labptyClient] in
      do {
        let response = try labptyClient.parkOutputWake(entries: entries.withLock { $0 })
        DispatchQueue.main.async {
          self?.handleLabptyOutputWakeParkResponse(response.parked)
        }
      } catch {
        AppLog.app.error("labpty output wake park failed: \(String(describing: error))")
        DispatchQueue.main.async {
          self?.fallbackToLabptyPolling()
        }
      }
    }
  }

  private func handleLabptyOutputWakeParkResponse(_ parked: Bool) {
    guard labptyWakeAvailable else { return }
    if parked { return }
    labptyWakeLastOutputNs = DispatchTime.now().uptimeNanoseconds
    startLabptyActiveDrain()
    pollAllLabptyFeeds()
  }

  private func refreshLabptyTabMetadata(
    tabs: [Tab],
    model: AppModel,
    client: LabptyTerminalSessionClient,
    now: Date
  ) {
    let descriptors: [LabptySessionDescriptor]
    do {
      descriptors = try client.listLabptySessions()
    } catch {
      AppLog.app.error(
        "labpty listSessions failed during tab metadata refresh: \(String(describing: error))")
      return
    }
    // A close_pending labpty session relinquishes its logical id (""), so a
    // burst of HUP-ignoring terminations can surface several identity-less
    // descriptors in one list. The daemon omits them, but key defensively: an
    // empty id matches no tab, and uniquing keeps any duplicate id from
    // trapping the initializer (uniqueKeysWithValues aborts on collision).
    let descriptorById = Dictionary(
      descriptors.lazy.filter { !$0.logicalSessionId.isEmpty }.map { ($0.logicalSessionId, $0) },
      uniquingKeysWith: { current, _ in current })
    Self.noteMissingLabptySessionsIfNeeded(
      tabs: tabs,
      model: model,
      attachedTabIds: Set(labptyDescriptorBySessionId.keys),
      liveLogicalIds: Set(descriptorById.keys),
      notedTabIds: &labptyRecoveryNotedSessionIds)
    // Kick off the off-main libproc walk for the live children so the next
    // poll reads warm metadata instead of blocking the render tick on syscalls.
    refreshProcMetadataCache(forChildPids: descriptors.map { $0.childPid })
    // Drop degraded stamps whose cooldown has fully elapsed so the map cannot
    // accumulate entries for tabs that overflowed once and were never closed.
    labptyStateLock.withLock { labptyDegradation.pruneExpired(now: now) }
    for tab in tabs.flatMap({ tab in tab.allSessionIds.map { tab.focusing($0) } }) {
      guard let descriptor = descriptorById[tab.focusedSessionId] else { continue }
      storeLabpty(descriptor, for: tab)
      // The "output skipped" badge is a live signal that bytes are being dropped
      // right now — and for a short cooldown after the last drop — not a permanent
      // record. An inactive tab therefore retires it on its own once drops stop
      // (recency, via isLabptyOutputDegraded(now:)), and the active (viewed) tab
      // retires it immediately, mirroring how bell/unseen-output attention clears
      // on selection. Before this the latch only dropped on stop/close, so the
      // badge stuck to a live tab forever.
      if tab.isActive {
        clearLabptyOutputDegraded(for: tab.focusedSessionId)
      }
      let degraded = isLabptyOutputDegraded(for: tab.focusedSessionId, now: now)
      let signals = surfaceSignals(
        from: labptyInfo(from: descriptor),
        labptyOutputDegraded: degraded)
      _ = model.applySurfaceSignals(
        signals, forTab: tab.id, sessionId: tab.focusedSessionId, now: now)
      if !degraded {
        // surfaceSignals sends a nil agentStatus when not degraded, and the
        // synchronizer deliberately leaves a nil alone so a metadata poll can
        // never wipe an OSC 21337 status. Clearing a retired degraded badge is
        // therefore explicit, and scoped to the exact badge so it can never
        // touch an OSC status that happens to share titleMetadata.agentStatus.
        _ = model.clearAgentStatus(
          forTab: tab.id, sessionId: tab.focusedSessionId, ifEquals: Self.labptyOutputDegradedStatus
        )
      }
    }
  }

  @discardableResult
  static func noteMissingLabptySessionsIfNeeded(
    tabs: [Tab],
    model: AppModel,
    attachedTabIds: Set<Tab.ID>,
    liveLogicalIds: Set<String>,
    notedTabIds: inout Set<Tab.ID>
  ) -> [Tab.ID] {
    let liveTabIds = Set(tabs.flatMap(\.allSessionIds))
    notedTabIds.formIntersection(liveTabIds)
    notedTabIds.subtract(liveLogicalIds)
    let affected = tabs.flatMap { tab in tab.allSessionIds.map { tab.focusing($0) } }.filter {
      attachedTabIds.contains($0.focusedSessionId) && !liveLogicalIds.contains($0.focusedSessionId)
        && !notedTabIds.contains($0.focusedSessionId)
    }
    guard !affected.isEmpty else { return [] }
    let labels = affected.map(\.title).joined(separator: ", ")
    let plural = affected.count == 1 ? "shell" : "shells"
    let text =
      "Background session daemon restarted; \(plural) lost for \(labels). Restart the affected shell tabs."
    for tab in affected {
      _ = model.postTabNotice(
        forTab: tab.id,
        note: TabStateJournal.daemonRecoveryNote,
        text: text,
        urgent: true)
      notedTabIds.insert(tab.focusedSessionId)
    }
    return affected.map(\.id)
  }

  private func surfaceSignals(
    from info: LabandSessionInfo,
    labptyOutputDegraded: Bool = false
  ) -> TabSurfaceSignals {
    let trimmedTitle = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let titleDirty = !trimmedTitle.isEmpty
    let processMetadata: Session.ProcessMetadata? = {
      guard info.foregroundCommand != nil || info.foregroundProcess != nil else { return nil }
      return Session.ProcessMetadata(
        childPid: info.childPid,
        foregroundPid: info.foregroundPid,
        foregroundProcess: info.foregroundProcess ?? "",
        foregroundCommand: info.foregroundCommand ?? "",
        foregroundArguments: info.foregroundArguments,
        cwd: info.foregroundCwd ?? info.cwd
      )
    }()
    return TabSurfaceSignals(
      processMetadata: processMetadata,
      titleDirty: titleDirty,
      titleRaw: titleDirty ? trimmedTitle : nil,
      exitState: info.lifecycleState == .running ? .running : .exited(code: 0),
      agentStatus: labptyOutputDegraded ? Self.labptyOutputDegradedStatus : nil
    )
  }

  private func labptyInfo(from descriptor: LabptySessionDescriptor) -> LabandSessionInfo {
    // labpty's descriptor only carries childPid; the real foreground
    // process (e.g. the user's current command inside their shell) is
    // resolved by processMetadata via libproc, which walks the child's
    // pgrp tree and picks the right pid.
    let pid = descriptor.childPid
    let metadata = processMetadata(pid: pid, childPid: descriptor.childPid)
    let commandDisplayName =
      metadata.foregroundProcess?.isEmpty == false
      ? metadata.foregroundProcess! : "Background Session"
    return LabandSessionInfo(
      logicalSessionId: descriptor.logicalSessionId,
      incarnationId: String(descriptor.ptyHandle),
      childPid: Int(descriptor.childPid),
      foregroundPid: pid > 0 ? Int(pid) : nil,
      daemonProcessPid: -1,
      cwd: metadata.cwd ?? cwdByLogicalSessionId(descriptor.logicalSessionId),
      commandDisplayName: commandDisplayName,
      title: "",
      rows: Int(descriptor.rows),
      cols: Int(descriptor.cols),
      lifecycleState: descriptor.alive ? .running : .exited,
      attachedClientCount: Int(descriptor.connectedClients),
      leaseHolder: nil,
      transportMode: transportMode,
      foregroundProcess: metadata.foregroundProcess,
      foregroundCommand: metadata.foregroundCommand,
      foregroundArguments: metadata.foregroundArguments,
      foregroundCwd: metadata.cwd)
  }

  private func processMetadata(pid: Int32, childPid: Int32) -> Session.ProcessMetadata {
    guard pid > 0 else {
      return Session.ProcessMetadata(childPid: Int(childPid))
    }
    if let cached = procMetadata.withLock({ $0.cache[childPid] }) {
      return cached
    }
    // Cold miss (first sighting of this child): compute once on the calling
    // thread so a freshly opened tab shows its real process immediately.
    // Steady-state polls are served from the cache, refreshed off-main below.
    let computed = Self.computeProcessMetadata(
      pid: pid, childPid: childPid, introspector: processIntrospector)
    procMetadata.withLock { $0.cache[childPid] = computed }
    return computed
  }

  /// Recompute the libproc metadata for the live child pids off the main
  /// thread, then publish it into the cache. Fire-and-forget: the current poll
  /// uses the previous cycle's cache, so the displayed process/cwd lags real
  /// changes by at most one poll interval. A single refresh runs at a time.
  private func refreshProcMetadataCache(forChildPids childPids: [Int32]) {
    let live = childPids.filter { $0 > 0 }
    guard !live.isEmpty else { return }
    let shouldRun = procMetadata.withLock { state -> Bool in
      if state.refreshInFlight { return false }
      state.refreshInFlight = true
      return true
    }
    guard shouldRun else { return }
    let state = procMetadata
    Task.detached(priority: .utility) {
      let introspector = LibprocIntrospector()
      let computed = Dictionary(
        live.map { childPid in
          (
            childPid,
            Self.computeProcessMetadata(
              pid: childPid, childPid: childPid, introspector: introspector)
          )
        },
        uniquingKeysWith: { current, _ in current })
      state.withLock {
        // Full replace also prunes pids no longer present.
        $0.cache = computed
        $0.refreshInFlight = false
      }
    }
  }

  private static func computeProcessMetadata(
    pid: Int32, childPid: Int32, introspector: LibprocIntrospector
  ) -> Session.ProcessMetadata {
    guard pid > 0 else {
      return Session.ProcessMetadata(childPid: Int(childPid))
    }
    let processPid = pid_t(pid)
    let arguments = introspector.arguments(of: processPid)
    let processName = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
    return Session.ProcessMetadata(
      childPid: Int(childPid),
      foregroundPid: Int(pid),
      foregroundProcess: processName,
      foregroundCommand: arguments.isEmpty ? processName : arguments.joined(separator: " "),
      foregroundArguments: arguments.isEmpty ? nil : arguments,
      cwd: introspector.currentWorkingDirectory(of: processPid)
    )
  }

  private func ensureControlLease(_ info: LabandSessionInfo) throws -> LabandSessionInfo {
    guard let labandClient else { return info }
    guard info.lease?.holderClientId != labandClient.clientIdentifier else { return info }
    return try labandClient.transferLease(
      sessionId: info.logicalSessionId,
      holderClientId: labandClient.clientIdentifier
    )
  }

  private func reacquireControlLease(for tab: Tab) throws -> LabandSessionInfo {
    guard let labandClient else { throw TerminalSessionClientError.sessionNotFound(tab.id) }
    let current = try labandClient.lookupSession(logicalSessionId: tab.focusedSessionId)
    let controlled = try ensureControlLease(current)
    store(controlled, for: tab)
    return controlled
  }

  private func store(_ info: LabandSessionInfo, for tab: Tab) {
    infoBySessionId[tab.focusedSessionId] = info
  }

  private func storeLabpty(_ descriptor: LabptySessionDescriptor, for tab: Tab) {
    labptyDescriptorBySessionId[tab.focusedSessionId] = descriptor
    store(labptyInfo(from: descriptor), for: tab)
  }

  private func removeCachedInfo(for tab: Tab) {
    infoBySessionId.removeValue(forKey: tab.focusedSessionId)
    lastSentSizeBySession.removeValue(forKey: tab.focusedSessionId)
    clearLabptyOutputDegraded(for: tab.focusedSessionId)
  }

  private static let labptyOutputDegradedStatus = TabAgentStatus(
    indicatorColor: "#f59e0b",
    statusText: "output skipped",
    statusTextColor: "#f59e0b")

  /// How long the "output skipped" badge lingers after the last dropped-output
  /// event before it self-clears on an inactive tab. The byte ring reports each
  /// drop as a one-shot edge, so a recency window is what turns those edges into
  /// a steady badge while a burst overruns and lets it fade once drops stop.
  private static let labptyOutputDegradedCooldown: TimeInterval = 4

  private func markLabptyOutputDegraded(for tabId: Tab.ID) {
    // The overflow edge fires on the byte-ring poll thread; stamp wall-clock time
    // here and let the metadata poll compare it against its own `now`. Both use
    // real `Date`, so the recency window is consistent across the two threads.
    labptyStateLock.withLock {
      labptyDegradation.recordSkip(tabId, at: Date())
    }
  }

  private func clearLabptyOutputDegraded(for tabId: Tab.ID) {
    labptyStateLock.withLock {
      labptyDegradation.clear(tabId)
    }
  }

  private func isLabptyOutputDegraded(for tabId: Tab.ID, now: Date) -> Bool {
    labptyStateLock.withLock {
      labptyDegradation.isDegraded(tabId, now: now)
    }
  }

  private func attachSnapshotRing(for logicalSessionId: String) {
    guard let labandClient else { return }
    _ = try? labandClient.attachSnapshotRing(sessionId: logicalSessionId)
    snapshotGenerationMonitor?.track(sessionId: logicalSessionId)
  }

  private func applyCurrentThemeToKnownSessions() {
    let logicalSessionIds = Set(infoBySessionId.values.map(\.logicalSessionId))
    for logicalSessionId in logicalSessionIds {
      applyCurrentTheme(to: logicalSessionId)
    }
  }

  private func applyCurrentTheme(to logicalSessionId: String) {
    guard let labandClient, supportsThemeApplication else { return }
    let theme = Theme.current
    let colorScheme: TerminalColorScheme = theme.isDark ? .dark : .light
    do {
      try labandClient.applyTheme(
        sessionId: logicalSessionId,
        paletteBytes: ThemePaletteInjector.paletteBytes(for: theme),
        colorScheme: colorScheme)
    } catch {
      AppLog.app.error(
        "laband theme apply failed for \(logicalSessionId): \(String(describing: error))")
    }
  }

  private func removeThemeChangeObserver() {
    if let themeChangeObserver {
      NotificationCenter.default.removeObserver(themeChangeObserver)
      self.themeChangeObserver = nil
    }
  }

  /// The launch with the *current* terminal identity merged in. Identity is a
  /// live setting; resolving it per spawn means flipping it in Settings
  /// reaches the next new session without relaunching Laban. The provider
  /// also reinstalls the shell-integration overlay if its files were
  /// deleted since the last spawn.
  private var spawnShellLaunch: ShellIntegrationLaunch {
    shellLaunchProvider().withTerminalIdentity(TerminalIdentitySettings.identity())
  }

  private func labptyOpenRequest(
    for tab: Tab,
    size: LabanTerminalSize
  ) -> LabptyOpenSessionRequest {
    LabptyOpenSessionRequest(
      rows: UInt32(max(1, Int(size.rows))),
      cols: UInt32(max(1, Int(size.cols))),
      argv: (argvProvider?(tab.id, tab.focusedSessionId) ?? shellLaunchProvider().argv) ?? [],
      envp: mergedSpawnEnvironment(for: tab).map { "\($0.key)=\($0.value)" }.sorted(),
      cwd: cwdByLogicalSessionId(tab.focusedSessionId),
      logicalSessionId: tab.focusedSessionId)
  }

  private func launchRequest(
    for tab: Tab,
    size: LabanTerminalSize
  ) -> TerminalSessionLaunchRequest {
    let argv = argvProvider?(tab.id, tab.focusedSessionId) ?? shellLaunchProvider().argv
    return TerminalSessionLaunchRequest(
      executable: argv?.first,
      argv: argv,
      cwd: cwdByLogicalSessionId(tab.focusedSessionId),
      environmentPatch: mergedSpawnEnvironment(for: tab),
      rows: Int(size.rows),
      cols: Int(size.cols),
      logicalSessionId: tab.focusedSessionId
    )
  }

  private func mergedSpawnEnvironment(for tab: Tab) -> [String: String] {
    var env = spawnShellLaunch.environmentOverrides
    if let overrides = launchEnvironmentProvider?(tab.id, tab.focusedSessionId) {
      for (key, value) in overrides {
        env[key] = value
      }
    }
    return env
  }

  private func cwdByLogicalSessionId(_ logicalSessionId: String) -> String {
    launchCwdOverrideBySessionId[logicalSessionId] ?? cwdBySessionId[logicalSessionId]
      ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  private func fallbackSize() -> LabanTerminalSize {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return size
  }
}

private final class LabptyParserFeed {
  let ptyHandle: UInt64
  private let reader: LabptyByteRingReader
  private let session: Session
  private let onDirty: @Sendable (Session.ID) -> Void
  private let onOverflow: @Sendable () -> Void
  private let onResponse: @Sendable ([UInt8]) -> Void
  private let onQueuedOutput: @Sendable ([UInt8]) -> Bool
  private let queue: DispatchQueue
  private let timer: DispatchSourceTimer
  private let lock = NSLock()
  private var lastOffset: UInt64 = 0
  private var stopped = false
  // True while the feed's first non-empty read is still ahead of it. A
  // reattach feed starts from offset 0, so that read spans historical output
  // the child was already answered for (or long gave up on): query replies
  // the parser regenerates while replaying it must not be forwarded, or they
  // land in the child's input as garbage (post-restart "10;rgb:..." paste).
  // Touched only from `poll()` on the serial timer queue, like `lastOffset`.
  private var catchUpResponseSuppressionPending: Bool
  // The PTY's grid when a reattach feed started, which is what the retained
  // output was written for. The catch-up read parses at this grid, not the
  // session's guessed launch grid: zsh's PROMPT_SP padding otherwise wraps
  // and the window resize rejoins it as "%   <prompt>", and pixel-sized Kitty
  // images span the wrong rows. Nil for a feed that opened its session.
  private let catchUpGrid: (cols: Int, rows: Int)?
  // Touched only from `poll()` on the serial timer queue, like `lastOffset`.
  private var overflowGate = LabptyByteRingOverflowGate()
  // Lock-guarded mirror of `lastOffset`, written by `poll()` right after it
  // updates `lastOffset` itself. `lastOffset` is confined to `queue`; this
  // mirror lets `wakeIfOutputPending()` read "how far have we consumed" from
  // the main thread without hopping to `queue` first, which is the whole
  // point (see that method's comment for the concurrency argument).
  private let publishedLastOffset = OSAllocatedUnfairLock(initialState: UInt64(0))

  init(
    ptyHandle: UInt64,
    reader: LabptyByteRingReader,
    session: Session,
    catchUpGrid: (cols: Int, rows: Int)?,
    onDirty: @escaping @Sendable (Session.ID) -> Void,
    onOverflow: @escaping @Sendable () -> Void,
    onResponse: @escaping @Sendable ([UInt8]) -> Void,
    onQueuedOutput: @escaping @Sendable ([UInt8]) -> Bool
  ) {
    self.ptyHandle = ptyHandle
    self.reader = reader
    self.session = session
    self.catchUpResponseSuppressionPending = catchUpGrid != nil
    self.catchUpGrid = catchUpGrid
    self.onDirty = onDirty
    self.onOverflow = onOverflow
    self.onResponse = onResponse
    self.onQueuedOutput = onQueuedOutput
    self.queue = DispatchQueue(label: "com.laban.labpty.parser.\(ptyHandle)", qos: .userInteractive)
    self.timer = DispatchSource.makeTimerSource(queue: queue)
  }

  func start(pollingIntervalMilliseconds: Int = 4) {
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    scheduleTimer(pollingIntervalMilliseconds: pollingIntervalMilliseconds)
    IdleCounters.shared.noteLabptyFeedStarted()
    timer.resume()
  }

  func setPollingInterval(milliseconds: Int) {
    queue.async { [weak self] in
      self?.scheduleTimer(pollingIntervalMilliseconds: milliseconds)
    }
  }

  func wake() {
    queue.async { [weak self] in
      self?.poll()
    }
  }

  // Called only from `pollAllLabptyFeeds()` (main thread) on the 8ms active
  // drain tick, to skip the `queue.async` hop and the ring read in `poll()`
  // for a tab that has produced nothing since our last consume. Every other
  // caller of `wake()` (the daemon wake-pipe handler, the unpark response,
  // reconnect) stays unconditional, so a stale `publishedLastOffset` mirror
  // can only ever cause a spurious extra `poll()`, never a missed one.
  //
  // Memory-ordering argument: `reader.outputWriteOffset()` does an aligned
  // acquire load of the daemon's monotonically increasing write-offset
  // counter in the shared-memory ring (see
  // `LabptyByteRingReader.outputWriteOffset()`, a read-only load from an
  // mmap the daemon owns and only ever appends to; it is safe to call from
  // any thread, including this one racing `poll()` on `queue`). We compare it
  // against the offset `poll()` last published *after* consuming up to that
  // point. Three interleavings are possible:
  //  - the producer wrote nothing new: `outputWriteOffset() <=` the mirror,
  //    we correctly skip.
  //  - the producer wrote before our read and `poll()` already published the
  //    new mirror value: we see the advance and wake, correctly.
  //  - the producer writes concurrently with our read, racing `poll()`'s own
  //    mirror update: worst case we read a stale (too-low) mirror and skip a
  //    wake this tick, but the daemon's wake pipe still fires for that same
  //    write, and `handleLabptyOutputWake` polls all feeds unconditionally,
  //    so the output is never stranded, only picked up slightly later.
  func wakeIfOutputPending() {
    guard reader.outputWriteOffset() > publishedLastOffset.withLock({ $0 }) else { return }
    wake()
  }

  func observedWakeParkEntry(
    _ completion: @escaping @Sendable (LabptyOutputWakeParkEntry) -> Void
  ) {
    queue.async {
      completion(
        LabptyOutputWakeParkEntry(
          ptyHandle: self.ptyHandle,
          observedOutputOffset: self.lastOffset))
    }
  }

  func stop() {
    let shouldCancel: Bool = lock.withLock {
      if stopped { return false }
      stopped = true
      return true
    }
    if shouldCancel {
      timer.setEventHandler {}
      timer.cancel()
      IdleCounters.shared.noteLabptyFeedStopped()
    }
  }

  private func scheduleTimer(pollingIntervalMilliseconds: Int) {
    let interval = max(1, pollingIntervalMilliseconds)
    let leeway = interval <= 4 ? 1 : max(50, interval / 10)
    timer.schedule(
      deadline: .now(),
      repeating: .milliseconds(interval),
      leeway: .milliseconds(leeway))
  }

  private func poll() {
    if lock.withLock({ stopped }) {
      return
    }
    if session.hasQueuedOutput() {
      pumpQueuedOutput()
    }
    let result = reader.readSince(lastOffset)
    lastOffset = result.newOffset
    // Publish right after consuming, so a concurrent `wakeIfOutputPending()`
    // read on the main thread never observes an offset we have not actually
    // finished handling yet.
    publishedLastOffset.withLock { $0 = result.newOffset }
    IdleCounters.shared.noteLabptyPoll(byteCount: result.bytes.count)
    // Replay reads re-answer every historical query still in the window (OSC
    // color probes, CPR, DA): the reattach catch-up read from offset 0, and
    // any overflow read whose re-fed window tail was already parsed and
    // answered live. Replies regenerated from such bytes are drained below
    // but must not be forwarded — the child is not waiting for them and
    // would echo them as garbage input. Accepted trade-off: a child that
    // emitted a query while no client was attached and is still blocked on
    // the reply does not get it from the replay (it got no reply while
    // detached either).
    let replayRead = catchUpResponseSuppressionPending || result.overflowed
    guard result.overflowed || !result.bytes.isEmpty else { return }
    let catchUpRead = catchUpResponseSuppressionPending
    catchUpResponseSuppressionPending = false
    // The first read positions the cursor from offset 0, so its span covers the
    // session's whole lifetime, not output we dropped live: on a restart
    // reconnect to a session that has emitted more than a window of output it
    // "overflows" by construction. Repaint from the window tail either way, but
    // only raise the "output skipped" badge once we hold an established cursor
    // and genuinely fell behind the producer in real time.
    let liveDrop = overflowGate.isLiveDrop(overflowed: result.overflowed)
    if result.overflowed {
      if liveDrop {
        AppLog.app.error(
          "labpty byte ring overflow for pty handle \(self.ptyHandle); resetting parser continuity")
        onOverflow()
      } else {
        AppLog.app.info(
          "labpty byte ring join repaint from window tail for pty handle \(self.ptyHandle)")
      }
      _ = session.feedOutput([0x1B, 0x63])
    }
    // Exhausted byte-ring confirmation retries deliberately return no bytes:
    // the uncertain range was dropped, but the RIS above still changed parser
    // and render state and must become visible immediately.
    guard !result.bytes.isEmpty else {
      onDirty(session.id)
      return
    }
    let diagBefore =
      ScrollDiagnostics.shared.isEnabled ? session.viewportState() : nil
    // The reattach catch-up read also re-runs the host side effects in that
    // history: an OSC 52 copy made before the restart would overwrite whatever
    // the user copied since, and old OSC 9 notifications would post again, so
    // drop them. An overflow read is NOT suppressed here: its window tail
    // starts past `lastOffset`, so every byte in it is new and a copy or
    // notification in it is live.
    let feed: () -> Void = {
      if catchUpRead, let catchUpGrid = self.catchUpGrid {
        self.session.feedOutput(
          Array(result.bytes), writtenAtCols: catchUpGrid.cols, rows: catchUpGrid.rows)
      } else {
        _ = self.session.feedOutput(Array(result.bytes))
      }
    }
    if catchUpRead {
      session.withHostEffectsSuppressed(feed)
    } else {
      feed()
    }
    if ScrollDiagnostics.shared.isEnabled, let after = session.viewportState() {
      // Does appending output on the background timer move `viewportOffset` with
      // `totalRows` (follow-output engaged) or leave the offset behind so the
      // overlay's `linesBack` keeps climbing while the user sits at the bottom?
      ScrollDiagnostics.shared.feed(
        bytesLen: result.bytes.count,
        offBefore: diagBefore?.viewportOffset ?? after.viewportOffset,
        totalBefore: diagBefore?.totalRows ?? after.totalRows,
        off: after.viewportOffset, total: after.totalRows, vp: after.viewportRows,
        sb: after.scrollbackRows, alt: after.altScreen, mouse: after.mouseTracking)
    }
    // The daemon owns the PTY, so replies the parser generated while consuming
    // this chunk (CPR/DA/OSC color queries) exist only in the session's
    // response buffer. Ship them back over the daemon socket or the querying
    // child blocks forever (gh auth login's survey size probe) — unless this
    // read replayed historical bytes, whose queries were answered (or
    // abandoned) long ago; forwarding those replies is the post-restart
    // garbage-input bug.
    let responses = session.drainResponse()
    if !responses.isEmpty && !replayRead {
      onResponse(responses)
    }
    // Only the reattach catch-up read is history; an overflow read is new
    // bytes and must not drop a live reply still being sent.
    if catchUpRead {
      session.discardQueuedOutput()
    } else if session.hasQueuedOutput() {
      pumpQueuedOutput()
    }
    onDirty(session.id)
  }

  /// Send queued output (a large clipboard reply plus anything queued behind
  /// it, ADR 0040) to the daemon in chunks. While some is left, one follow-up
  /// poll is scheduled (never more than one), backing off while the daemon
  /// refuses chunks. A refused chunk stays queued. If nothing is accepted for
  /// `queuedOutputStallLimit` (a canonical-mode reader can never take a
  /// multi-kilobyte line), the queue is dropped so input is not trapped
  /// behind it; keystrokes typed during that stall are lost with it.
  private func pumpQueuedOutput() {
    var sent = 0
    var refused = false
    while sent < Self.queuedOutputBytesPerPump {
      let chunk = session.peekQueuedOutput(maxBytes: Self.queuedOutputChunkBytes)
      guard !chunk.isEmpty else {
        queuedOutputStalledSince = nil
        return
      }
      guard onQueuedOutput(chunk) else {
        refused = true
        break
      }
      session.consumeQueuedOutput(chunk.count)
      sent += chunk.count
    }
    if sent > 0 {
      queuedOutputStalledSince = nil
    } else if refused {
      let now = Date()
      let since = queuedOutputStalledSince ?? now
      queuedOutputStalledSince = since
      if now.timeIntervalSince(since) >= Self.queuedOutputStallLimit {
        AppLog.app.error(
          "labpty queued output stalled for pty handle \(self.ptyHandle); dropping it")
        session.discardQueuedOutput()
        queuedOutputStalledSince = nil
        return
      }
    }
    guard !queuedOutputRepollScheduled else { return }
    queuedOutputRepollScheduled = true
    let delay = refused && sent == 0 ? 50 : 2
    queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
      self?.queuedOutputRepollScheduled = false
      self?.poll()
    }
  }

  // Touched only on the serial feed queue, like `lastOffset`.
  private var queuedOutputRepollScheduled = false
  private var queuedOutputStalledSince: Date?
  private static let queuedOutputChunkBytes = 16 * 1024
  private static let queuedOutputBytesPerPump = 1024 * 1024
  private static let queuedOutputStallLimit: TimeInterval = 3
}
