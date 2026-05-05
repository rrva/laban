import Foundation
import LabanRenderer
import LabanTerminalCore

public final class AppModel {
  public static let maxTabs = 9

  private let modelLock = NSRecursiveLock()
  private var _tabs: [Tab] = []
  public var tabs: [Tab] { withModelLock { _tabs } }
  private var sessions: [Session.ID: Session] = [:]
  private var lastProcessMetadataSyncAtByTab: [Tab.ID: Date] = [:]
  private var processIdentityByTab: [Tab.ID: ProcessIdentity] = [:]
  private var terminalTitleOwnerByTab: [Tab.ID: ProcessIdentity] = [:]
  private var currentSize: LabanTerminalSize
  private let sessionFactory: (LabanTerminalSize) throws -> Session
  private let processMetadataSyncInterval: TimeInterval = 0.25
  private var themeChangeObserver: NSObjectProtocol?
  private let gitInfo = GitInfoTracker()
  public weak var captureSink: CaptureSink? {
    didSet {
      withModelLock {
        for session in sessions.values {
          session.captureSink = captureSink
        }
      }
    }
  }

  @discardableResult
  private func withModelLock<T>(_ body: () throws -> T) rethrows -> T {
    modelLock.lock()
    defer { modelLock.unlock() }
    return try body()
  }

  private struct ProcessIdentity: Equatable {
    var pid: Int?
    var process: String?
    var command: String?

    init?(_ metadata: Session.ProcessMetadata) {
      let pid = metadata.foregroundPid ?? metadata.childPid
      let process = TerminalTitle.sanitize(metadata.foregroundProcess)
      let command = TerminalTitle.sanitize(metadata.foregroundCommand)
      guard pid != nil || process != nil || command != nil else { return nil }
      self.pid = pid
      self.process = process
      self.command = command
    }
  }

  public init(
    initialSize: LabanTerminalSize = defaultSize(),
    sessionFactory: @escaping (LabanTerminalSize) throws -> Session = { size in
      try Session.fixture(size: size)
    }
  ) throws {
    self.currentSize = initialSize
    self.sessionFactory = sessionFactory
    let session = try sessionFactory(initialSize)
    AppModel.maybeAutoCapture(session)
    AppModel.applyThemePalette(to: session)
    let tab = Tab(
      id: UUID().uuidString,
      position: 1,
      title: "Tab 1",
      isActive: true,
      sessionId: session.id
    )
    sessions[session.id] = session
    if let captureSink {
      session.captureSink = captureSink
    }
    _tabs.append(tab)
    attachTabStatus(session: session, tabId: tab.id)
    themeChangeObserver = NotificationCenter.default.addObserver(
      forName: Theme.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // Re-inject the new palette into every running session so SGR colors
      // and the default fg/bg/cursor that libghostty has cached for new
      // output match the swapped theme. Cells already in scrollback keep
      // their resolved RGB — that's standard terminal behavior.
      self.withModelLock {
        for session in self.sessions.values {
          AppModel.applyThemePalette(to: session)
        }
      }
    }
  }

  deinit {
    if let themeChangeObserver {
      NotificationCenter.default.removeObserver(themeChangeObserver)
    }
  }

  public var activeTab: Tab? { withModelLock { _tabs.first(where: { $0.isActive }) } }

  public func session(forTab tabId: Tab.ID) -> Session? {
    withModelLock {
      guard let tab = _tabs.first(where: { $0.id == tabId }) else { return nil }
      return sessions[tab.sessionId]
    }
  }

  @discardableResult
  public func createTab() throws -> Tab {
    try withModelLock {
      guard _tabs.count < AppModel.maxTabs else { throw AppError.tabLimitReached }
      let session = try sessionFactory(currentSize)
      session.captureSink = captureSink
      AppModel.maybeAutoCapture(session)
      AppModel.applyThemePalette(to: session)
      let position = _tabs.count + 1
      let tab = Tab(
        id: UUID().uuidString,
        position: position,
        title: "Tab \(position)",
        isActive: false,
        sessionId: session.id
      )
      sessions[session.id] = session
      _tabs.append(tab)
      attachTabStatus(session: session, tabId: tab.id)
      recordSessionCreated(sessionId: session.id, tabId: tab.id)
      recordTab(.tabCreated, tabId: tab.id, sessionId: session.id)
      selectTab(tab.id)
      return _tabs.last!
    }
  }

  public func selectTab(_ tabId: Tab.ID) {
    withModelLock {
      guard let selectedIdx = _tabs.firstIndex(where: { $0.id == tabId }) else { return }
      for i in _tabs.indices {
        let selected = i == selectedIdx
        _tabs[i].isActive = selected
        if selected {
          _tabs[i].titleMetadata.unseenOutput = false
        }
        if _tabs[i].status == .running {
          _tabs[i].titleMetadata.activityState =
            selected
            ? .active
            : (_tabs[i].titleMetadata.unseenOutput ? .unseenOutput : .background)
        }
      }
      let tab = _tabs[selectedIdx]
      recordTab(.tabSelected, tabId: tab.id, sessionId: tab.sessionId)
    }
  }

  public func closeTab(_ tabId: Tab.ID) throws {
    try withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      let tab = _tabs[idx]
      let closedCwd = tab.titleMetadata.workspace.cwd

      if _tabs.count == 1 {
        sessions[tab.sessionId]?.close()
        sessions.removeValue(forKey: tab.sessionId)
        if let closedCwd { gitInfo.forget(cwd: closedCwd) }
        lastProcessMetadataSyncAtByTab.removeValue(forKey: tab.id)
        processIdentityByTab.removeValue(forKey: tab.id)
        terminalTitleOwnerByTab.removeValue(forKey: tab.id)
        _tabs = []
        recordTab(.tabClosed, tabId: tab.id, sessionId: tab.sessionId)
        throw AppError.lastTabClosed
      }

      // Determine next active tab before removing
      let wasActive = tab.isActive
      sessions[tab.sessionId]?.close()
      sessions.removeValue(forKey: tab.sessionId)
      if let closedCwd { gitInfo.forget(cwd: closedCwd) }
      lastProcessMetadataSyncAtByTab.removeValue(forKey: tab.id)
      processIdentityByTab.removeValue(forKey: tab.id)
      terminalTitleOwnerByTab.removeValue(forKey: tab.id)
      _tabs.remove(at: idx)
      recordTab(.tabClosed, tabId: tab.id, sessionId: tab.sessionId)

      // Recompute one-based positions
      for i in _tabs.indices {
        _tabs[i].position = i + 1
        resolveTitle(at: i)
      }

      if wasActive {
        let newActiveIdx = min(idx, _tabs.count - 1)
        _tabs[newActiveIdx].isActive = true
        _tabs[newActiveIdx].titleMetadata.unseenOutput = false
        if _tabs[newActiveIdx].status == .running {
          _tabs[newActiveIdx].titleMetadata.activityState = .active
        }
      }
    }
  }

  public func updateTitle(_ title: String, forTab tabId: Tab.ID) throws {
    try updateTerminalTitle(title, forTab: tabId)
  }

  public func updateTerminalTitle(_ title: String?, forTab tabId: Tab.ID) throws {
    try withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      guard let sanitized = TerminalTitle.sanitize(title) else { return }
      setTerminalTitle(sanitized, forTab: tabId, at: idx)
      resolveTitle(at: idx)
    }
  }

  public func renameTab(_ tabId: Tab.ID, title: String) throws {
    try withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      guard let sanitized = TerminalTitle.sanitize(title) else {
        try clearUserTitle(forTab: tabId)
        return
      }
      _tabs[idx].titleMetadata.userTitle = sanitized
      _tabs[idx].titleMetadata.displayTitle = sanitized
      _tabs[idx].titleMetadata.titleSource = .user
      _tabs[idx].titleMetadata.lastActivityAt = Date()
    }
  }

  public func freezeTitle(forTab tabId: Tab.ID, frozen: Bool = true) throws {
    try withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      if frozen, _tabs[idx].titleMetadata.userTitle == nil {
        _tabs[idx].titleMetadata.userTitle = _tabs[idx].titleMetadata.displayTitle
        _tabs[idx].titleMetadata.titleSource = .user
      }
      _tabs[idx].titleMetadata.titleFrozen = frozen
      resolveTitle(at: idx)
    }
  }

  public func clearUserTitle(forTab tabId: Tab.ID) throws {
    try withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      _tabs[idx].titleMetadata.userTitle = nil
      _tabs[idx].titleMetadata.titleFrozen = false
      resolveTitle(at: idx)
    }
  }

  public func updateTitleMetadata(
    forTab tabId: Tab.ID,
    workspace: TabWorkspaceMetadata? = nil,
    process: TabProcessMetadata? = nil,
    agent: TabAgentMetadata? = nil,
    activityState: TabActivityState? = nil,
    lastActivityAt: Date? = nil,
    lastOutputAt: Date? = nil,
    unseenOutput: Bool? = nil,
    exitStatus: Int? = nil
  ) throws {
    try withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      if let workspace { _tabs[idx].titleMetadata.workspace = workspace }
      if let process { _tabs[idx].titleMetadata.process = process }
      if let agent { _tabs[idx].titleMetadata.agent = agent }
      if let activityState { _tabs[idx].titleMetadata.activityState = activityState }
      if let lastActivityAt { _tabs[idx].titleMetadata.lastActivityAt = lastActivityAt }
      if let lastOutputAt { _tabs[idx].titleMetadata.lastOutputAt = lastOutputAt }
      if let unseenOutput { _tabs[idx].titleMetadata.unseenOutput = unseenOutput }
      if let exitStatus { _tabs[idx].titleMetadata.exitStatus = exitStatus }
      resolveTitle(at: idx)
    }
  }

  /// Consume any pending title update from the session, apply the title policy,
  /// and update the stored title metadata only when the result differs.
  /// Returns true if title metadata was changed.
  @discardableResult
  public func syncTitle(forTab tabId: Tab.ID, from session: Session) -> Bool {
    withModelLock {
      let (dirty, raw) = session.consumeTitle()
      guard dirty else { return false }
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      let before = _tabs[idx].titleMetadata
      setTerminalTitle(TerminalTitle.sanitize(raw), forTab: tabId, at: idx)
      resolveTitle(at: idx)
      return _tabs[idx].titleMetadata != before
    }
  }

  @discardableResult
  public func syncProcessMetadata(
    forTab tabId: Tab.ID,
    from session: Session,
    now: Date = Date()
  ) -> Bool {
    withModelLock {
      guard _tabs.contains(where: { $0.id == tabId }) else { return false }
      if let last = lastProcessMetadataSyncAtByTab[tabId],
        now.timeIntervalSince(last) < processMetadataSyncInterval
      {
        return false
      }
      lastProcessMetadataSyncAtByTab[tabId] = now

      guard let metadata = session.processMetadata() else { return false }
      return applyProcessMetadata(metadata, forTab: tabId, now: now)
    }
  }

  @discardableResult
  func applyProcessMetadata(
    _ metadata: Session.ProcessMetadata,
    forTab tabId: Tab.ID,
    now: Date = Date()
  ) -> Bool {
    withModelLock {
      _ = now
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      let before = _tabs[idx].titleMetadata
      let newIdentity = ProcessIdentity(metadata)
      let oldIdentity = processIdentityByTab[tabId]
      let processChanged = oldIdentity != nil && oldIdentity != newIdentity

      if processChanged {
        _tabs[idx].titleMetadata.terminalTitle = nil
        terminalTitleOwnerByTab.removeValue(forKey: tabId)
      } else if let owner = terminalTitleOwnerByTab[tabId], owner != newIdentity {
        _tabs[idx].titleMetadata.terminalTitle = nil
        terminalTitleOwnerByTab.removeValue(forKey: tabId)
      } else if terminalTitleOwnerByTab[tabId] == nil,
        _tabs[idx].titleMetadata.terminalTitle != nil,
        let newIdentity
      {
        terminalTitleOwnerByTab[tabId] = newIdentity
      }

      if let newIdentity {
        processIdentityByTab[tabId] = newIdentity
      } else {
        processIdentityByTab.removeValue(forKey: tabId)
      }

      var workspace = _tabs[idx].titleMetadata.workspace
      if let cwd = metadata.cwd {
        workspace.cwd = cwd
        // Kick off git branch resolution off-main; the completion writes
        // the branch back into the tab if the cwd hasn't changed in the
        // meantime. Cheap when cached + HEAD mtime stable.
        gitInfo.refresh(cwd: cwd) { [weak self] resolvedCwd, branch in
          self?.applyResolvedBranch(branch, forTab: tabId, cwd: resolvedCwd)
        }
      }

      var process = _tabs[idx].titleMetadata.process
      process.foregroundProcess = metadata.foregroundProcess
      process.foregroundCommand = metadata.foregroundCommand
      process.pid = metadata.foregroundPid

      _tabs[idx].titleMetadata.workspace = workspace
      _tabs[idx].titleMetadata.process = process
      resolveTitle(at: idx)
      return _tabs[idx].titleMetadata != before
    }
  }

  /// Read exit state from the session and record it in the tab.
  /// Exit state is monotonic: once a tab is non-running, this is a no-op.
  /// Returns true if the tab status changed.
  @discardableResult
  public func syncExitState(forTab tabId: Tab.ID, from session: Session) -> Bool {
    withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      guard _tabs[idx].status == .running else { return false }
      let s = session.exitState()
      guard s != .running else { return false }
      _tabs[idx].status = s
      _tabs[idx].titleMetadata.activityState = .exited
      switch s {
      case .exited(let code), .exitedSignal(let code):
        _tabs[idx].titleMetadata.exitStatus = code
      case .running:
        break
      }
      return true
    }
  }

  /// Force-sets a tab's status directly. Internal; exposed for unit tests only.
  func forceExitState(forTab tabId: Tab.ID, status: TabStatus) {
    withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return }
      _tabs[idx].status = status
      if status != .running {
        _tabs[idx].titleMetadata.activityState = .exited
        switch status {
        case .exited(let code), .exitedSignal(let code):
          _tabs[idx].titleMetadata.exitStatus = code
        case .running:
          break
        }
      }
    }
  }

  @discardableResult
  public func noteOutput(forTab tabId: Tab.ID, at date: Date = Date()) -> Bool {
    withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      let before = _tabs[idx].titleMetadata
      _tabs[idx].titleMetadata.lastOutputAt = date
      _tabs[idx].titleMetadata.lastActivityAt = date
      if _tabs[idx].status == .running {
        if _tabs[idx].isActive {
          _tabs[idx].titleMetadata.unseenOutput = false
          _tabs[idx].titleMetadata.activityState = .active
        } else {
          _tabs[idx].titleMetadata.unseenOutput = true
          _tabs[idx].titleMetadata.activityState = .unseenOutput
        }
      }
      resolveTitle(at: idx)
      return _tabs[idx].titleMetadata != before
    }
  }

  /// The display title for the AppKit window: active tab title, or "Laban" as fallback.
  public var windowTitle: String {
    withModelLock {
      guard let title = activeTab?.title, !title.isEmpty else { return "Laban" }
      return title
    }
  }

  /// If `LABAN_CAPTURE_DIR` is set, start a fresh PTY-byte capture for this
  /// session into `<dir>/session-<id>-<timestamp>.bin`. Capture begins
  /// before `applyThemePalette` so the OSC palette injection — which sets
  /// the default colors that subsequent rendering depends on — is recorded
  /// alongside the rest of the byte stream.
  private static func maybeAutoCapture(_ session: Session) {
    guard let dir = ProcessInfo.processInfo.environment["LABAN_CAPTURE_DIR"],
      !dir.isEmpty
    else { return }
    let dirURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    try? FileManager.default.createDirectory(
      at: dirURL, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let fileURL = dirURL.appendingPathComponent("session-\(session.id)-\(stamp).bin")
    _ = session.startCapture(path: fileURL.path)
  }

  private static func applyThemePalette(to session: Session) {
    var bytes: [UInt8] = []
    for (i, color) in Theme.CurrentTheme.ansi16.enumerated() {
      bytes += oscSeq(4, index: i, rgba: color)
    }
    bytes += oscSeq(10, rgba: Theme.CurrentTheme.fg0)
    bytes += oscSeq(11, rgba: Theme.CurrentTheme.bg0)
    bytes += oscSeq(12, rgba: Theme.CurrentTheme.cursor)
    session.feedOutput(bytes)
  }

  private static func oscSeq(_ n: Int, index: Int? = nil, rgba: UInt32) -> [UInt8] {
    let r = (rgba >> 24) & 0xFF
    let g = (rgba >> 16) & 0xFF
    let b = (rgba >> 8) & 0xFF
    let hex = String(format: "%02x%02x%02x", r, g, b)
    let s =
      index.map { "\u{1B}]\(n);\($0);#\(hex)\u{07}" }
      ?? "\u{1B}]\(n);#\(hex)\u{07}"
    return Array(s.utf8)
  }

  public func resize(viewportWidth: Int, viewportHeight: Int, cellWidth: Int, cellHeight: Int) {
    withModelLock {
      let safeCellWidth = max(1, cellWidth)
      let safeCellHeight = max(1, cellHeight)
      let safeViewportWidth = max(0, viewportWidth)
      let safeViewportHeight = max(0, viewportHeight)
      let rows = max(1, safeViewportHeight / safeCellHeight)
      let cols = max(1, safeViewportWidth / safeCellWidth)
      var size = LabanTerminalSize()
      size.rows = Self.clampedTerminalMetric(rows, minimum: 1)
      size.cols = Self.clampedTerminalMetric(cols, minimum: 1)
      size.pixel_width = Self.clampedTerminalMetric(safeViewportWidth)
      size.pixel_height = Self.clampedTerminalMetric(safeViewportHeight)
      size.cell_width = Self.clampedTerminalMetric(safeCellWidth, minimum: 1)
      size.cell_height = Self.clampedTerminalMetric(safeCellHeight, minimum: 1)
      currentSize = size
      for session in sessions.values {
        if session.resize(size) == 0 {
          var event = CaptureTimelineEvent(kind: .sessionResized, sessionId: session.id)
          event.rows = Int(size.rows)
          event.cols = Int(size.cols)
          event.pixelWidth = safeViewportWidth
          event.pixelHeight = safeViewportHeight
          event.cellWidth = safeCellWidth
          event.cellHeight = safeCellHeight
          captureSink?.record(event)
        }
      }
    }
  }

  private static func clampedTerminalMetric(_ value: Int, minimum: Int = 0) -> Int32 {
    Int32(max(minimum, min(value, Int(Int32.max))))
  }

  /// Subscribe to OSC 21337 tab-status pushes from the session and fold
  /// them into the matching tab's metadata. Per the iTerm2 spec, each
  /// field is preserved when the update doesn't mention it (nil), cleared
  /// when an empty value comes through, or set otherwise.
  private func attachTabStatus(session: Session, tabId: Tab.ID) {
    session.onTabStatus = { [weak self] update in
      self?.applyTabStatusUpdate(update, forTab: tabId)
    }
  }

  private func applyTabStatusUpdate(_ update: Session.TabStatusUpdate, forTab tabId: Tab.ID) {
    withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return }
      var status = _tabs[idx].titleMetadata.agentStatus
      let before = status

      if let v = update.indicator {
        status.indicatorColor = v.isEmpty ? nil : v
      }
      if let v = update.status {
        status.statusText = v.isEmpty ? nil : v
      }
      if let v = update.statusColor {
        status.statusTextColor = v.isEmpty ? nil : v
      }

      guard status != before else { return }
      _tabs[idx].titleMetadata.agentStatus = status
    }
  }

  /// Completion target for `gitInfo.refresh`. Writes the resolved branch into
  /// the tab's workspace metadata only when the tab's cwd still matches the
  /// cwd that was queried — avoids a stale background result clobbering a
  /// fresh `cd` that happened mid-flight.
  private func applyResolvedBranch(_ branch: String?, forTab tabId: Tab.ID, cwd: String) {
    withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return }
      guard _tabs[idx].titleMetadata.workspace.cwd == cwd else { return }
      guard _tabs[idx].titleMetadata.workspace.branch != branch else { return }
      _tabs[idx].titleMetadata.workspace.branch = branch
      resolveTitle(at: idx)
    }
  }

  private func resolveTitle(at idx: Int) {
    _tabs[idx].titleMetadata = TabTitleResolver.resolvedMetadata(
      _tabs[idx].titleMetadata,
      fallbackPosition: _tabs[idx].position
    )
  }

  public func allSessions() -> [(tab: Tab, session: Session)] {
    withModelLock {
      _tabs.compactMap { tab in
        guard let session = sessions[tab.sessionId] else { return nil }
        return (tab, session)
      }
    }
  }

  public func recordExistingStateForCapture() {
    withModelLock {
      captureSink?.record(CaptureTimelineEvent(kind: .appState))
      for tab in _tabs {
        recordSessionCreated(sessionId: tab.sessionId, tabId: tab.id)
        recordTab(.tabCreated, tabId: tab.id, sessionId: tab.sessionId)
        if tab.isActive {
          recordTab(.tabSelected, tabId: tab.id, sessionId: tab.sessionId)
        }
      }
    }
  }

  private func recordSessionCreated(sessionId: Session.ID, tabId: Tab.ID) {
    captureSink?.record(
      CaptureTimelineEvent(kind: .sessionCreated, tabId: tabId, sessionId: sessionId))
  }

  private func recordTab(_ kind: CaptureEventKind, tabId: Tab.ID, sessionId: Session.ID) {
    captureSink?.record(CaptureTimelineEvent(kind: kind, tabId: tabId, sessionId: sessionId))
  }

  private func setTerminalTitle(_ title: String?, forTab tabId: Tab.ID, at idx: Int) {
    _tabs[idx].titleMetadata.terminalTitle = title
    if title != nil, let owner = processIdentityByTab[tabId] {
      terminalTitleOwnerByTab[tabId] = owner
    } else {
      terminalTitleOwnerByTab.removeValue(forKey: tabId)
    }
  }
}

@usableFromInline
func defaultSize() -> LabanTerminalSize {
  var s = LabanTerminalSize()
  s.rows = 24
  s.cols = 80
  return s
}
