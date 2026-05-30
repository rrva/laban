import Darwin
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class AppSessionCoordinator {
  private let mode: TerminalSessionBackend
  private let labandClient: LabandTerminalSessionClient?
  private let labptyClient: LabptyTerminalSessionClient?
  private let shellLaunch: ShellIntegrationLaunch
  private let cwdByTabId: [Tab.ID: String]
  private let supportsThemeApplication: Bool
  private let supportsViewportScroll: Bool
  private var infoByTabId: [Tab.ID: LabandSessionInfo] = [:]
  private var infoByLocalSessionId: [Session.ID: LabandSessionInfo] = [:]
  private var labptyDescriptorByTabId: [Tab.ID: LabptySessionDescriptor] = [:]
  private var labptyFeedByTabId: [Tab.ID: LabptyParserFeed] = [:]
  private let labptyStateLock = NSLock()
  private var labptyDegradedTabIds: Set<Tab.ID> = []
  private var ownedProcess: Process?
  private var themeChangeObserver: NSObjectProtocol?
  private var snapshotGenerationMonitor: LabandSnapshotGenerationMonitor?
  private var lastTabMetadataRefreshAt: Date?
  private let processIntrospector = LibprocIntrospector()

  var onSessionDirty: (@Sendable (Session.ID) -> Void)?

  init(
    client: LabandTerminalSessionClient,
    shellLaunch: ShellIntegrationLaunch,
    cwdByTabId: [Tab.ID: String] = [:],
    labandProcess: Process? = nil
  ) {
    self.mode = .laband
    self.labandClient = client
    self.labptyClient = nil
    self.shellLaunch = shellLaunch
    self.cwdByTabId = cwdByTabId
    self.ownedProcess = labandProcess
    let capabilities = (try? client.hello().capabilities) ?? []
    self.supportsThemeApplication = capabilities.contains("theme-palette/v1")
    self.supportsViewportScroll = capabilities.contains("viewport-scroll/v1")
    installThemeObserver()
  }

  init(
    labptyClient: LabptyTerminalSessionClient,
    shellLaunch: ShellIntegrationLaunch,
    cwdByTabId: [Tab.ID: String] = [:],
    labptyProcess: Process? = nil
  ) {
    self.mode = .labpty
    self.labandClient = nil
    self.labptyClient = labptyClient
    self.shellLaunch = shellLaunch
    self.cwdByTabId = cwdByTabId
    self.ownedProcess = labptyProcess
    self.supportsThemeApplication = false
    self.supportsViewportScroll = false
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

  var usesRemoteSnapshots: Bool {
    mode == .laband
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
    for logicalSessionId in Set(infoByTabId.values.map(\.logicalSessionId)) {
      monitor.track(sessionId: logicalSessionId)
    }
  }

  func stopSnapshotGenerationMonitor() {
    snapshotGenerationMonitor?.stop()
    snapshotGenerationMonitor = nil
  }

  func ensureSessions(for tabs: [Tab], in model: AppModel, size: LabanTerminalSize) throws {
    for tab in tabs {
      _ = try ensureSession(for: tab, session: model.session(forTab: tab.id), size: size)
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
    infoByTabId[tab.id] ?? infoByLocalSessionId[tab.sessionId]
  }

  func snapshot(for tab: Tab, size: LabanTerminalSize) throws -> LabandSnapshotResponse {
    try snapshotFrame(for: tab, size: size).snapshot
  }

  func snapshotGeneration(for tab: Tab, size: LabanTerminalSize) throws -> UInt64? {
    guard let labandClient else { return nil }
    let info = try ensureLabandSession(for: tab, size: size)
    return labandClient.snapshotRingGeneration(sessionId: info.logicalSessionId)
  }

  func snapshotFrame(for tab: Tab, size: LabanTerminalSize) throws -> LabandSnapshotFrame {
    guard let labandClient else {
      throw TerminalSessionClientError.snapshotFailed(tab.id)
    }
    let info = try ensureLabandSession(for: tab, size: size)
    return try labandClient.snapshotFrame(sessionId: info.logicalSessionId)
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
      try labptyClient.writeInput(handle: descriptor.ptyHandle, bytes: bytes)
      return
    }
    guard let labandClient else { return }
    let info = try ensureLabandSession(for: tab, size: size)
    snapshotGenerationMonitor?.boost(sessionId: info.logicalSessionId)
    try labandClient.writeInput(sessionId: info.logicalSessionId, bytes: bytes)
    if let refreshed = try? labandClient.lookupSession(logicalSessionId: info.logicalSessionId) {
      store(refreshed, for: tab)
    }
  }

  func resize(tabs: [Tab], in model: AppModel, size: LabanTerminalSize) {
    for tab in tabs {
      do {
        let session = model.session(forTab: tab.id)
        if let labptyClient {
          let descriptor = try ensureLabptyDescriptor(for: tab, session: session, size: size)
          let resized = try labptyClient.resize(
            handle: descriptor.ptyHandle,
            rows: Int(size.rows),
            cols: Int(size.cols))
          storeLabpty(resized, for: tab)
          continue
        }
        guard let labandClient else { continue }
        let info = try ensureLabandSession(for: tab, size: size)
        let resized = try labandClient.resize(
          sessionId: info.logicalSessionId,
          rows: Int(size.rows),
          cols: Int(size.cols)
        )
        store(resized, for: tab)
      } catch {
        AppLog.app.error("session resize failed for tab \(tab.id): \(String(describing: error))")
      }
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
    var logicalSessionId = sessionInfo(for: tab)?.logicalSessionId
    if let labptyClient {
      if let descriptor = labptyDescriptorByTabId[tab.id] {
        _ = try? labptyClient.terminate(handle: descriptor.ptyHandle)
      } else if let info = sessionInfo(for: tab) {
        _ = try? labptyClient.terminate(sessionId: info.logicalSessionId)
      }
      stopLabptyFeed(for: tab)
      removeCachedInfo(for: tab)
      return
    }

    guard let labandClient else { return }
    do {
      let info = try ensureLabandSession(for: tab, size: fallbackSize())
      logicalSessionId = info.logicalSessionId
      let terminated = try labandClient.terminate(sessionId: info.logicalSessionId)
      store(terminated, for: tab)
    } catch {
      AppLog.app.error("laband terminate failed for tab \(tab.id): \(String(describing: error))")
    }
    if let logicalSessionId {
      snapshotGenerationMonitor?.untrack(sessionId: logicalSessionId)
    }
    removeCachedInfo(for: tab)
  }

  func sweepOrphanedSessions() {
    guard mode == .laband else { return }
    let knownIds = Set(infoByTabId.values.map(\.logicalSessionId))
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
  func unclaimedLabptySessions(knownTabIds: Set<Tab.ID>) -> [LabptySessionDescriptor] {
    guard mode == .labpty, let labptyClient else { return [] }
    let descriptors: [LabptySessionDescriptor]
    do {
      descriptors = try labptyClient.listLabptySessions()
    } catch {
      AppLog.app.error(
        "labpty listSessions failed during orphan detection: \(String(describing: error))")
      return []
    }
    return descriptors.filter { $0.alive && !knownTabIds.contains($0.logicalSessionId) }
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
          launchCommand: shellLaunch.argv?.joined(separator: " ") ?? "",
          isActive: false)
        _ = try ensureSession(for: tab, session: model.session(forTab: tab.id), size: size)
        adopted.append(tab)
      } catch {
        AppLog.app.error(
          "labpty adopt failed for \(descriptor.logicalSessionId): \(String(describing: error))")
      }
    }
    return adopted
  }

  func refreshTabMetadata(for tabs: [Tab], into model: AppModel, now: Date = Date()) {
    if let last = lastTabMetadataRefreshAt, now.timeIntervalSince(last) < 0.25 {
      return
    }
    lastTabMetadataRefreshAt = now
    if let labptyClient {
      refreshLabptyTabMetadata(tabs: tabs, model: model, client: labptyClient, now: now)
      return
    }
    guard let labandClient else { return }
    let infos: [LabandSessionInfo]
    do {
      infos = try labandClient.listSessions()
    } catch {
      AppLog.app.error(
        "laband listSessions failed during tab metadata refresh: \(String(describing: error))")
      return
    }
    let infoById = Dictionary(uniqueKeysWithValues: infos.map { ($0.logicalSessionId, $0) })
    for tab in tabs {
      guard let info = infoById[tab.id] else { continue }
      store(info, for: tab)
      let signals = surfaceSignals(from: info)
      _ = model.applySurfaceSignals(signals, forTab: tab.id, now: now)
    }
  }

  func detach() {
    removeThemeChangeObserver()
    stopSnapshotGenerationMonitor()
    for feed in labptyFeedByTabId.values {
      feed.stop()
    }
    labptyFeedByTabId.removeAll()
    labptyClient?.close()
    labandClient?.close()
    infoByTabId.removeAll()
    infoByLocalSessionId.removeAll()
    labptyDescriptorByTabId.removeAll()
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
    if let cached = infoByTabId[tab.id], cached.lifecycleState == .running {
      return cached
    }

    if let existing = try? labandClient.lookupSession(logicalSessionId: tab.id),
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
    if let cached = infoByTabId[tab.id], cached.lifecycleState == .running,
      let descriptor = labptyDescriptorByTabId[tab.id]
    {
      if labptyFeedByTabId[tab.id] == nil, let session {
        try startLabptyFeed(descriptor: descriptor, tab: tab, session: session)
      }
      return descriptor
    }

    guard let labptyClient else {
      throw TerminalSessionClientError.sessionNotFound(tab.id)
    }
    let existing = try labptyClient.listLabptySessions().first {
      $0.logicalSessionId == tab.id && $0.alive
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
      try startLabptyFeed(descriptor: descriptor, tab: tab, session: session)
    }
    return descriptor
  }

  private func startLabptyFeed(
    descriptor: LabptySessionDescriptor,
    tab: Tab,
    session: Session
  ) throws {
    if labptyFeedByTabId[tab.id]?.ptyHandle == descriptor.ptyHandle {
      return
    }
    stopLabptyFeed(for: tab)
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)
    let tabId = tab.id
    let feed = LabptyParserFeed(
      ptyHandle: descriptor.ptyHandle,
      reader: reader,
      session: session,
      onDirty: { [weak self] sessionId in
        self?.onSessionDirty?(sessionId)
      },
      onOverflow: { [weak self] in
        self?.markLabptyOutputDegraded(for: tabId)
      })
    labptyFeedByTabId[tab.id] = feed
    feed.start()
  }

  private func stopLabptyFeed(for tab: Tab) {
    labptyFeedByTabId.removeValue(forKey: tab.id)?.stop()
    labptyDescriptorByTabId.removeValue(forKey: tab.id)
    clearLabptyOutputDegraded(for: tab.id)
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
    let descriptorById = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.logicalSessionId, $0) })
    for tab in tabs {
      guard let descriptor = descriptorById[tab.id] else { continue }
      storeLabpty(descriptor, for: tab)
      // The "output skipped" badge is an attention notice: it exists so the
      // user can SEE that output was dropped while they were looking elsewhere.
      // Once this is the active (viewed) tab the notice has done its job, so
      // retire the latch — mirroring how bell/unseen-output attention clears
      // on selection. Without this the degraded flag is only ever dropped on
      // stop/close, so the badge sticks to a live tab forever.
      if tab.isActive {
        clearLabptyOutputDegraded(for: tab.id)
      }
      let degraded = isLabptyOutputDegraded(for: tab.id)
      let signals = surfaceSignals(
        from: labptyInfo(from: descriptor),
        labptyOutputDegraded: degraded)
      _ = model.applySurfaceSignals(signals, forTab: tab.id, now: now)
      if !degraded {
        // surfaceSignals sends a nil agentStatus when not degraded, and the
        // synchronizer deliberately leaves a nil alone so a metadata poll can
        // never wipe an OSC 21337 status. Clearing a retired degraded badge is
        // therefore explicit, and scoped to the exact badge so it can never
        // touch an OSC status that happens to share titleMetadata.agentStatus.
        _ = model.clearAgentStatus(forTab: tab.id, ifEquals: Self.labptyOutputDegradedStatus)
      }
    }
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
      metadata.foregroundProcess?.isEmpty == false ? metadata.foregroundProcess! : "Background Session"
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
    let processPid = pid_t(pid)
    let arguments = processIntrospector.arguments(of: processPid)
    let processName = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
    return Session.ProcessMetadata(
      childPid: Int(childPid),
      foregroundPid: Int(pid),
      foregroundProcess: processName,
      foregroundCommand: arguments.isEmpty ? processName : arguments.joined(separator: " "),
      foregroundArguments: arguments.isEmpty ? nil : arguments,
      cwd: processIntrospector.currentWorkingDirectory(of: processPid)
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

  private func store(_ info: LabandSessionInfo, for tab: Tab) {
    infoByTabId[tab.id] = info
    infoByLocalSessionId[tab.sessionId] = info
  }

  private func storeLabpty(_ descriptor: LabptySessionDescriptor, for tab: Tab) {
    labptyDescriptorByTabId[tab.id] = descriptor
    store(labptyInfo(from: descriptor), for: tab)
  }

  private func removeCachedInfo(for tab: Tab) {
    infoByTabId.removeValue(forKey: tab.id)
    infoByLocalSessionId.removeValue(forKey: tab.sessionId)
    clearLabptyOutputDegraded(for: tab.id)
  }

  private static let labptyOutputDegradedStatus = TabAgentStatus(
    indicatorColor: "#f59e0b",
    statusText: "output skipped",
    statusTextColor: "#f59e0b")

  private func markLabptyOutputDegraded(for tabId: Tab.ID) {
    _ = labptyStateLock.withLock {
      labptyDegradedTabIds.insert(tabId)
    }
  }

  private func clearLabptyOutputDegraded(for tabId: Tab.ID) {
    _ = labptyStateLock.withLock {
      labptyDegradedTabIds.remove(tabId)
    }
  }

  private func isLabptyOutputDegraded(for tabId: Tab.ID) -> Bool {
    labptyStateLock.withLock {
      labptyDegradedTabIds.contains(tabId)
    }
  }

  private func attachSnapshotRing(for logicalSessionId: String) {
    guard let labandClient else { return }
    _ = try? labandClient.attachSnapshotRing(sessionId: logicalSessionId)
    snapshotGenerationMonitor?.track(sessionId: logicalSessionId)
  }

  private func applyCurrentThemeToKnownSessions() {
    let logicalSessionIds = Set(infoByTabId.values.map(\.logicalSessionId))
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

  private func labptyOpenRequest(
    for tab: Tab,
    size: LabanTerminalSize
  ) -> LabptyOpenSessionRequest {
    LabptyOpenSessionRequest(
      rows: UInt32(max(1, Int(size.rows))),
      cols: UInt32(max(1, Int(size.cols))),
      argv: shellLaunch.argv ?? [],
      envp: shellLaunch.environmentOverrides.map { "\($0.key)=\($0.value)" }.sorted(),
      cwd: cwdByTabId[tab.id] ?? FileManager.default.homeDirectoryForCurrentUser.path,
      logicalSessionId: tab.id)
  }

  private func launchRequest(
    for tab: Tab,
    size: LabanTerminalSize
  ) -> TerminalSessionLaunchRequest {
    let argv = shellLaunch.argv
    return TerminalSessionLaunchRequest(
      executable: argv?.first,
      argv: argv,
      cwd: cwdByTabId[tab.id] ?? FileManager.default.homeDirectoryForCurrentUser.path,
      environmentPatch: shellLaunch.environmentOverrides,
      rows: Int(size.rows),
      cols: Int(size.cols),
      logicalSessionId: tab.id
    )
  }

  private func cwdByLogicalSessionId(_ logicalSessionId: String) -> String {
    cwdByTabId[logicalSessionId] ?? FileManager.default.homeDirectoryForCurrentUser.path
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
  private let queue: DispatchQueue
  private let timer: DispatchSourceTimer
  private let lock = NSLock()
  private var lastOffset: UInt64 = 0
  private var stopped = false

  init(
    ptyHandle: UInt64,
    reader: LabptyByteRingReader,
    session: Session,
    onDirty: @escaping @Sendable (Session.ID) -> Void,
    onOverflow: @escaping @Sendable () -> Void
  ) {
    self.ptyHandle = ptyHandle
    self.reader = reader
    self.session = session
    self.onDirty = onDirty
    self.onOverflow = onOverflow
    self.queue = DispatchQueue(label: "com.laban.labpty.parser.\(ptyHandle)", qos: .userInteractive)
    self.timer = DispatchSource.makeTimerSource(queue: queue)
  }

  func start() {
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
    timer.resume()
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
    }
  }

  private func poll() {
    if lock.withLock({ stopped }) {
      return
    }
    let result = reader.readSince(lastOffset)
    lastOffset = result.newOffset
    guard !result.bytes.isEmpty else { return }
    if result.overflowed {
      AppLog.app.error(
        "labpty byte ring overflow for pty handle \(self.ptyHandle); resetting parser continuity")
      onOverflow()
      _ = session.feedOutput([0x1B, 0x63])
    }
    _ = session.feedOutput(Array(result.bytes))
    onDirty(session.id)
  }
}
