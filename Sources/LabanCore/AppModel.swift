import Foundation
import LabanRenderer
import LabanTerminalCore

public final class AppModel {
  public static let maxTabs = 9

  private let modelLock = NSRecursiveLock()
  private var _tabs: [Tab] = []
  public var tabs: [Tab] { withModelLock { _tabs } }
  private let sessionRegistry = SessionRegistry()
  private var findStateBySession: [Session.ID: TerminalFindState] = [:]
  private var findFullSearchCacheBySession: [Session.ID: FindFullSearchCache] = [:]
  private let metadataSync = TabMetadataSynchronizer()
  private var currentSize: LabanTerminalSize
  private let sessionFactory: (LabanTerminalSize) throws -> Session
  private var themeChangeObserver: NSObjectProtocol?

  private struct FindFullSearchCache {
    var needle: String
    var totalRows: Int
    var matches: [TerminalFindMatch]
  }

  /// Set by the AppKit view to receive "this session has new bytes
  /// to render" wake-ups from the per-session reader threads. The
  /// callback fires on a background thread and must be cheap and
  /// non-blocking — typically a coalesced `DispatchQueue.main.async`
  /// post that kicks the display link.
  public var onSessionDirty: (@Sendable (Session.ID) -> Void)? {
    didSet {
      withModelLock {
        sessionRegistry.onSessionDirty = onSessionDirty
      }
    }
  }
  public weak var captureSink: CaptureSink? {
    didSet {
      withModelLock {
        sessionRegistry.captureSink = captureSink
      }
    }
  }

  @discardableResult
  private func withModelLock<T>(_ body: () throws -> T) rethrows -> T {
    modelLock.lock()
    defer { modelLock.unlock() }
    return try body()
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
    ThemePaletteInjector.injectCurrentTheme(into: session)
    let tab = Tab(
      id: UUID().uuidString,
      position: 1,
      title: "Tab 1",
      isActive: true,
      sessionId: session.id
    )
    sessionRegistry.captureSink = captureSink
    sessionRegistry.onSessionDirty = onSessionDirty
    sessionRegistry.add(session)
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
        self.sessionRegistry.forEachSession { session in
          ThemePaletteInjector.injectCurrentTheme(into: session)
        }
      }
    }
  }

  deinit {
    if let themeChangeObserver {
      NotificationCenter.default.removeObserver(themeChangeObserver)
    }
    closeAllSessionsUnlocked()
  }

  /// Stop every session reader before closing its C session handle.
  /// Callers that replace or tear down the whole model must use this instead
  /// of closing sessions directly; the C destructor requires exclusive access.
  public func closeAllSessions() {
    withModelLock {
      closeAllSessionsUnlocked()
    }
  }

  private func closeAllSessionsUnlocked() {
    let closedCwds = _tabs.compactMap { $0.titleMetadata.workspace.cwd }
    sessionRegistry.closeAll()
    _tabs.removeAll()
    findStateBySession.removeAll()
    findFullSearchCacheBySession.removeAll()
    metadataSync.reset(closedCwds: closedCwds)
  }

  public var activeTab: Tab? { withModelLock { _tabs.first(where: { $0.isActive }) } }

  public func session(forTab tabId: Tab.ID) -> Session? {
    withModelLock {
      guard let tab = _tabs.first(where: { $0.id == tabId }) else { return nil }
      return sessionRegistry.session(id: tab.sessionId)
    }
  }

  public func session(forSessionID sessionID: Session.ID) -> Session? {
    withModelLock {
      sessionRegistry.session(id: sessionID)
    }
  }

  public func findState(forSession sessionID: Session.ID) -> TerminalFindState {
    withModelLock {
      findStateBySession[sessionID] ?? .inactive
    }
  }

  public var allFindStates: [Session.ID: TerminalFindState] {
    withModelLock { findStateBySession }
  }

  @discardableResult
  public func startFind(sessionID: Session.ID, needle: String = "") -> TerminalFindState? {
    withModelLock {
      guard let session = sessionRegistry.session(id: sessionID) else { return nil }
      let viewport = session.viewportState()
      var state = TerminalFindState(
        isActive: true,
        needle: needle,
        matches: [],
        selectedIndex: nil,
        viewportScrollOffsetAtStart: viewport?.viewportOffset,
        viewportRowsAtStart: viewport?.viewportRows
      )
      findStateBySession[sessionID] = state
      findFullSearchCacheBySession.removeValue(forKey: sessionID)
      if !needle.isEmpty {
        state = refreshFindFullUnlocked(sessionID: sessionID, preserving: nil) ?? state
      }
      return state
    }
  }

  @discardableResult
  public func updateFindNeedle(
    sessionID: Session.ID,
    needle: String,
    scrollSelectedIntoView: Bool = false
  ) -> TerminalFindState? {
    withModelLock {
      guard let session = sessionRegistry.session(id: sessionID) else { return nil }
      if findStateBySession[sessionID]?.isActive != true {
        let viewport = session.viewportState()
        findStateBySession[sessionID] = TerminalFindState(
          isActive: true,
          needle: needle,
          matches: [],
          selectedIndex: nil,
          viewportScrollOffsetAtStart: viewport?.viewportOffset,
          viewportRowsAtStart: viewport?.viewportRows
        )
        findFullSearchCacheBySession.removeValue(forKey: sessionID)
      } else {
        if findStateBySession[sessionID]?.needle != needle {
          findFullSearchCacheBySession.removeValue(forKey: sessionID)
        }
        findStateBySession[sessionID]?.needle = needle
      }
      let refreshed = refreshFindFullUnlocked(sessionID: sessionID, preserving: nil)
      if scrollSelectedIntoView {
        scrollSelectedFindMatchIntoViewUnlocked(sessionID: sessionID)
        return findStateBySession[sessionID] ?? refreshed
      }
      return refreshed
    }
  }

  @discardableResult
  public func setFindNeedlePending(sessionID: Session.ID, needle: String) -> TerminalFindState? {
    withModelLock {
      guard let session = sessionRegistry.session(id: sessionID) else { return nil }
      if findStateBySession[sessionID]?.isActive != true {
        let viewport = session.viewportState()
        findStateBySession[sessionID] = TerminalFindState(
          isActive: true,
          needle: needle,
          matches: [],
          selectedIndex: nil,
          viewportScrollOffsetAtStart: viewport?.viewportOffset,
          viewportRowsAtStart: viewport?.viewportRows
        )
        findFullSearchCacheBySession.removeValue(forKey: sessionID)
      } else {
        if findStateBySession[sessionID]?.needle != needle {
          findFullSearchCacheBySession.removeValue(forKey: sessionID)
        }
        findStateBySession[sessionID]?.needle = needle
        findStateBySession[sessionID]?.matches = []
        findStateBySession[sessionID]?.selectedIndex = nil
      }
      return findStateBySession[sessionID]
    }
  }

  @discardableResult
  public func stepFind(
    sessionID: Session.ID,
    direction: TerminalFindDirection
  ) -> TerminalFindState? {
    withModelLock {
      guard findStateBySession[sessionID]?.isActive == true else { return nil }
      _ = refreshFindFullUnlocked(sessionID: sessionID)
      guard var state = findStateBySession[sessionID] else { return nil }
      guard !state.matches.isEmpty else {
        state.selectedIndex = nil
        findStateBySession[sessionID] = state
        return state
      }

      let current = state.selectedIndex ?? (direction == .previous ? 0 : state.matches.count - 1)
      switch direction {
      case .next:
        state.selectedIndex = (current + 1) % state.matches.count
      case .previous:
        state.selectedIndex = (current - 1 + state.matches.count) % state.matches.count
      }
      findStateBySession[sessionID] = state
      scrollSelectedFindMatchIntoViewUnlocked(sessionID: sessionID)
      return findStateBySession[sessionID] ?? state
    }
  }

  @discardableResult
  public func stopFind(sessionID: Session.ID) -> TerminalFindState? {
    withModelLock {
      guard let state = findStateBySession[sessionID], state.isActive else {
        findStateBySession[sessionID] = .inactive
        return .inactive
      }
      if let session = sessionRegistry.session(id: sessionID),
        let savedOffset = state.viewportScrollOffsetAtStart,
        let savedRows = state.viewportRowsAtStart,
        let viewport = session.viewportState(),
        viewport.viewportRows == savedRows
      {
        let delta = savedOffset - viewport.viewportOffset
        if delta != 0 {
          _ = session.scrollViewport(deltaRows: delta)
        }
      }
      findStateBySession[sessionID] = .inactive
      findFullSearchCacheBySession.removeValue(forKey: sessionID)
      return .inactive
    }
  }

  public func refreshFindVisible(
    sessionID: Session.ID,
    snapshot: UnsafePointer<LabanSnapshot>,
    viewportOffset: Int
  ) {
    withModelLock {
      guard var state = findStateBySession[sessionID], state.isActive else { return }
      guard !state.needle.isEmpty else {
        state.matches = []
        state.selectedIndex = nil
        findStateBySession[sessionID] = state
        return
      }

      let previousSelected = state.selectedMatch
      let rows = Int(snapshot.pointee.rows)
      let visibleEnd = viewportOffset + rows
      let visibleMatches = TerminalFind.search(
        needle: state.needle,
        inSnapshot: snapshot,
        rowOffset: viewportOffset
      )
      let preserved = state.matches.filter { match in
        match.row < viewportOffset || match.row >= visibleEnd
      }
      state.matches = (preserved + visibleMatches).sorted(by: Self.findMatchSort)
      state.selectedIndex = Self.findSelectedIndex(
        preserving: previousSelected,
        preferredIndex: state.selectedIndex,
        in: state.matches
      )
      findStateBySession[sessionID] = state
    }
  }

  @discardableResult
  public func createTab() throws -> Tab {
    try withModelLock {
      guard _tabs.count < AppModel.maxTabs else { throw AppError.tabLimitReached }
      let session = try sessionFactory(currentSize)
      session.captureSink = captureSink
      AppModel.maybeAutoCapture(session)
      ThemePaletteInjector.injectCurrentTheme(into: session)
      let position = _tabs.count + 1
      let tab = Tab(
        id: UUID().uuidString,
        position: position,
        title: "Tab \(position)",
        isActive: false,
        sessionId: session.id
      )
      sessionRegistry.add(session)
      _tabs.append(tab)
      attachTabStatus(session: session, tabId: tab.id)
      recordSessionCreated(sessionId: session.id, tabId: tab.id)
      recordTab(.tabCreated, tabId: tab.id, sessionId: session.id)
      selectTabUnlocked(tab.id)
      return _tabs.last!
    }
  }

  public func selectTab(_ tabId: Tab.ID) {
    withModelLock {
      selectTabUnlocked(tabId)
    }
  }

  private func selectTabUnlocked(_ tabId: Tab.ID) {
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

  public func closeTab(_ tabId: Tab.ID) throws {
    try withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      let tab = _tabs[idx]

      if _tabs.count == 1 {
        sessionRegistry.close(sessionId: tab.sessionId)
        findStateBySession.removeValue(forKey: tab.sessionId)
        findFullSearchCacheBySession.removeValue(forKey: tab.sessionId)
        metadataSync.forget(tab: tab)
        _tabs = []
        recordTab(.tabClosed, tabId: tab.id, sessionId: tab.sessionId)
        throw AppError.lastTabClosed
      }

      // Determine next active tab before removing
      let wasActive = tab.isActive
      sessionRegistry.close(sessionId: tab.sessionId)
      findStateBySession.removeValue(forKey: tab.sessionId)
      findFullSearchCacheBySession.removeValue(forKey: tab.sessionId)
      metadataSync.forget(tab: tab)
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
        _tabs[idx].titleMetadata.userTitle = nil
        _tabs[idx].titleMetadata.titleFrozen = false
        resolveTitle(at: idx)
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
      metadataSync.syncTitle(forTab: tabId, from: session, tabs: &_tabs)
    }
  }

  @discardableResult
  public func syncProcessMetadata(
    forTab tabId: Tab.ID,
    from session: Session,
    now: Date = Date()
  ) -> Bool {
    withModelLock {
      metadataSync.syncProcessMetadata(
        forTab: tabId,
        from: session,
        now: now,
        tabs: &_tabs,
        onBranchResolved: { [weak self] branch, tabId, cwd in
          self?.applyResolvedBranch(branch, forTab: tabId, cwd: cwd)
        }
      )
    }
  }

  @discardableResult
  func applyProcessMetadata(
    _ metadata: Session.ProcessMetadata,
    forTab tabId: Tab.ID,
    now: Date = Date()
  ) -> Bool {
    withModelLock {
      metadataSync.applyProcessMetadata(
        metadata,
        forTab: tabId,
        now: now,
        tabs: &_tabs,
        onBranchResolved: { [weak self] branch, tabId, cwd in
          self?.applyResolvedBranch(branch, forTab: tabId, cwd: cwd)
        }
      )
    }
  }

  /// Read exit state from the session and record it in the tab.
  /// Exit state is monotonic: once a tab is non-running, this is a no-op.
  /// Returns true if the tab status changed.
  @discardableResult
  public func syncExitState(forTab tabId: Tab.ID, from session: Session) -> Bool {
    withModelLock {
      metadataSync.syncExitState(forTab: tabId, from: session, tabs: &_tabs)
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
      if let tab = _tabs.first(where: { $0.id == tabId }) {
        findFullSearchCacheBySession.removeValue(forKey: tab.sessionId)
      }
      return metadataSync.noteOutput(forTab: tabId, at: date, tabs: &_tabs)
    }
  }

  /// The display title for the AppKit window: active tab title, or "Laban" as fallback.
  public var windowTitle: String {
    withModelLock {
      guard let title = _tabs.first(where: { $0.isActive })?.title, !title.isEmpty else {
        return "Laban"
      }
      return title
    }
  }

  /// If `LABAN_CAPTURE_DIR` is set, start a fresh PTY-byte capture for this
  /// session into `<dir>/session-<id>-<timestamp>.bin`. Capture begins
  /// before theme palette injection so the OSC palette injection — which
  /// sets the default colors that subsequent rendering depends on — is
  /// recorded alongside the rest of the byte stream.
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
      sessionRegistry.forEachSession { session in
        if session.resize(size) == 0 {
          var event = CaptureTimelineEvent(kind: .sessionResized, sessionId: session.id)
          event.rows = Int(size.rows)
          event.cols = Int(size.cols)
          event.pixelWidth = safeViewportWidth
          event.pixelHeight = safeViewportHeight
          event.cellWidth = safeCellWidth
          event.cellHeight = safeCellHeight
          captureSink?.record(event)
          if findStateBySession[session.id]?.isActive == true {
            findFullSearchCacheBySession.removeValue(forKey: session.id)
            _ = refreshFindFullUnlocked(sessionID: session.id)
          }
        }
      }
    }
  }

  @discardableResult
  private func refreshFindFullUnlocked(
    sessionID: Session.ID,
    preserving explicitPrevious: TerminalFindMatch? = nil
  ) -> TerminalFindState? {
    guard var state = findStateBySession[sessionID],
      state.isActive,
      let session = sessionRegistry.session(id: sessionID)
    else { return nil }

    let previousSelected = explicitPrevious ?? state.selectedMatch
    guard !state.needle.isEmpty else {
      state.matches = []
      state.selectedIndex = nil
      findStateBySession[sessionID] = state
      findFullSearchCacheBySession.removeValue(forKey: sessionID)
      return state
    }

    var needsMatchSort = true
    var fullSearchCacheKey: (needle: String, totalRows: Int)?
    if let viewport = session.viewportState(),
      viewport.totalRows > 0
    {
      if let cache = findFullSearchCacheBySession[sessionID],
        cache.needle == state.needle,
        cache.totalRows == viewport.totalRows
      {
        state.matches = cache.matches
        needsMatchSort = false
      } else if let scrollback = session.scrollbackBlock(rowOffset: 0, maxRows: viewport.totalRows),
        scrollback.rows > 0
      {
        state.matches = TerminalFind.search(needle: state.needle, in: scrollback)
        fullSearchCacheKey = (state.needle, viewport.totalRows)
      } else if let snapshot = session.snapshot() {
        defer { laban_snapshot_destroy(snapshot) }
        state.matches = TerminalFind.search(
          needle: state.needle,
          inSnapshot: UnsafePointer(snapshot),
          rowOffset: viewport.viewportOffset
        )
      } else {
        state.matches = []
      }
    } else if let snapshot = session.snapshot() {
      defer { laban_snapshot_destroy(snapshot) }
      let rowOffset = session.viewportState()?.viewportOffset ?? 0
      state.matches = TerminalFind.search(
        needle: state.needle,
        inSnapshot: UnsafePointer(snapshot),
        rowOffset: rowOffset
      )
    } else {
      state.matches = []
    }

    if needsMatchSort {
      state.matches.sort(by: Self.findMatchSort)
    }
    if let fullSearchCacheKey {
      findFullSearchCacheBySession[sessionID] = FindFullSearchCache(
        needle: fullSearchCacheKey.needle,
        totalRows: fullSearchCacheKey.totalRows,
        matches: state.matches
      )
    }
    state.selectedIndex = Self.findSelectedIndex(
      preserving: previousSelected,
      preferredIndex: state.selectedIndex,
      in: state.matches
    )
    findStateBySession[sessionID] = state
    return state
  }

  private func scrollSelectedFindMatchIntoViewUnlocked(sessionID: Session.ID) {
    guard let session = sessionRegistry.session(id: sessionID),
      var state = findStateBySession[sessionID],
      let match = state.selectedMatch,
      let viewport = session.viewportState()
    else { return }

    let visibleStart = viewport.viewportOffset
    let visibleEnd = visibleStart + viewport.viewportRows
    guard match.row < visibleStart || match.row >= visibleEnd else { return }

    let maxOffset = max(0, viewport.totalRows - viewport.viewportRows)
    let anchorRow = max(0, viewport.viewportRows / 3)
    let targetOffset = min(max(0, match.row - anchorRow), maxOffset)
    let delta = targetOffset - viewport.viewportOffset
    guard delta != 0 else { return }
    _ = session.scrollViewport(deltaRows: delta)
    if let selected = state.matches.firstIndex(of: match) {
      state.selectedIndex = selected
      findStateBySession[sessionID] = state
    }
  }

  private static func findMatchSort(_ lhs: TerminalFindMatch, _ rhs: TerminalFindMatch) -> Bool {
    if lhs.row != rhs.row { return lhs.row < rhs.row }
    if lhs.startColumn != rhs.startColumn { return lhs.startColumn < rhs.startColumn }
    return lhs.endColumn < rhs.endColumn
  }

  private static func findSelectedIndex(
    preserving previous: TerminalFindMatch?,
    preferredIndex: Int?,
    in matches: [TerminalFindMatch]
  ) -> Int? {
    guard !matches.isEmpty else { return nil }
    if let previous {
      if let exact = matches.firstIndex(of: previous) {
        return exact
      }
      return matches.indices.min { lhs, rhs in
        let l = findDistance(matches[lhs], from: previous)
        let r = findDistance(matches[rhs], from: previous)
        if l != r { return l < r }
        return lhs < rhs
      }
    }
    if let preferredIndex, matches.indices.contains(preferredIndex) {
      return preferredIndex
    }
    return 0
  }

  private static func findDistance(
    _ match: TerminalFindMatch,
    from previous: TerminalFindMatch
  ) -> Int {
    abs(match.row - previous.row) * 10_000 + abs(match.startColumn - previous.startColumn)
  }

  private static func clampedTerminalMetric(_ value: Int, minimum: Int = 0) -> Int32 {
    Int32(max(minimum, min(value, Int(Int32.max))))
  }

  /// Subscribe to OSC 21337 tab-status pushes from the session and fold
  /// them into the matching tab's metadata. Per the iTerm2 spec, each
  /// field is preserved when the update doesn't mention it (nil), cleared
  /// when an empty value comes through, or set otherwise.
  private func attachTabStatus(session: Session, tabId: Tab.ID) {
    // The C tab-status callback fires from whichever thread drove the VT parser
    // -- historically the main thread, now the per-session reader thread. The C
    // session lock is held while the callback runs. If the handler synchronously
    // took `modelLock`, an inversion against any path that holds `modelLock` and
    // then calls a session method (e.g. `advanceFrame`'s `session.snapshot()`)
    // would deadlock. Punting the model mutation onto the main queue keeps the
    // reader thread holding exactly one lock at a time.
    session.onTabStatus = { [weak self] update in
      DispatchQueue.main.async { [weak self] in
        self?.applyTabStatusUpdate(update, forTab: tabId)
      }
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

  /// Completion target for `TabMetadataSynchronizer` git refresh. Writes the resolved branch into
  /// the tab's workspace metadata only when the tab's cwd still matches the
  /// cwd that was queried — avoids a stale background result clobbering a
  /// fresh `cd` that happened mid-flight.
  private func applyResolvedBranch(_ branch: String?, forTab tabId: Tab.ID, cwd: String) {
    withModelLock {
      _ = metadataSync.applyResolvedBranch(branch, forTab: tabId, cwd: cwd, tabs: &_tabs)
    }
  }

  private func resolveTitle(at idx: Int) {
    TabMetadataSynchronizer.resolveTitle(in: &_tabs, at: idx)
  }

  public func allSessions() -> [(tab: Tab, session: Session)] {
    withModelLock {
      sessionRegistry.tabSessions(for: _tabs)
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
    metadataSync.setTerminalTitle(title, forTab: tabId, at: idx, tabs: &_tabs)
  }
}

@usableFromInline
func defaultSize() -> LabanTerminalSize {
  var s = LabanTerminalSize()
  s.rows = 24
  s.cols = 80
  return s
}
