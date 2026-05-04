import Foundation
import LabanRenderer
import LabanTerminalCore

public final class AppModel {
  public static let maxTabs = 9

  public private(set) var tabs: [Tab] = []
  private var sessions: [Session.ID: Session] = [:]
  private var lastProcessMetadataSyncAtByTab: [Tab.ID: Date] = [:]
  private var currentSize: LabanTerminalSize
  private let sessionFactory: (LabanTerminalSize) throws -> Session
  private let processMetadataSyncInterval: TimeInterval = 0.25
  public weak var captureSink: CaptureSink? {
    didSet {
      for session in sessions.values {
        session.captureSink = captureSink
      }
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
    tabs.append(tab)
  }

  public var activeTab: Tab? { tabs.first(where: { $0.isActive }) }

  public func session(forTab tabId: Tab.ID) -> Session? {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
    return sessions[tab.sessionId]
  }

  @discardableResult
  public func createTab() throws -> Tab {
    guard tabs.count < AppModel.maxTabs else { throw AppError.tabLimitReached }
    let session = try sessionFactory(currentSize)
    session.captureSink = captureSink
    AppModel.maybeAutoCapture(session)
    AppModel.applyThemePalette(to: session)
    let position = tabs.count + 1
    let tab = Tab(
      id: UUID().uuidString,
      position: position,
      title: "Tab \(position)",
      isActive: false,
      sessionId: session.id
    )
    sessions[session.id] = session
    tabs.append(tab)
    recordSessionCreated(sessionId: session.id, tabId: tab.id)
    recordTab(.tabCreated, tabId: tab.id, sessionId: session.id)
    selectTab(tab.id)
    return tabs.last!
  }

  public func selectTab(_ tabId: Tab.ID) {
    for i in tabs.indices {
      let selected = tabs[i].id == tabId
      tabs[i].isActive = selected
      if selected {
        tabs[i].titleMetadata.unseenOutput = false
      }
      if tabs[i].status == .running {
        tabs[i].titleMetadata.activityState =
          selected
          ? .active
          : (tabs[i].titleMetadata.unseenOutput ? .unseenOutput : .background)
      }
    }
    if let tab = tabs.first(where: { $0.id == tabId }) {
      recordTab(.tabSelected, tabId: tab.id, sessionId: tab.sessionId)
    }
  }

  public func closeTab(_ tabId: Tab.ID) throws {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    let tab = tabs[idx]

    if tabs.count == 1 {
      sessions[tab.sessionId]?.close()
      sessions.removeValue(forKey: tab.sessionId)
      lastProcessMetadataSyncAtByTab.removeValue(forKey: tab.id)
      tabs = []
      recordTab(.tabClosed, tabId: tab.id, sessionId: tab.sessionId)
      throw AppError.lastTabClosed
    }

    // Determine next active tab before removing
    let wasActive = tab.isActive
    sessions[tab.sessionId]?.close()
    sessions.removeValue(forKey: tab.sessionId)
    lastProcessMetadataSyncAtByTab.removeValue(forKey: tab.id)
    tabs.remove(at: idx)
    recordTab(.tabClosed, tabId: tab.id, sessionId: tab.sessionId)

    // Recompute one-based positions
    for i in tabs.indices {
      tabs[i].position = i + 1
      resolveTitle(at: i)
    }

    if wasActive {
      let newActiveIdx = min(idx, tabs.count - 1)
      tabs[newActiveIdx].isActive = true
      tabs[newActiveIdx].titleMetadata.unseenOutput = false
      if tabs[newActiveIdx].status == .running {
        tabs[newActiveIdx].titleMetadata.activityState = .active
      }
    }
  }

  public func updateTitle(_ title: String, forTab tabId: Tab.ID) throws {
    try updateTerminalTitle(title, forTab: tabId)
  }

  public func updateTerminalTitle(_ title: String?, forTab tabId: Tab.ID) throws {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    guard let sanitized = TerminalTitle.sanitize(title) else { return }
    tabs[idx].titleMetadata.terminalTitle = sanitized
    resolveTitle(at: idx)
  }

  public func renameTab(_ tabId: Tab.ID, title: String) throws {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    guard let sanitized = TerminalTitle.sanitize(title) else {
      try clearUserTitle(forTab: tabId)
      return
    }
    tabs[idx].titleMetadata.userTitle = sanitized
    tabs[idx].titleMetadata.displayTitle = sanitized
    tabs[idx].titleMetadata.titleSource = .user
    tabs[idx].titleMetadata.lastActivityAt = Date()
  }

  public func freezeTitle(forTab tabId: Tab.ID, frozen: Bool = true) throws {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    if frozen, tabs[idx].titleMetadata.userTitle == nil {
      tabs[idx].titleMetadata.userTitle = tabs[idx].titleMetadata.displayTitle
      tabs[idx].titleMetadata.titleSource = .user
    }
    tabs[idx].titleMetadata.titleFrozen = frozen
    resolveTitle(at: idx)
  }

  public func clearUserTitle(forTab tabId: Tab.ID) throws {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    tabs[idx].titleMetadata.userTitle = nil
    tabs[idx].titleMetadata.titleFrozen = false
    resolveTitle(at: idx)
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
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    if let workspace { tabs[idx].titleMetadata.workspace = workspace }
    if let process { tabs[idx].titleMetadata.process = process }
    if let agent { tabs[idx].titleMetadata.agent = agent }
    if let activityState { tabs[idx].titleMetadata.activityState = activityState }
    if let lastActivityAt { tabs[idx].titleMetadata.lastActivityAt = lastActivityAt }
    if let lastOutputAt { tabs[idx].titleMetadata.lastOutputAt = lastOutputAt }
    if let unseenOutput { tabs[idx].titleMetadata.unseenOutput = unseenOutput }
    if let exitStatus { tabs[idx].titleMetadata.exitStatus = exitStatus }
    resolveTitle(at: idx)
  }

  /// Consume any pending title update from the session, apply the title policy,
  /// and update the stored title metadata only when the result differs.
  /// Returns true if title metadata was changed.
  @discardableResult
  public func syncTitle(forTab tabId: Tab.ID, from session: Session) -> Bool {
    let (dirty, raw) = session.consumeTitle()
    guard dirty else { return false }
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    let before = tabs[idx].titleMetadata
    guard let sanitized = TerminalTitle.sanitize(raw) else { return false }
    tabs[idx].titleMetadata.terminalTitle = sanitized
    resolveTitle(at: idx)
    return tabs[idx].titleMetadata != before
  }

  @discardableResult
  public func syncProcessMetadata(
    forTab tabId: Tab.ID,
    from session: Session,
    now: Date = Date()
  ) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    if let last = lastProcessMetadataSyncAtByTab[tabId],
      now.timeIntervalSince(last) < processMetadataSyncInterval
    {
      return false
    }
    lastProcessMetadataSyncAtByTab[tabId] = now

    guard let metadata = session.processMetadata() else { return false }
    let before = tabs[idx].titleMetadata

    var workspace = tabs[idx].titleMetadata.workspace
    if let cwd = metadata.cwd {
      workspace.cwd = cwd
    }

    var process = tabs[idx].titleMetadata.process
    process.foregroundProcess = metadata.foregroundProcess
    process.foregroundCommand = metadata.foregroundCommand
    process.pid = metadata.foregroundPid

    tabs[idx].titleMetadata.workspace = workspace
    tabs[idx].titleMetadata.process = process
    resolveTitle(at: idx)
    return tabs[idx].titleMetadata != before
  }

  /// Read exit state from the session and record it in the tab.
  /// Exit state is monotonic: once a tab is non-running, this is a no-op.
  /// Returns true if the tab status changed.
  @discardableResult
  public func syncExitState(forTab tabId: Tab.ID, from session: Session) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    guard tabs[idx].status == .running else { return false }
    let s = session.exitState()
    guard s != .running else { return false }
    tabs[idx].status = s
    tabs[idx].titleMetadata.activityState = .exited
    switch s {
    case .exited(let code), .exitedSignal(let code):
      tabs[idx].titleMetadata.exitStatus = code
    case .running:
      break
    }
    return true
  }

  /// Force-sets a tab's status directly. Internal; exposed for unit tests only.
  func forceExitState(forTab tabId: Tab.ID, status: TabStatus) {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    tabs[idx].status = status
    if status != .running {
      tabs[idx].titleMetadata.activityState = .exited
      switch status {
      case .exited(let code), .exitedSignal(let code):
        tabs[idx].titleMetadata.exitStatus = code
      case .running:
        break
      }
    }
  }

  @discardableResult
  public func noteOutput(forTab tabId: Tab.ID, at date: Date = Date()) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    let before = tabs[idx].titleMetadata
    tabs[idx].titleMetadata.lastOutputAt = date
    tabs[idx].titleMetadata.lastActivityAt = date
    if tabs[idx].status == .running {
      if tabs[idx].isActive {
        tabs[idx].titleMetadata.unseenOutput = false
        tabs[idx].titleMetadata.activityState = .active
      } else {
        tabs[idx].titleMetadata.unseenOutput = true
        tabs[idx].titleMetadata.activityState = .unseenOutput
      }
    }
    resolveTitle(at: idx)
    return tabs[idx].titleMetadata != before
  }

  /// The display title for the AppKit window: active tab title, or "Laban" as fallback.
  public var windowTitle: String {
    guard let title = activeTab?.title, !title.isEmpty else { return "Laban" }
    return title
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
    let rows = Int32(max(1, viewportHeight / cellHeight))
    let cols = Int32(max(1, viewportWidth / cellWidth))
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    currentSize = size
    for session in sessions.values {
      if session.resize(size) == 0 {
        var event = CaptureTimelineEvent(kind: .sessionResized, sessionId: session.id)
        event.rows = Int(rows)
        event.cols = Int(cols)
        event.pixelWidth = viewportWidth
        event.pixelHeight = viewportHeight
        event.cellWidth = cellWidth
        event.cellHeight = cellHeight
        captureSink?.record(event)
      }
    }
  }

  private func resolveTitle(at idx: Int) {
    tabs[idx].titleMetadata = TabTitleResolver.resolvedMetadata(
      tabs[idx].titleMetadata,
      fallbackPosition: tabs[idx].position
    )
  }

  public func allSessions() -> [(tab: Tab, session: Session)] {
    tabs.compactMap { tab in
      guard let session = sessions[tab.sessionId] else { return nil }
      return (tab, session)
    }
  }

  public func recordExistingStateForCapture() {
    captureSink?.record(CaptureTimelineEvent(kind: .appState))
    for tab in tabs {
      recordSessionCreated(sessionId: tab.sessionId, tabId: tab.id)
      recordTab(.tabCreated, tabId: tab.id, sessionId: tab.sessionId)
      if tab.isActive {
        recordTab(.tabSelected, tabId: tab.id, sessionId: tab.sessionId)
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
}

@usableFromInline
func defaultSize() -> LabanTerminalSize {
  var s = LabanTerminalSize()
  s.rows = 24
  s.cols = 80
  return s
}
