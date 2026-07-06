import Foundation
import LabanRenderer
import LabanTerminalCore

struct AppModelSurfaceSession {
  var tabId: Tab.ID
  var tabIndex: Int
  var session: Session
}

struct AppModelSurfaceSessionSnapshot {
  var activeTabId: Tab.ID?
  var activeSessionId: Session.ID?
  var tabSessions: [AppModelSurfaceSession]
}

struct AppModelSurfaceMetadataSyncResult {
  var modelChanged: Bool
  var titleChangeEvent: CaptureTimelineEvent?
}

public final class AppModel {
  private let modelLock = NSRecursiveLock()
  private var _tabs: [Tab] = []
  public var tabs: [Tab] { withModelLock { _tabs } }
  private let sessionRegistry = SessionRegistry()
  private var findStateBySession: [Session.ID: TerminalFindState] = [:]
  private var findFullSearchCacheBySession: [Session.ID: FindFullSearchCache] = [:]
  // Sessions whose active find needs a full scrollback rescan deferred from a
  // live resize drag; flushed by refreshActiveFindsAfterResize on settle. (H-5)
  private var pendingFindRescanSessions: Set<Session.ID> = []
  private let metadataSync = TabMetadataSynchronizer()
  private var currentSize: LabanTerminalSize
  private let sessionFactory: (LabanTerminalSize, SessionLaunchContext) throws -> Session
  /// Supplies preallocated session identity and control env before each spawn (C11).
  public var sessionLaunchContextProvider: ((Tab.ID?, Bool) -> SessionLaunchContext)?

  /// Current grid size in cells (cols, rows). Read under the model
  /// lock so callers see a stable size even mid-resize.
  public var terminalSize: LabanTerminalSize {
    withModelLock { currentSize }
  }
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

  /// Always-on journal of what each tab visibly showed over time. Fed by the
  /// notify funnels (see `recordTabJournal`), queryable via
  /// `GET /debug/tab-journal`, dumpable from the Debug menu, and mirrored into
  /// capture timelines as `tab.metadata` events.
  public let tabJournal = TabStateJournal()

  private static let attentionDecisionCapacity = 128
  private var attentionNotificationDecisions: [AttentionNotificationDecision] = []

  public var recentAttentionNotificationDecisions: [AttentionNotificationDecision] {
    withModelLock { attentionNotificationDecisions }
  }

  /// Fires after every workspace mutation (tab add/remove/reorder, tab
  /// select, cwd update) so the persistence coordinator can debounce a
  /// save. The callback runs on the calling thread under no lock;
  /// implementers should not call back into the model synchronously.
  /// Set by `PersistenceCoordinator.attach(_:)` in normal operation.
  public var onWorkspaceMutation: (() -> Void)?

  /// Fires after any model mutation that can change rendered pixels — tab
  /// open/close/reorder/select (every `notifyWorkspaceMutation` site),
  /// background git-branch resolution (`applyResolvedBranch`), daemon surface
  /// signals (`applySurfaceSignals`), and agent-status updates
  /// (`applyTabStatusUpdate`). The AppKit view subscribes this through its
  /// display-kick coalescer so a fully parked display link still produces a
  /// frame for model-only changes; mutations that arrive as terminal bytes are
  /// additionally covered by `onSessionDirty`. Deliberately separate from
  /// `onWorkspaceMutation`, which is single-cast and owned by
  /// `PersistenceCoordinator.attach(_:)`. Runs on the mutating thread outside
  /// the model lock; implementations MUST be cheap, non-blocking, and must not
  /// call back into the model synchronously.
  public var onSurfaceStateChanged: (@Sendable () -> Void)?

  /// Fires after every successful tab creation (default, fresh, or
  /// restored). Lets LabanApp wire up per-tab subsystems like the
  /// agent-session detector that depend on a real shell PID.
  public var onTabCreated: ((Tab.ID, Session) -> Void)?

  /// Fires after every tab close so per-tab subsystems can tear down.
  public var onTabClosed: ((Tab.ID) -> Void)?

  /// Fires after each OSC 133 shell-integration transition for a tab, with
  /// the post-reduction `ShellIntegrationState`. Always dispatched to the
  /// main queue. Lets hosts react to prompt/command/exit changes — the
  /// debug runtime records them as events, and the AppKit UI (later
  /// milestone) drives a per-tab status indicator. Single broadcast point so
  /// `Session.onShellIntegration` stays owned by AppModel.
  public var onShellIntegrationChange: ((Tab.ID, ShellIntegrationState) -> Void)?

  /// Broadcast when a tab enters a user-visible attention state that may be
  /// eligible for a native notification. Always dispatched to the main queue.
  /// Hosts decide delivery policy; AppModel owns the tab metadata changes.
  public var onAttentionNotification: ((AttentionNotificationEvent) -> Void)?

  /// Compatibility hook for older tests/debug surfaces that only observe
  /// urgent OSC notifications. New code should use `onAttentionNotification`.
  public var onAgentNotification: ((Tab.ID, String) -> Void)?

  /// Compatibility hook for older tests that only observe BEL attention. New
  /// code should use `onAttentionNotification`.
  public var onBellAttention: ((Tab.ID, String) -> Void)?

  /// Host-provided check for "is the user looking at this tab right now"
  /// (AppKit: app active AND tab selected — the same closure the banner
  /// poster uses for suppression). The synthetic awaiting-input attention
  /// (see `detectAwaitMarkerTransitions`) skips tabs the user is watching;
  /// nil means "never attended" (headless), so detection always raises.
  public var isTabFrontmost: ((Tab.ID) -> Bool)?

  /// Broadcast when a tab's program copies to the clipboard via OSC 52
  /// (`ESC ] 52 ; c ; <base64> ST`) — e.g. a coding agent reached over SSH,
  /// where the native clipboard is unreachable. Dispatched to the main queue
  /// with the originating tab and the already base64-decoded bytes. The AppKit
  /// host writes `NSPasteboard`; the debug runtime records it. Single broadcast
  /// point so `Session.onClipboardWrite` stays owned by AppModel.
  public var onClipboardWrite: ((Tab.ID, Data) -> Void)?

  /// Supplies the current host clipboard bytes when a tab's program issues an
  /// OSC 52 *read* query (`ESC ] 52 ; c ; ? ST`). Invoked on the main queue;
  /// return nil for "no/empty clipboard". The AppKit host reads `NSPasteboard`;
  /// the debug runtime returns its debug clipboard. Only consulted when
  /// `osc52ReadEnabled` is true (read is off by default — see that flag).
  public var clipboardReadProvider: (() -> Data?)?

  /// Whether sessions answer OSC 52 read queries. Default false: copy-from-a-
  /// remote-program (write) works unconditionally, but a read query is dropped
  /// with no reply unless the host opts in, so a remote process cannot pull the
  /// host clipboard unasked. Applied to each session as it is attached.
  public var osc52ReadEnabled: Bool = false

  /// Broadcast when a tab's shell reports its working directory via OSC 7.
  /// Dispatched to the main queue with the tab and the decoded absolute path.
  /// The cwd is already adopted as the session's authoritative directory (it
  /// flows through `processMetadata().cwd` into `titleMetadata.workspace.cwd` on
  /// the next metadata sync); this hook is for observers that want it
  /// immediately — chiefly the debug event stream. Single broadcast point so
  /// `Session.onWorkingDirectory` stays owned by AppModel.
  public var onWorkingDirectoryChange: ((Tab.ID, String) -> Void)?

  /// Optional logger invoked for each tab that fails to spawn during
  /// `replaceTabs(from:)`. Production wires this to `AppLog` so
  /// restore failures don't disappear silently.
  public var restoreFailureLogger: ((Tab.ID, Error) -> Void)?

  /// Factory used by `replaceTabs(from:)` and `createRestoredTab(...)`
  /// to spawn a session pinned to a specific cwd. When nil, restored
  /// tabs fall back to the default `sessionFactory` and the persisted
  /// cwd is recorded into the launch_cwd path passed to the C layer but
  /// otherwise ignored — useful for headless tests where every session
  /// is a fixture. Production wires this to a wrapper around
  /// `Session.realShell(size:, cwd:)`.
  public var restoredSessionFactory: ((LabanTerminalSize, String, SessionLaunchContext) throws -> Session)?

  /// Factory for a brand-new (⌘T) tab spawned in an explicit cwd — the active
  /// tab's working directory — so a new tab opens where you currently are
  /// rather than at the launcher's directory. The cwd is the active tab's
  /// reported directory: its OSC 7 / metadata-synced `workspace.cwd`, else its
  /// live process cwd. When this is nil, or no cwd resolves, or the cwd no
  /// longer exists, `createTab` falls back to the default `sessionFactory`
  /// (the prior behavior). Production wires this to `Session.realShell(size:,
  /// cwd:)`; headless tests leave it nil unless exercising inheritance.
  public var newTabSessionFactory: ((LabanTerminalSize, String, SessionLaunchContext) throws -> Session)?

  /// Factory for a tab that runs a caller-supplied argv (argv[0] is the
  /// executable) instead of the login shell — the "run argv in a new tab"
  /// path, e.g. an `ssh://` URL handler. Mirrors `newTabSessionFactory` but
  /// takes the argv and an optional cwd. Production wires it to
  /// `Session.realShell(..., launchArgv: argv)` for the in-process backend;
  /// for the daemon backends the returned session is parser-only and the
  /// daemon launches `argv`, which it reads back via `launchArgv(forTab:)`.
  /// When nil, `createTab(runningArgv:)` falls back to the default factory.
  public var commandSessionFactory: ((LabanTerminalSize, String?, [String], SessionLaunchContext) throws -> Session)?

  /// Richer restore-time factory. When set, takes precedence over
  /// `restoredSessionFactory`. The spec carries enough state for the
  /// factory to construct a deferred-spawn Session, replay the
  /// persisted transcript into it, then start the shell — see
  /// `TranscriptRenderer` and `Session.makeDeferred(...)`. Production
  /// wires this in `MainWindowController.makeAndShow(...)`.
  public var restoredDeferredSessionFactory: ((RestoredSessionSpec) throws -> Session)?

  /// Per-tab transcript writer registry. AppModel notifies the
  /// delegate on tab creation/close so the delegate can attach a
  /// `TranscriptWriter` to each session's PTY-byte tee. Weak so a
  /// host owned by `MainWindowController` can outlive intermediate
  /// AppModel teardowns without retain cycles.
  public weak var transcriptDelegate: TranscriptHostDelegate?

  /// Recorded as `launchCommand` in `WorkspaceState` for tabs that were
  /// not themselves restored from state. Defaults to the user's `SHELL`
  /// env var, falling back to `/bin/zsh`. Tabs restored from a prior
  /// `WorkspaceState` keep their persisted launch command.
  public var defaultLaunchCommand: String =
    (ProcessInfo.processInfo.environment["SHELL"].map { "\($0) -l" }) ?? "/bin/zsh -l"

  /// Optional launch command override per tab; used when a tab was
  /// created with an explicit launch command (restored tabs). Keyed by
  /// Tab.ID. Cleared on tab close.
  private var launchCommandByTab: [Tab.ID: String] = [:]

  /// Explicit launch argv for tabs created via `createTab(runningArgv:)`,
  /// keyed by Tab.ID. The daemon-backed coordinators read this through
  /// `launchArgv(forTab:)` to launch the requested command instead of the
  /// login shell. Cleared on tab close.
  private var launchArgvByTab: [Tab.ID: [String]] = [:]

  /// Most recent agent observation per tab, fed by the LabanApp-side
  /// `AgentSessionDetector`. Persisted into `TabState.agent` by
  /// `snapshotForPersistence(windowId:)`. Cleared on tab close.
  private var agentByTab: [Tab.ID: AgentInfo] = [:]

  /// True when the tab was restored with a cwd that no longer existed
  /// and we fell back to `$HOME`. Surfaced into
  /// `TabState.cwdFallbackApplied` so headless tests can assert the
  /// fallback was taken and the next save round-trips the flag.
  /// Cleared on tab close.
  private var cwdFallbackAppliedByTab: [Tab.ID: Bool] = [:]

  /// Update the captured agent state for a tab. Setting nil clears
  /// any previously captured state. Triggers a workspace mutation
  /// notification so the persistence coordinator records the change.
  public func updateAgent(_ agent: AgentInfo?, forTab tabId: Tab.ID) {
    let changed: Bool = withModelLock {
      guard _tabs.contains(where: { $0.id == tabId }) else {
        return agentByTab.removeValue(forKey: tabId) != nil
      }
      let prior = agentByTab[tabId]
      if prior == agent { return false }
      if let agent {
        agentByTab[tabId] = agent
      } else {
        agentByTab.removeValue(forKey: tabId)
      }
      return true
    }
    if changed { notifyWorkspaceMutation() }
  }

  /// Read the captured agent state for a tab. Returns nil when the
  /// tab does not exist or no agent has been detected.
  public func agent(forTab tabId: Tab.ID) -> AgentInfo? {
    withModelLock { agentByTab[tabId] }
  }

  @discardableResult
  private func withModelLock<T>(_ body: () throws -> T) rethrows -> T {
    modelLock.lock()
    defer { modelLock.unlock() }
    return try body()
  }

  public init(
    initialSize: LabanTerminalSize = defaultSize(),
    sessionLaunchContextProvider: ((Tab.ID?, Bool) -> SessionLaunchContext)? = nil,
    sessionFactory: @escaping (LabanTerminalSize, SessionLaunchContext) throws -> Session = { size, context in
      try Session.fixture(size: size, sessionID: context.sessionID)
    }
  ) throws {
    self.currentSize = initialSize
    self.sessionLaunchContextProvider = sessionLaunchContextProvider
    self.sessionFactory = sessionFactory
    let initialContext = sessionLaunchContextProvider?(nil, false) ?? .fresh()
    let session = try sessionFactory(initialSize, initialContext)
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
    attachSessionCallbacks(session: session, tabId: tab.id)
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

  /// Backward-compatible factory that ignores launch context (tests and tools).
  public convenience init(
    initialSize: LabanTerminalSize = defaultSize(),
    sessionFactory: @escaping (LabanTerminalSize) throws -> Session
  ) throws {
    try self.init(
      initialSize: initialSize,
      sessionFactory: { size, _ in try sessionFactory(size) })
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
    // Notify the transcript delegate BEFORE we tear down the session
    // registry, so the host can flush each writer's ring and detach
    // the C callback while the Session pointer is still valid.
    // Otherwise the host retains stale writers/bridges until its own
    // teardown — a real leak the M1 review flagged after restore
    // calls `closeAllSessionsUnlocked` to replace the default tab.
    if let transcriptDelegate {
      for tab in _tabs {
        let session = sessionRegistry.session(id: tab.sessionId)
        transcriptDelegate.detachTranscriptWriter(forTabId: tab.id, in: session)
      }
    }
    if let onTabClosed {
      for tab in _tabs { onTabClosed(tab.id) }
    }
    sessionRegistry.closeAll()
    _tabs.removeAll()
    findStateBySession.removeAll()
    findFullSearchCacheBySession.removeAll()
    launchCommandByTab.removeAll()
    agentByTab.removeAll()
    cwdFallbackAppliedByTab.removeAll()
    metadataSync.reset(closedCwds: closedCwds)
  }

  public var activeTab: Tab? { withModelLock { _tabs.first(where: { $0.isActive }) } }

  func surfaceSessionSnapshot() -> AppModelSurfaceSessionSnapshot {
    withModelLock {
      var activeTabId: Tab.ID?
      var activeSessionId: Session.ID?
      var tabSessions: [AppModelSurfaceSession] = []
      tabSessions.reserveCapacity(_tabs.count)
      for (idx, tab) in _tabs.enumerated() {
        if tab.isActive {
          activeTabId = tab.id
          activeSessionId = tab.sessionId
        }
        if let session = sessionRegistry.session(id: tab.sessionId) {
          tabSessions.append(
            AppModelSurfaceSession(tabId: tab.id, tabIndex: idx, session: session))
        }
      }
      return AppModelSurfaceSessionSnapshot(
        activeTabId: activeTabId,
        activeSessionId: activeSessionId,
        tabSessions: tabSessions
      )
    }
  }

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
      // Re-run the full find before navigating: refreshFindFullUnlocked reuses
      // the cached match set when it is still valid (cheap for an idle session)
      // and re-scans when output invalidated it, so next/prev reflects
      // newly-arrived matches. An earlier optimization that skipped this when
      // matches were already non-empty broke output-invalidation (see
      // testOutputInvalidatesCachedFullFindResults). Eliminating the re-scan
      // during *active streaming* (where totalRows changes every batch and the
      // cache can't help) needs an incremental match index — the open half of
      // M-6, not a stepFind change.
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

  /// Run the full scrollback find rescan deferred from a live resize drag
  /// (see `resize(deferFindRescan:)`). Called once on resize-settle. (H-5)
  public func refreshActiveFindsAfterResize() {
    withModelLock {
      let pending = pendingFindRescanSessions
      pendingFindRescanSessions.removeAll()
      for sessionID in pending where findStateBySession[sessionID]?.isActive == true {
        findFullSearchCacheBySession.removeValue(forKey: sessionID)
        _ = refreshFindFullUnlocked(sessionID: sessionID)
      }
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
    let (tab, session) = try withModelLock {
      () -> (Tab, Session) in
      let tabId = UUID().uuidString
      let launchContext = self.launchContext(tabId: tabId, isAgentAttached: false)
      // A new tab opens in the active tab's working directory when one is known
      // and a cwd-aware factory is wired; otherwise spawn at the default
      // location, exactly as before. `selectTabUnlocked` below moves activeness
      // to the new tab, so resolve the inherited cwd here, first.
      let session: Session
      if let inherited = resolveInheritedCwdUnlocked(), let factory = newTabSessionFactory {
        session = try factory(currentSize, resolveRestoredCwd(inherited).cwd, launchContext)
      } else {
        session = try sessionFactory(currentSize, launchContext)
      }
      session.captureSink = captureSink
      AppModel.maybeAutoCapture(session)
      ThemePaletteInjector.injectCurrentTheme(into: session)
      let position = _tabs.count + 1
      let tab = Tab(
        id: tabId,
        position: position,
        title: "Tab \(position)",
        isActive: false,
        sessionId: session.id
      )
      sessionRegistry.add(session)
      _tabs.append(tab)
      attachSessionCallbacks(session: session, tabId: tab.id)
      recordSessionCreated(sessionId: session.id, tabId: tab.id)
      recordTab(.tabCreated, tabId: tab.id, sessionId: session.id)
      selectTabUnlocked(tab.id)
      return (_tabs.last!, session)
    }
    transcriptDelegate?.attachTranscriptWriter(to: session, tabId: tab.id)
    onTabCreated?(tab.id, session)
    notifyWorkspaceMutation()
    return tab
  }

  @discardableResult
  public func createAgentAttachedTab() throws -> Tab {
    let (tab, session) = try withModelLock {
      () -> (Tab, Session) in
      let tabId = UUID().uuidString
      let launchContext = self.launchContext(tabId: tabId, isAgentAttached: true)
      let session = try sessionFactory(currentSize, launchContext)
      session.captureSink = captureSink
      AppModel.maybeAutoCapture(session)
      ThemePaletteInjector.injectCurrentTheme(into: session)
      let position = _tabs.count + 1
      let tab = Tab(
        id: tabId,
        position: position,
        title: "Tab \(position)",
        isActive: false,
        sessionId: session.id
      )
      sessionRegistry.add(session)
      _tabs.append(tab)
      attachSessionCallbacks(session: session, tabId: tab.id)
      recordSessionCreated(sessionId: session.id, tabId: tab.id)
      recordTab(.tabCreated, tabId: tab.id, sessionId: session.id)
      selectTabUnlocked(tab.id)
      return (_tabs.last!, session)
    }
    transcriptDelegate?.attachTranscriptWriter(to: session, tabId: tab.id)
    onTabCreated?(tab.id, session)
    notifyWorkspaceMutation()
    return tab
  }

  /// Create and select a new tab whose session runs `argv` (argv[0] is the
  /// executable) instead of the login shell — the "run argv in a new tab"
  /// entry point used by, e.g., an `ssh://` URL handler. In-process spawns the
  /// command directly via `commandSessionFactory`; for the daemon backends the
  /// local session is parser-only and the daemon launches `argv`, which the
  /// coordinator reads back through `launchArgv(forTab:)`. Falls back to a
  /// plain shell tab when `argv` is empty or no `commandSessionFactory` is set.
  @discardableResult
  public func createTab(runningArgv argv: [String], cwd: String? = nil) throws -> Tab {
    let (tab, session) = try withModelLock { () -> (Tab, Session) in
      let tabId = UUID().uuidString
      let launchContext = self.launchContext(tabId: tabId, isAgentAttached: false)
      let session: Session
      if !argv.isEmpty, let factory = commandSessionFactory {
        session = try factory(currentSize, cwd, argv, launchContext)
      } else if let cwd, let factory = newTabSessionFactory {
        session = try factory(currentSize, cwd, launchContext)
      } else {
        session = try sessionFactory(currentSize, launchContext)
      }
      session.captureSink = captureSink
      AppModel.maybeAutoCapture(session)
      ThemePaletteInjector.injectCurrentTheme(into: session)
      let position = _tabs.count + 1
      let tab = Tab(
        id: tabId,
        position: position,
        title: "Tab \(position)",
        isActive: false,
        sessionId: session.id
      )
      if !argv.isEmpty { launchArgvByTab[tab.id] = argv }
      sessionRegistry.add(session)
      _tabs.append(tab)
      attachSessionCallbacks(session: session, tabId: tab.id)
      recordSessionCreated(sessionId: session.id, tabId: tab.id)
      recordTab(.tabCreated, tabId: tab.id, sessionId: session.id)
      selectTabUnlocked(tab.id)
      return (_tabs.last!, session)
    }
    transcriptDelegate?.attachTranscriptWriter(to: session, tabId: tab.id)
    onTabCreated?(tab.id, session)
    notifyWorkspaceMutation()
    return tab
  }

  /// The explicit launch argv recorded for a tab created via
  /// `createTab(runningArgv:)`, or nil for an ordinary login-shell tab.
  public func launchArgv(forTab tabId: Tab.ID) -> [String]? {
    withModelLock { launchArgvByTab[tabId] }
  }

  /// Create a tab pinned to a specific working directory with a
  /// caller-supplied id and launch command. Used directly by tests
  /// that want to exercise restored-tab semantics without going
  /// through a full `WorkspaceState`. Production restore flows go
  /// through `replaceTabs(from:)`.
  @discardableResult
  public func createRestoredTab(
    id: Tab.ID,
    cwd: String,
    launchCommand: String,
    isActive: Bool
  ) throws -> Tab {
    let synthesizedState = TabState(
      id: id,
      cwd: cwd,
      launchCommand: launchCommand,
      lastActiveAt: Date()
    )
    let tab = try createRestoredTabSuppressingNotification(
      id: id,
      persistedTab: synthesizedState,
      isActive: isActive
    )
    notifyWorkspaceMutation()
    return tab
  }

  /// Replace the current tab set with one rebuilt from a persisted
  /// `WorkspaceState`. Closes every existing session before spawning
  /// the restored ones so the user never sees a flash of the default
  /// tab. Multi-window persistence is not implemented in M0; only the
  /// first window in `state.windows` is consumed.
  ///
  /// Per-tab restore goes through the deferred-spawn factory when one
  /// is set so production can start each fresh shell in the restored
  /// cwd. If the deferred factory is not set, falls back to the
  /// simple cwd-only factory used by tests.
  ///
  /// Mutation notifications are coalesced: one `onWorkspaceMutation`
  /// fires at the end, not per tab. This keeps the persistence
  /// coordinator from scheduling N debounced saves during restore.
  public func replaceTabs(from state: WorkspaceState) {
    guard let window = state.windows.first else { return }
    withModelLock {
      // Don't let restored agents' resume-time OSC 9 burst badge every tab.
      notificationSuppressionDeadline = Date().addingTimeInterval(restoreNotificationGraceSeconds)
      closeAllSessionsUnlocked()
    }
    for (index, persistedTab) in window.tabs.enumerated() {
      let isActive =
        (window.selectedTabId == persistedTab.id)
        || (window.selectedTabId == nil && index == 0)
      do {
        _ = try createRestoredTabSuppressingNotification(
          id: persistedTab.id,
          persistedTab: persistedTab,
          isActive: isActive
        )
      } catch {
        // A restored tab failed to spawn (tab cap hit, factory error,
        // etc.). Log but keep going so one bad tab doesn't take out
        // the whole workspace. Future work could materialize a
        // placeholder error tab here; for now the missing tab is
        // visible by its absence after relaunch.
        restoreFailureLogger?(persistedTab.id, error)
      }
    }
    notifyWorkspaceMutation()
  }

  /// Internal helper shared by `replaceTabs(from:)` so per-tab creation
  /// does not fire the mutation callback (the caller coalesces).
  ///
  /// Spawn-or-fallback ordering: when a `restoredDeferredSessionFactory`
  /// is set we use it (this is the production path and the one that
  /// gives the restore factory access to cwd and diagnostic
  /// transcript metadata). Otherwise we fall back to the older simple
  /// cwd-only `restoredSessionFactory` and finally to the default
  /// `sessionFactory` — useful for headless tests that work with
  /// fixture sessions.
  @discardableResult
  private func createRestoredTabSuppressingNotification(
    id: Tab.ID,
    persistedTab: TabState,
    isActive: Bool
  ) throws -> Tab {
    let resolved = resolveRestoredCwd(persistedTab.cwd)
    let (tab, session) = try withModelLock {
      () -> (Tab, Session) in
      let launchContext = self.launchContext(tabId: id, isAgentAttached: false)
      let session: Session
      if let deferredFactory = restoredDeferredSessionFactory {
        let spec = RestoredSessionSpec(
          size: currentSize,
          tabId: id,
          cwd: resolved.cwd,
          cwdFallbackApplied: resolved.fallbackApplied,
          transcriptURL: transcriptDelegate?.transcriptURL(forTabId: id),
          altBufferAtQuit: persistedTab.altBufferAtQuit ?? false,
          agent: persistedTab.agent,
          shellPid: persistedTab.shellPid
        )
        session = try deferredFactory(spec)
      } else if let factory = restoredSessionFactory {
        session = try factory(currentSize, resolved.cwd, launchContext)
      } else {
        session = try sessionFactory(currentSize, launchContext)
      }
      session.captureSink = captureSink
      AppModel.maybeAutoCapture(session)
      ThemePaletteInjector.injectCurrentTheme(into: session)
      let position = _tabs.count + 1
      let tab = Tab(
        id: id,
        position: position,
        title: "Tab \(position)",
        isActive: false,
        sessionId: session.id
      )
      sessionRegistry.add(session)
      _tabs.append(tab)
      launchCommandByTab[id] = persistedTab.launchCommand
      if let agent = persistedTab.agent {
        agentByTab[id] = agent
      }
      if resolved.fallbackApplied {
        _tabs[_tabs.count - 1].titleMetadata.workspace = TabWorkspaceMetadata(cwd: resolved.cwd)
        cwdFallbackAppliedByTab[id] = true
      }
      attachSessionCallbacks(session: session, tabId: tab.id)
      recordSessionCreated(sessionId: session.id, tabId: tab.id)
      recordTab(.tabCreated, tabId: tab.id, sessionId: session.id)
      if isActive {
        selectTabUnlocked(tab.id)
      }
      return (_tabs.last!, session)
    }
    // Restored tabs ask the delegate to suppress capture for ~500ms
    // so the new shell's spawn-time prompt sequences don't get
    // appended to the prior session's `.bin`. Without this, every
    // quit-restore cycle accumulates a stacked prompt block that
    // shows up in the next restore's scrollback.
    transcriptDelegate?.attachTranscriptWriter(
      to: session, tabId: id,
      suppressInitialOutputFor: .milliseconds(500))
    onTabCreated?(id, session)
    return tab
  }

  /// Resolve the cwd to use when restoring a tab. The persisted cwd may
  /// no longer exist (unmounted external drive, deleted directory); in
  /// that case we fall back to `$HOME` and report
  /// `fallbackApplied = true` so callers can persist the fact and
  /// (eventually) render a one-line banner. The default fallback is the
  /// user's home directory.
  private func resolveRestoredCwd(_ cwd: String) -> (cwd: String, fallbackApplied: Bool) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: cwd, isDirectory: &isDir),
      isDir.boolValue,
      fm.isReadableFile(atPath: cwd)
    {
      return (cwd, false)
    }
    return (fm.homeDirectoryForCurrentUser.path, true)
  }

  /// The active tab's working directory for new-tab inheritance, resolved the
  /// same way persistence resolves it: prefer the reported `workspace.cwd` (the
  /// OSC 7 / metadata-synced directory), then the live process cwd. Returns nil
  /// when nothing is known, so the new tab spawns at the default location.
  /// Assumes the model lock is held (reads `_tabs` and the session registry,
  /// matching `snapshotForPersistence`).
  private func resolveInheritedCwdUnlocked() -> String? {
    guard let active = _tabs.first(where: { $0.isActive }) else { return nil }
    if let cached = active.titleMetadata.workspace.cwd, !cached.isEmpty {
      return cached
    }
    if let session = sessionRegistry.session(id: active.sessionId),
      let cwd = session.processMetadata()?.cwd, !cwd.isEmpty
    {
      return cwd
    }
    return nil
  }

  /// Snapshot the current workspace into a Codable structure suitable
  /// for atomic persistence. Reads under the model lock so the
  /// resulting `WorkspaceState` is internally consistent even if other
  /// threads mutate during the call. The persisted `cwd` for each tab
  /// is the most recently observed shell cwd
  /// (`tab.titleMetadata.workspace.cwd`); when unavailable (the tab was
  /// just created and metadata sync hasn't fired yet), it falls back to
  /// the live process metadata, and finally the user's home directory.
  public func snapshotForPersistence(windowId: String) -> WorkspaceState {
    withModelLock {
      let now = Date()
      let states: [TabState] = _tabs.map { tab in
        let session = sessionRegistry.session(id: tab.sessionId)
        let liveCwd: String? = {
          if let cached = tab.titleMetadata.workspace.cwd, !cached.isEmpty {
            return cached
          }
          if let session,
            let metadata = session.processMetadata(),
            let cwd = metadata.cwd, !cwd.isEmpty
          {
            return cwd
          }
          return nil
        }()
        let cwd = liveCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let launchCommand =
          launchCommandByTab[tab.id] ?? defaultLaunchCommand
        let processStatus: PersistedProcessStatus = {
          switch tab.status {
          case .running: return .running
          case .exited(let code): return code == 0 ? .exitedClean : .exitedError
          case .exitedSignal: return .exitedError
          }
        }()
        let exitCode: Int? = {
          switch tab.status {
          case .running: return nil
          case .exited(let code), .exitedSignal(let code): return code
          }
        }()
        let altBuffer = session?.altBufferActive ?? false
        let shellPid = session?.processMetadata()?.childPid
        let transcriptPath: String? = {
          if transcriptDelegate == nil { return nil }
          return "transcripts/\(tab.id).bin"
        }()
        let repoFingerprint = RepoFingerprint.fingerprint(cwd: cwd)
        return TabState(
          id: tab.id,
          cwd: cwd,
          launchCommand: launchCommand,
          lastActiveAt: now,
          transcriptPath: transcriptPath,
          altBufferAtQuit: altBuffer,
          cwdFallbackApplied: cwdFallbackAppliedByTab[tab.id],
          repoFingerprint: repoFingerprint,
          processStatus: processStatus,
          exitCode: exitCode,
          shellPid: shellPid,
          agent: agentByTab[tab.id]
        )
      }
      let selectedId = _tabs.first(where: { $0.isActive })?.id
      let window = WindowState(
        id: windowId,
        selectedTabId: selectedId,
        tabs: states
      )
      return WorkspaceState(windows: [window])
    }
  }

  /// Fires `onWorkspaceMutation` outside the model lock. Callers must
  /// invoke this AFTER `withModelLock` returns so the callback chain
  /// cannot re-enter the model under the same lock. Every workspace
  /// mutation is also a surface-state change (the sidebar renders tabs),
  /// so the frame-loop wake hook co-fires here — one fire point keeps
  /// every tab open/close/reorder/select entry point waking a parked
  /// display link without each call site remembering to.
  private func notifyWorkspaceMutation() {
    recordTabJournal()
    onWorkspaceMutation?()
    onSurfaceStateChanged?()
  }

  /// Fires `onSurfaceStateChanged` outside the model lock for mutations that
  /// change rendered pixels without being workspace mutations (no persistence
  /// debounce wanted): resolved git branches, daemon surface signals, agent
  /// status. Same re-entrancy contract as `notifyWorkspaceMutation`.
  private func notifySurfaceStateChanged() {
    recordTabJournal()
    onSurfaceStateChanged?()
  }

  /// Diffs the current tab projections into `tabJournal` and mirrors any new
  /// entries into a running capture. Hooked into both notify funnels — those
  /// are exactly the UI-invalidation signals, so a journal entry means "what
  /// some tab showed changed". Diff-dedupe makes the double funnel harmless.
  private func recordTabJournal() {
    let (snapshot, activeId): ([Tab], Tab.ID?) = withModelLock {
      (_tabs, _tabs.first(where: { $0.isActive })?.id)
    }
    let entries = tabJournal.recordDiff(tabs: snapshot, activeTabId: activeId)
    guard let captureSink, !entries.isEmpty else { return }
    let sessionByTab = Dictionary(
      snapshot.map { ($0.id, $0.sessionId) }, uniquingKeysWith: { first, _ in first })
    for entry in entries {
      captureSink.record(entry.captureEvent(sessionId: sessionByTab[entry.tabId]))
    }
  }

  public func recordAttentionNotificationDecision(_ decision: AttentionNotificationDecision) {
    withModelLock {
      attentionNotificationDecisions.append(decision)
      if attentionNotificationDecisions.count > Self.attentionDecisionCapacity {
        attentionNotificationDecisions.removeFirst(
          attentionNotificationDecisions.count - Self.attentionDecisionCapacity)
      }
    }
  }

  @discardableResult
  private func recordTabJournalNote(
    tabId: Tab.ID,
    note: String,
    text: String?
  ) -> Bool {
    let sessionId = withModelLock {
      _tabs.first(where: { $0.id == tabId })?.sessionId
    }
    let entry = tabJournal.note(tabId: tabId, note: note, text: text)
    captureSink?.record(entry.captureEvent(sessionId: sessionId))
    return sessionId != nil
  }

  /// Surface a user-visible, non-modal notice on a tab and mirror it into the
  /// tab-state journal so headless/debug clients can observe the same event.
  @discardableResult
  public func postTabNotice(
    forTab tabId: Tab.ID,
    note: String,
    text: String,
    urgent: Bool = false
  ) -> Bool {
    let changed: Bool = withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      let prior = _tabs[idx].titleMetadata.notification
      _tabs[idx].titleMetadata.notification = TabNotification(
        text: text,
        urgent: urgent || (prior?.urgent ?? false),
        count: (prior?.count ?? 0) + 1)
      return true
    }
    guard changed else { return false }
    notifyWorkspaceMutation()
    _ = recordTabJournalNote(tabId: tabId, note: note, text: text)
    return true
  }

  public func selectTab(_ tabId: Tab.ID) {
    let changed: Bool = withModelLock {
      let prior = _tabs.first(where: { $0.isActive })?.id
      selectTabUnlocked(tabId)
      let now = _tabs.first(where: { $0.isActive })?.id
      return prior != now
    }
    if changed { notifyWorkspaceMutation() }
  }

  private func selectTabUnlocked(_ tabId: Tab.ID) {
    guard let selectedIdx = _tabs.firstIndex(where: { $0.id == tabId }) else { return }
    for i in _tabs.indices {
      let selected = i == selectedIdx
      _tabs[i].isActive = selected
      if selected {
        _tabs[i].titleMetadata.unseenOutput = false
        _tabs[i].titleMetadata.bellAttention = false
        _tabs[i].titleMetadata.notification = nil
        _tabs[i].titleMetadata.agentStatus.indicatorColor = nil
        // Viewing the tab acknowledges its last command's outcome: drop the
        // steady failed-command dot the same way we drop the other attention
        // signals, and mark every completion seen so far as acknowledged so a
        // later prompt re-emission or metadata sync can't restore it. It
        // re-arms only when a *new* command finishes non-zero while this tab is
        // backgrounded (see resolveFailedCommandDot).
        _tabs[i].titleMetadata.lastCommandExitCode = nil
        acknowledgeShellCommands(forTabAt: i)
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

  /// Record that the user has seen every command the tab's shell has finished,
  /// so the failed-command dot stays dismissed until a genuinely new command
  /// fails. Called when a tab becomes active; pairs with the dot's gate in
  /// `TabMetadataSynchronizer.resolveFailedCommandDot`.
  private func acknowledgeShellCommands(forTabAt idx: Int) {
    guard _tabs.indices.contains(idx) else { return }
    let count =
      sessionRegistry.session(id: _tabs[idx].sessionId)?
      .shellIntegrationState().completedCommandCount ?? 0
    metadataSync.acknowledgeShellCommands(forTab: _tabs[idx].id, upTo: count)
  }

  public func closeTab(_ tabId: Tab.ID) throws {
    var lastTabClosedThrown = false
    var closedSession: Session?
    var closedTabId: Tab.ID?
    do {
      try withModelLock {
        guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
          throw AppError.tabNotFound
        }
        let tab = _tabs[idx]
        closedTabId = tab.id
        closedSession = sessionRegistry.session(id: tab.sessionId)

        if _tabs.count == 1 {
          sessionRegistry.close(sessionId: tab.sessionId)
          findStateBySession.removeValue(forKey: tab.sessionId)
          findFullSearchCacheBySession.removeValue(forKey: tab.sessionId)
          launchCommandByTab.removeValue(forKey: tab.id)
          agentByTab.removeValue(forKey: tab.id)
          cwdFallbackAppliedByTab.removeValue(forKey: tab.id)
          metadataSync.forget(tab: tab)
          _tabs = []
          recordTab(.tabClosed, tabId: tab.id, sessionId: tab.sessionId)
          lastTabClosedThrown = true
          throw AppError.lastTabClosed
        }

        // Determine next active tab before removing
        let wasActive = tab.isActive
        sessionRegistry.close(sessionId: tab.sessionId)
        findStateBySession.removeValue(forKey: tab.sessionId)
        findFullSearchCacheBySession.removeValue(forKey: tab.sessionId)
        launchCommandByTab.removeValue(forKey: tab.id)
        launchArgvByTab.removeValue(forKey: tab.id)
        agentByTab.removeValue(forKey: tab.id)
        cwdFallbackAppliedByTab.removeValue(forKey: tab.id)
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
          _tabs[newActiveIdx].titleMetadata.bellAttention = false
          _tabs[newActiveIdx].titleMetadata.notification = nil
          _tabs[newActiveIdx].titleMetadata.agentStatus.indicatorColor = nil
          _tabs[newActiveIdx].titleMetadata.lastCommandExitCode = nil
          acknowledgeShellCommands(forTabAt: newActiveIdx)
          if _tabs[newActiveIdx].status == .running {
            _tabs[newActiveIdx].titleMetadata.activityState = .active
          }
        }
      }
    } catch {
      if let id = closedTabId {
        transcriptDelegate?.detachTranscriptWriter(forTabId: id, in: closedSession)
        onTabClosed?(id)
      }
      if lastTabClosedThrown {
        notifyWorkspaceMutation()
      }
      throw error
    }
    if let id = closedTabId {
      transcriptDelegate?.detachTranscriptWriter(forTabId: id, in: closedSession)
      onTabClosed?(id)
    }
    notifyWorkspaceMutation()
  }

  /// Move `tabId` to `newIndex` (0-based, clamped to `[0, count - 1]`).
  /// Tab identity, active selection, and per-tab state survive — only the
  /// array order and the rendered 1-based `position` change. A no-op move
  /// (same index, or unknown id) returns false and does NOT fire the
  /// workspace-mutation callback. `AppError.tabNotFound` is thrown for
  /// unknown ids so callers can distinguish a stale drag from a real
  /// reorder.
  @discardableResult
  public func moveTab(_ tabId: Tab.ID, to newIndex: Int) throws -> Bool {
    let moved: Bool = try withModelLock {
      guard let fromIdx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        throw AppError.tabNotFound
      }
      let lastIdx = _tabs.count - 1
      let clamped = max(0, min(newIndex, lastIdx))
      if clamped == fromIdx { return false }
      let tab = _tabs.remove(at: fromIdx)
      _tabs.insert(tab, at: clamped)
      for i in _tabs.indices {
        _tabs[i].position = i + 1
        resolveTitle(at: i)
      }
      recordTab(.tabMoved, tabId: tab.id, sessionId: tab.sessionId)
      return true
    }
    if moved { notifyWorkspaceMutation() }
    return moved
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
      _tabs[idx].lastActivityAt = Date()
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
    bellAttention: Bool? = nil,
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
      if let lastActivityAt { _tabs[idx].lastActivityAt = lastActivityAt }
      if let lastOutputAt { _tabs[idx].lastOutputAt = lastOutputAt }
      if let unseenOutput { _tabs[idx].titleMetadata.unseenOutput = unseenOutput }
      if let bellAttention { _tabs[idx].titleMetadata.bellAttention = bellAttention }
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
    let priorCwd = withModelLock {
      _tabs.first(where: { $0.id == tabId })?.titleMetadata.workspace.cwd
    }
    let changed = withModelLock {
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
    if changed {
      let newCwd = withModelLock {
        _tabs.first(where: { $0.id == tabId })?.titleMetadata.workspace.cwd
      }
      if priorCwd != newCwd {
        notifyWorkspaceMutation()
      }
    }
    return changed
  }

  /// Apply foreground-process metadata to a tab directly, bypassing the
  /// `Session.processMetadata()` poll. Used by the background-session
  /// coordinator (`AppSessionCoordinator`) which receives metadata
  /// over the daemon control protocol — its local `Session` is a fixture
  /// with no PTY handle so the normal `syncProcessMetadata` path would
  /// always see nil.
  @discardableResult
  public func applyProcessMetadata(
    _ metadata: Session.ProcessMetadata,
    forTab tabId: Tab.ID,
    now: Date = Date()
  ) -> Bool {
    let priorCwd = withModelLock {
      _tabs.first(where: { $0.id == tabId })?.titleMetadata.workspace.cwd
    }
    let changed = withModelLock {
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
    if changed {
      let newCwd = withModelLock {
        _tabs.first(where: { $0.id == tabId })?.titleMetadata.workspace.cwd
      }
      if priorCwd != newCwd {
        notifyWorkspaceMutation()
      }
    }
    return changed
  }

  /// Test hook: overrides the probe that decides whether a terminal title's
  /// recorded owner process is still running.
  func setTitleOwnerLivenessProbeForTesting(_ probe: @escaping (Int?) -> Bool) {
    withModelLock {
      metadataSync.processIsAlive = probe
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

  func syncSurfaceMetadata(
    forTab tabId: Tab.ID,
    tabIndex: Int,
    from session: Session,
    now: Date,
    recordTitleChanges: Bool
  ) -> AppModelSurfaceMetadataSyncResult {
    runSurfaceMetadataSync(
      forTab: tabId,
      tabIndex: tabIndex,
      sessionId: session.id,
      now: now,
      recordTitleChanges: recordTitleChanges,
      sync: { idx, onBranchResolved in
        metadataSync.syncSurfaceMetadata(
          forTab: tabId,
          at: idx,
          from: session,
          now: now,
          tabs: &_tabs,
          onBranchResolved: onBranchResolved
        )
      }
    )
  }

  /// Signals-based surface-metadata sync. Used by the laband coordinator
  /// to feed daemon-sourced title/process metadata through the same apply
  /// path as the local-session writer, so both can't write conflicting
  /// data into `TabMetadataSynchronizer`. Returns `true` when the model
  /// changed; the coordinator doesn't need the full capture-event detail.
  @discardableResult
  public func applySurfaceSignals(
    _ signals: TabSurfaceSignals,
    forTab tabId: Tab.ID,
    now: Date = Date()
  ) -> Bool {
    let modelChanged = runSurfaceMetadataSync(
      forTab: tabId,
      tabIndex: -1,
      sessionId: "",
      now: now,
      recordTitleChanges: false,
      sync: { idx, onBranchResolved in
        metadataSync.syncSurfaceMetadata(
          forTab: tabId,
          at: idx,
          signals: signals,
          now: now,
          tabs: &_tabs,
          onBranchResolved: onBranchResolved
        )
      }
    ).modelChanged
    // Daemon-sourced signals arrive off the local session's output path (no
    // dirty-generation bump), so a parked display link needs this model-level
    // wake to paint the change.
    if modelChanged { notifySurfaceStateChanged() }
    return modelChanged
  }

  /// Clears a tab's surface-owned agent status, but only when it still holds
  /// the exact value the surface last set. The surface path uses this to retire
  /// a transport-degradation badge ("output skipped") once the user has viewed
  /// the tab, without clobbering an OSC 21337 status the child may have pushed
  /// in the meantime — both share `titleMetadata.agentStatus`, so an
  /// unconditional clear would wipe a legitimate process-reported status.
  @discardableResult
  public func clearAgentStatus(forTab tabId: Tab.ID, ifEquals expected: TabAgentStatus) -> Bool {
    withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      guard _tabs[idx].titleMetadata.agentStatus == expected else { return false }
      _tabs[idx].titleMetadata.agentStatus = TabAgentStatus()
      return true
    }
  }

  private func runSurfaceMetadataSync(
    forTab tabId: Tab.ID,
    tabIndex: Int,
    sessionId: Session.ID,
    now: Date,
    recordTitleChanges: Bool,
    sync: (
      _ idx: Int,
      _ onBranchResolved: @escaping TabMetadataSynchronizer.BranchResolved
    ) -> TabMetadataSynchronizer.SurfaceMetadataSyncResult
  ) -> AppModelSurfaceMetadataSyncResult {
    var shouldNotifyWorkspaceMutation = false
    let result = withModelLock {
      let idxLookup: Int? =
        sessionId.isEmpty
        ? _tabs.firstIndex(where: { $0.id == tabId })
        : tabIndexUnlocked(forTab: tabId, sessionId: sessionId, preferredIndex: tabIndex)
      guard let idx = idxLookup else {
        return AppModelSurfaceMetadataSyncResult(modelChanged: false, titleChangeEvent: nil)
      }

      let priorCwd = _tabs[idx].titleMetadata.workspace.cwd
      let onBranchResolved: TabMetadataSynchronizer.BranchResolved = {
        [weak self] branch, tabId, cwd in
        self?.applyResolvedBranch(branch, forTab: tabId, cwd: cwd)
      }
      let syncResult = sync(idx, onBranchResolved)

      if syncResult.processMetadataChanged {
        shouldNotifyWorkspaceMutation = priorCwd != _tabs[idx].titleMetadata.workspace.cwd
      }

      let event: CaptureTimelineEvent?
      if recordTitleChanges, let updated = syncResult.titleChangedTab {
        var titleEvent = CaptureTimelineEvent(
          kind: .appState,
          tabId: updated.id,
          sessionId: updated.sessionId
        )
        titleEvent.title = updated.title
        event = titleEvent
      } else {
        event = nil
      }

      return AppModelSurfaceMetadataSyncResult(
        modelChanged: syncResult.modelChanged,
        titleChangeEvent: event
      )
    }

    if shouldNotifyWorkspaceMutation {
      notifyWorkspaceMutation()
    }
    if result.modelChanged {
      // Title/metadata changes land here without passing a notify funnel (the
      // local path syncs inside the frame loop), so journal them directly and
      // check for awaiting-input title transitions.
      recordTabJournal()
      detectAwaitMarkerTransitions()
    }
    return result
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

  func noteSurfaceOutput(
    forTab tabId: Tab.ID,
    tabIndex: Int,
    sessionId: Session.ID,
    at date: Date
  ) -> Bool {
    withModelLock {
      guard
        let idx = tabIndexUnlocked(forTab: tabId, sessionId: sessionId, preferredIndex: tabIndex)
      else {
        return false
      }
      findFullSearchCacheBySession.removeValue(forKey: sessionId)
      return metadataSync.noteOutput(forTab: tabId, at: idx, date: date, tabs: &_tabs)
    }
  }

  private func tabIndexUnlocked(
    forTab tabId: Tab.ID,
    sessionId: Session.ID,
    preferredIndex: Int
  ) -> Int? {
    if _tabs.indices.contains(preferredIndex),
      _tabs[preferredIndex].id == tabId,
      _tabs[preferredIndex].sessionId == sessionId
    {
      return preferredIndex
    }
    return _tabs.firstIndex { $0.id == tabId && $0.sessionId == sessionId }
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

  public func resize(
    viewportWidth: Int, viewportHeight: Int, cellWidth: Int, cellHeight: Int,
    deferFindRescan: Bool = false
  ) {
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
            if deferFindRescan {
              // During a live resize drag, defer the O(scrollback) full find
              // rescan to resize-settle (refreshActiveFindsAfterResize). The
              // per-frame visible-highlight recompute still keeps what's on
              // screen correct, so each pixel nudge no longer formats the
              // whole scrollback on the main thread. (H-5)
              pendingFindRescanSessions.insert(session.id)
            } else {
              _ = refreshFindFullUnlocked(sessionID: session.id)
            }
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
      } else if let matches = session.findMatchesInScrollback(
        needle: state.needle,
        maxRows: viewport.totalRows
      ) {
        state.matches = matches
        fullSearchCacheKey = (state.needle, viewport.totalRows)
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

  private func launchContext(tabId: Tab.ID? = nil, isAgentAttached: Bool = false) -> SessionLaunchContext {
    sessionLaunchContextProvider?(tabId, isAgentAttached)
      ?? .fresh(tabID: tabId, isAgentAttached: isAgentAttached)
  }

  private func attachSessionCallbacks(session: Session, tabId: Tab.ID) {
    attachTabStatus(session: session, tabId: tabId)
    attachProgress(session: session, tabId: tabId)
    attachBellAttention(session: session, tabId: tabId)
    attachOSCNotification(session: session, tabId: tabId)
    attachClipboard(session: session, tabId: tabId)
    attachWorkingDirectory(session: session, tabId: tabId)
    attachShellIntegration(session: session, tabId: tabId)
  }

  /// Re-broadcast OSC 7 working-directory reports on the main queue. The cwd is
  /// adopted authoritatively in the C layer (see `processMetadata`), so this is
  /// only an observability hook; it does not itself mutate `workspace.cwd` (the
  /// metadata sync owns that write, now sourced from the OSC 7 cwd).
  private func attachWorkingDirectory(session: Session, tabId: Tab.ID) {
    session.onWorkingDirectory = { [weak self] cwd in
      DispatchQueue.main.async { [weak self] in
        self?.onWorkingDirectoryChange?(tabId, cwd)
      }
    }
  }

  /// Bridge the session's OSC 52 clipboard callbacks to the host. The C
  /// callbacks fire on the reader thread with the session lock held, so — like
  /// `attachOSCNotification` — both the pasteboard write and the read reply hop
  /// to the main queue (the read reply also keeps `NSPasteboard` off the reader
  /// thread). Write is wired unconditionally; read fires only when the session
  /// has read enabled, set here from `osc52ReadEnabled`.
  private func attachClipboard(session: Session, tabId: Tab.ID) {
    session.clipboardReadEnabled = osc52ReadEnabled
    session.onClipboardWrite = { [weak self] data in
      DispatchQueue.main.async { [weak self] in
        self?.onClipboardWrite?(tabId, data)
      }
    }
    session.onClipboardReadRequest = { [weak self, weak session] selection in
      DispatchQueue.main.async { [weak self, weak session] in
        guard let session else { return }
        let data = self?.clipboardReadProvider?() ?? Data()
        session.respondClipboardRead(selection: selection, data: data)
      }
    }
  }

  /// Subscribe to OSC 133 transitions and re-broadcast them on the main
  /// queue via `onShellIntegrationChange`. The C callback fires from the
  /// per-session reader thread with the session lock held, so — like
  /// `attachTabStatus` — the model mutation is punted to the main queue to
  /// avoid holding two locks at once.
  private func attachShellIntegration(session: Session, tabId: Tab.ID) {
    session.onShellIntegration = { [weak self] state in
      DispatchQueue.main.async { [weak self] in
        self?.applyShellIntegration(state, forTab: tabId)
        self?.onShellIntegrationChange?(tabId, state)
      }
    }
  }

  /// Fold the latest OSC 133 phase + command exit code into the tab's
  /// metadata so the sidebar can render a status indicator.
  private func applyShellIntegration(_ state: ShellIntegrationState, forTab tabId: Tab.ID) {
    withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return }
      _tabs[idx].titleMetadata.shellPhase = state.phase
      // The failed-command dot is an attention signal for *background* tabs:
      // it tells you a tab you weren't watching finished a command non-zero.
      // A command that finishes while you're already on the tab earns no dot
      // (you saw it). Crucially the dot keys on a *new* completion, not the
      // raw exit code: the reducer carries the last exit code forward across
      // later markers, so a bare prompt re-emission (OSC 133 A on every Enter)
      // re-delivers a stale non-zero code — re-applying it here re-armed a dot
      // the user had already dismissed. `resolveFailedCommandDot` gates on the
      // acknowledged completion count so only a genuinely new failure arms.
      _tabs[idx].titleMetadata.lastCommandExitCode =
        metadataSync.resolveFailedCommandDot(
          forTab: tabId, state: state, isActive: _tabs[idx].isActive)
    }
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

  /// Subscribe to OSC 9;4 progress pushes. Same main-queue hop as
  /// `attachTabStatus` and for the same lock-inversion reason.
  private func attachProgress(session: Session, tabId: Tab.ID) {
    session.onProgress = { [weak self] update in
      DispatchQueue.main.async { [weak self] in
        self?.applyProgressUpdate(update, forTab: tabId)
      }
    }
  }

  private func applyProgressUpdate(_ update: Session.ProgressUpdate, forTab tabId: Tab.ID) {
    let changed: Bool = withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      let next: TabProgress?
      switch update.operation {
      case 1: next = TabProgress(state: .determinate, percent: update.percent)
      case 2: next = TabProgress(state: .error, percent: update.percent)
      case 3: next = TabProgress(state: .indeterminate)
      default: next = nil  // 0 = clear
      }
      guard _tabs[idx].titleMetadata.progress != next else { return false }
      _tabs[idx].titleMetadata.progress = next
      return true
    }
    if changed { notifySurfaceStateChanged() }
  }

  private func attachBellAttention(session: Session, tabId: Tab.ID) {
    session.onBell = { [weak self] _ in
      let date = Date()
      DispatchQueue.main.async { [weak self] in
        self?.broadcastBellAttentionIfNeeded(forTab: tabId, at: date)
      }
    }
  }

  @discardableResult
  func applyBellAttention(forTab tabId: Tab.ID, at date: Date) -> String? {
    let result: (changed: Bool, title: String?) = withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else {
        return (false, nil)
      }
      let hadAttention = _tabs[idx].titleMetadata.bellAttention
      let changed = metadataSync.noteBell(forTab: tabId, at: date, tabs: &_tabs)
      let raisedAttention = !hadAttention && _tabs[idx].titleMetadata.bellAttention
      return (changed, raisedAttention ? _tabs[idx].titleMetadata.displayTitle : nil)
    }
    if result.changed { notifySurfaceStateChanged() }
    return result.title
  }

  private func broadcastBellAttentionIfNeeded(forTab tabId: Tab.ID, at date: Date) {
    guard let title = applyBellAttention(forTab: tabId, at: date) else { return }
    let event = AttentionNotificationEvent(
      tabId: tabId,
      source: .bell,
      category: .passive,
      title: title,
      body: "Tab needs attention.",
      dedupeKey: "bell:\(tabId)",
      createdAt: date)
    broadcastAttentionNotification(event)
  }

  /// Re-broadcast OSC 9 desktop notifications. The session callback fires on the
  /// reader thread; hop to main (matching `attachBellAttention`) so the host's
  /// notification posting and the model mutation both run on the main queue.
  private func attachOSCNotification(session: Session, tabId: Tab.ID) {
    session.onOSCNotification = { [weak self] text in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Surface it on the tab (sidebar badge + text) so a backgrounded Codex
        // tab visibly shows it finished / needs the user, even if the native
        // banner is dismissed or notification permission was denied.
        let outcome = self.applyAgentNotification(forTab: tabId, text: text)
        // Broadcast (and hence banner) only when the badge actually applied:
        // a merge means the title-flip banner already covered this wait, and
        // .ignored means the restore-grace window is open — resumed agents
        // re-emit their notifications in a burst at relaunch, and bannering
        // all of them buried the user in stale macOS notifications (seen in
        // the tab journal: ~40 banner notes in the first 200ms of a launch).
        self.broadcastAgentNotificationIfNeeded(tabId: tabId, text: text, outcome: outcome)
      }
    }
  }

  /// Open while a workspace restore is settling. A restored agent that resumes
  /// into a "waiting" / "needs permission" state re-emits its OSC 9 on launch,
  /// which would otherwise badge every restored tab with a stale notification
  /// the instant the app opens. `replaceTabs` opens this window; it closes
  /// `restoreNotificationGraceSeconds` later, after the resume burst settles.
  var notificationSuppressionDeadline: Date?
  var restoreNotificationGraceSeconds: TimeInterval = 8

  /// Record an OSC 9 desktop notification on a tab so it shows in the sidebar
  /// until the user opens (or returns to) that tab. Codex only emits OSC 9 when
  /// the tab is unfocused, so we always badge; the clear happens on
  /// `selectTabUnlocked` (open another-then-this tab) and
  /// `markActiveTabNotificationSeen` (return to the app). Repeat notifications
  /// before the tab is viewed accumulate an unread count.
  enum AgentNotificationOutcome {
    case ignored
    case applied
    /// Folded into the pending synthetic awaiting-input badge raised at the
    /// title flip (see `detectAwaitMarkerTransitions`): text/urgency refresh,
    /// but no count bump. Banners fire only when the merged OSC is urgent
    /// (see `broadcastAgentNotificationIfNeeded`).
    case mergedIntoAwaitEpisode
  }

  @discardableResult
  func applyAgentNotification(forTab tabId: Tab.ID, text: String) -> AgentNotificationOutcome {
    let outcome: AgentNotificationOutcome = withModelLock {
      // Ignore the restore-time resume burst (see notificationSuppressionDeadline).
      if let deadline = notificationSuppressionDeadline, Date() < deadline { return .ignored }
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return .ignored }
      let prior = _tabs[idx].titleMetadata.notification
      if var episode = awaitEpisodeByTab[tabId] {
        let merge = episode.raised && !episode.realArrived && prior != nil
        episode.realArrived = true
        awaitEpisodeByTab[tabId] = episode
        if merge, let prior {
          _tabs[idx].titleMetadata.notification = TabNotification(
            text: text,
            urgent: Self.isUrgentNotification(text) || prior.urgent,
            count: prior.count)
          return .mergedIntoAwaitEpisode
        }
      }
      _tabs[idx].titleMetadata.notification = TabNotification(
        text: text,
        urgent: Self.isUrgentNotification(text) || (prior?.urgent ?? false),
        count: (prior?.count ?? 0) + 1)
      return .applied
    }
    if outcome != .ignored { notifyWorkspaceMutation() }
    return outcome
  }

  /// Heuristic: permission / approval prompts need user action (urgent style).
  /// Claude Code's turn-complete OSC ("waiting for your input") and Codex
  /// summaries are informational — ready at the prompt, not blocked.
  /// Heuristic: is this agent OSC a blocking request (urgent style + native
  /// banner) or an informational turn-complete?
  ///
  /// An unambiguous blocking keyword (permission / approval / "wants to") wins
  /// even when the message also mentions waiting or completion — a real
  /// "needs permission" must never be silenced by an echoed "…waiting for your
  /// input". Only with no blocking keyword present do Claude Code's
  /// turn-complete OSC ("waiting for your input") and Codex's "turn complete"
  /// summaries read as informational (ready at the prompt, not blocked); softer
  /// action words still defer to those completion markers.
  static func isUrgentNotification(_ text: String) -> Bool {
    let t = text.lowercased()
    if t.contains("approval") || t.contains("approve")
      || t.contains("permission") || t.contains("wants to")
    {
      return true
    }
    if t.contains("waiting for your input") || t.contains("turn complete")
      || t.contains("task complete")
    {
      return false
    }
    return t.contains("needs your") || t.contains("needs input")
      || t.contains("requested")
  }

  /// Convert OSC 9-style agent messages into unified attention events. Policy
  /// decides later whether a native banner, sidebar-only state, or suppression
  /// is appropriate for the event's category and tab focus.
  private func broadcastAgentNotificationIfNeeded(
    tabId: Tab.ID, text: String, outcome: AgentNotificationOutcome
  ) {
    switch outcome {
    case .applied, .mergedIntoAwaitEpisode:
      let urgent = Self.isUrgentNotification(text)
      guard
        let event = makeAttentionNotificationEvent(
          tabId: tabId,
          source: .osc,
          category: urgent ? .needsAction : .completion,
          body: text,
          dedupeKey: "osc:\(tabId):\(urgent ? "needsAction" : "completion"):\(text)")
      else { return }
      broadcastAttentionNotification(event)
    case .ignored:
      let urgent = Self.isUrgentNotification(text)
      guard
        let event = makeAttentionNotificationEvent(
          tabId: tabId,
          source: .osc,
          category: urgent ? .needsAction : .completion,
          body: text,
          dedupeKey: "osc:\(tabId):restore:\(text)")
      else { return }
      recordAttentionNotificationDecision(
        AttentionNotificationDecision(
          event: event, action: .suppressed, suppressionReason: .restoreSuppression))
    }
  }

  private func broadcastAttentionNotification(_ event: AttentionNotificationEvent) {
    onAttentionNotification?(event)
    switch event.source {
    case .osc where event.category == .needsAction:
      onAgentNotification?(event.tabId, event.body)
    case .bell:
      onBellAttention?(event.tabId, event.title)
    case .osc, .tabAttention:
      break
    }
  }

  private func makeAttentionNotificationEvent(
    tabId: Tab.ID,
    source: AttentionNotificationSource,
    category: AttentionNotificationCategory,
    body: String,
    dedupeKey: String,
    createdAt: Date = Date()
  ) -> AttentionNotificationEvent? {
    withModelLock {
      guard let tab = _tabs.first(where: { $0.id == tabId }) else { return nil }
      return AttentionNotificationEvent(
        tabId: tab.id,
        source: source,
        category: category,
        title: tab.titleMetadata.displayTitle,
        body: body,
        dedupeKey: dedupeKey,
        createdAt: createdAt)
    }
  }

  public static let awaitingInputNotificationText = "Awaiting your input"

  struct AwaitEpisode {
    /// The flip raised the informational synthetic badge (it was backgrounded
    /// and outside the restore-grace window).
    var raised = false
    /// The agent's own OSC notification arrived during this episode.
    var realArrived = false
  }

  /// Active blocked-on-the-user episodes keyed by tab; an episode spans from
  /// the terminal title gaining an awaiting-input marker (Claude Code's
  /// leading "✳", Codex's "[ ! ]" prefix — see
  /// `TabAttentionClassifier.titleSignalsAwaitingInput`) to the title losing
  /// it. Guarded by `modelLock`.
  ///
  /// The marker is meaningful as an *edge*, not a state: "✳" is the resting
  /// title of every idle Claude Code tab, so a stateless needsAction
  /// classification turned every restored or viewed-then-backgrounded agent
  /// tab permanently yellow. Instead the flip raises an informational
  /// `TabNotification` badge (~6s before the agent's OSC); urgency and native
  /// banners come from `isUrgentNotification` when the OSC arrives. Both
  /// inherit seen-clearing (select / app-active) and restore-grace
  /// suppression; the debounced OSC merges into the badge without inflating
  /// the unread count.
  private var awaitEpisodeByTab: [Tab.ID: AwaitEpisode] = [:]

  /// Diffs each tab's terminal title against the awaiting-input predicate
  /// and drives attention episodes. Called after every surface-metadata sync
  /// that changed the model — the single chokepoint both the local parse
  /// path and the laband poll path go through.
  func detectAwaitMarkerTransitions() {
    var started: [Tab.ID] = []
    var endedRaised: [Tab.ID] = []
    withModelLock {
      var live = Set<Tab.ID>(minimumCapacity: _tabs.count)
      for tab in _tabs {
        live.insert(tab.id)
        let blocked = TabAttentionClassifier.titleSignalsAwaitingInput(tab.titleMetadata)
        if blocked, awaitEpisodeByTab[tab.id] == nil {
          awaitEpisodeByTab[tab.id] = AwaitEpisode()
          started.append(tab.id)
        } else if !blocked, let episode = awaitEpisodeByTab.removeValue(forKey: tab.id) {
          if episode.raised, !episode.realArrived { endedRaised.append(tab.id) }
        }
      }
      let closed = awaitEpisodeByTab.keys.filter { !live.contains($0) }
      for id in closed { awaitEpisodeByTab.removeValue(forKey: id) }
    }
    for tabId in started { raiseSyntheticAttention(forTab: tabId) }
    for tabId in endedRaised { clearStaleSyntheticBadge(forTab: tabId) }
  }

  /// Sets an informational awaiting-input badge on a background tab. Native
  /// banners are reserved for urgent OSC (permission/approval); the flip
  /// itself does not broadcast. Skipped when the user is already watching the
  /// tab (`isTabFrontmost`), when a notification is already pending (the user
  /// has an unseen badge either way), or during the restore-time suppression
  /// window (a relaunch restores a wall of idle "✳" agent tabs that must not
  /// all light up).
  private func raiseSyntheticAttention(forTab tabId: Tab.ID) {
    if isTabFrontmost?(tabId) == true { return }
    let event: AttentionNotificationEvent? = withModelLock {
      let now = Date()
      if let deadline = notificationSuppressionDeadline, now < deadline { return nil }
      guard var episode = awaitEpisodeByTab[tabId] else { return nil }
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
      guard _tabs[idx].titleMetadata.notification == nil else { return nil }
      episode.raised = true
      awaitEpisodeByTab[tabId] = episode
      _tabs[idx].titleMetadata.notification = TabNotification(
        text: Self.awaitingInputNotificationText, urgent: false)
      let tab = _tabs[idx]
      let attention = TabAttentionClassifier.classify(tab.titleMetadata, isActive: tab.isActive)
      let category = AttentionNotificationCategory(attention) ?? .completion
      return AttentionNotificationEvent(
        tabId: tab.id,
        source: .tabAttention,
        category: category,
        title: tab.titleMetadata.displayTitle,
        body: Self.awaitingInputNotificationText,
        dedupeKey: "tabAttention:\(tab.id):await",
        createdAt: now)
    }
    guard let event else { return }
    notifyWorkspaceMutation()
    broadcastAttentionNotification(event)
  }

  /// The agent resumed working without its own notification ever arriving,
  /// so an unseen synthetic badge is stale (e.g. the user answered from
  /// another device) — retire it rather than leave a lying "ready".
  private func clearStaleSyntheticBadge(forTab tabId: Tab.ID) {
    let cleared: Bool = withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return false }
      guard let notification = _tabs[idx].titleMetadata.notification,
        notification.text == Self.awaitingInputNotificationText,
        notification.count == 1
      else { return false }
      _tabs[idx].titleMetadata.notification = nil
      return true
    }
    if cleared { notifyWorkspaceMutation() }
  }

  /// Clear the notification on the active tab — the user has returned to the
  /// window and is now looking at it. Wired to the app becoming active.
  public func markActiveTabNotificationSeen() {
    let changed: Bool = withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.isActive }),
        _tabs[idx].titleMetadata.notification != nil
      else { return false }
      _tabs[idx].titleMetadata.notification = nil
      return true
    }
    if changed { notifyWorkspaceMutation() }
  }

  private func applyTabStatusUpdate(_ update: Session.TabStatusUpdate, forTab tabId: Tab.ID) {
    let result: (changed: Bool, needsActionEvent: AttentionNotificationEvent?) = withModelLock {
      guard let idx = _tabs.firstIndex(where: { $0.id == tabId }) else { return (false, nil) }
      var status = _tabs[idx].titleMetadata.agentStatus
      let before = status
      let wasAwaiting = _tabs[idx].titleMetadata.agent.awaitingInput

      if let v = update.indicator {
        status.indicatorColor = v.isEmpty ? nil : v
      }
      if let v = update.status {
        status.statusText = v.isEmpty ? nil : v
      }
      if let v = update.statusColor {
        status.statusTextColor = v.isEmpty ? nil : v
      }

      var changed = false
      // Laban extension: `awaiting=1` marks the tab blocked on user input
      // (drives the needsAction attention level and the "!" badge); an empty
      // or falsy value clears it; an absent key preserves the prior state.
      if let v = update.awaiting {
        let awaiting = v == "1" || v.lowercased() == "true"
        if _tabs[idx].titleMetadata.agent.awaitingInput != awaiting {
          _tabs[idx].titleMetadata.agent.awaitingInput = awaiting
          changed = true
        }
      }

      if status != before {
        _tabs[idx].titleMetadata.agentStatus = status
        changed = true
      }
      let tab = _tabs[idx]
      let attention = TabAttentionClassifier.classify(tab.titleMetadata, isActive: tab.isActive)
      let raisedNeedsAction =
        !wasAwaiting && tab.titleMetadata.agent.awaitingInput
        && attention == .needsAction
      let statusBody = update.status?.trimmingCharacters(in: .whitespacesAndNewlines)
      let event =
        raisedNeedsAction
        ? AttentionNotificationEvent(
          tabId: tab.id,
          source: .tabAttention,
          category: .needsAction,
          title: tab.titleMetadata.displayTitle,
          body: statusBody?.isEmpty == false
            ? statusBody!
            : "Tab needs attention.",
          dedupeKey: "tabAttention:\(tab.id):agentAwaiting")
        : nil
      return (changed, event)
    }
    // The OSC 21337 bytes that carried this update woke the frame loop via
    // onSessionDirty, but this model write lands on a later main-queue hop and
    // can miss that frame; with a parked link only this wake repaints it.
    if result.changed { notifySurfaceStateChanged() }
    if let event = result.needsActionEvent {
      broadcastAttentionNotification(event)
    }
  }

  /// Completion target for `TabMetadataSynchronizer` git refresh. Writes the resolved branch into
  /// the tab's workspace metadata only when the tab's cwd still matches the
  /// cwd that was queried — avoids a stale background result clobbering a
  /// fresh `cd` that happened mid-flight.
  private func applyResolvedBranch(_ branch: String?, forTab tabId: Tab.ID, cwd: String) {
    let changed: Bool = withModelLock {
      metadataSync.applyResolvedBranch(branch, forTab: tabId, cwd: cwd, tabs: &_tabs)
    }
    // Background git resolution completes off the output path: nothing bumps
    // the session's dirty generation, so without this model-level wake a
    // parked display link would freeze the sidebar's branch label until the
    // tab's next terminal byte.
    if changed { notifySurfaceStateChanged() }
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
