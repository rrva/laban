import Foundation
import LabanRenderer
import LabanTerminalCore

public final class AppModel {
  public static let maxTabs = 9

  public private(set) var tabs: [Tab] = []
  private var sessions: [Session.ID: Session] = [:]
  private var currentSize: LabanTerminalSize
  private let sessionFactory: (LabanTerminalSize) throws -> Session

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
    AppModel.maybeAutoCapture(session)
    AppModel.applyThemePalette(to: session)
    let position = tabs.count + 1
    var tab = Tab(
      id: UUID().uuidString,
      position: position,
      title: "Tab \(position)",
      isActive: false,
      sessionId: session.id
    )
    sessions[session.id] = session
    tabs.append(tab)
    selectTab(tab.id)
    tab.isActive = true
    return tabs.last!
  }

  public func selectTab(_ tabId: Tab.ID) {
    for i in tabs.indices {
      tabs[i].isActive = (tabs[i].id == tabId)
    }
  }

  public func closeTab(_ tabId: Tab.ID) throws {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    let tab = tabs[idx]

    if tabs.count == 1 {
      // Replace final tab: close current, open fresh
      let newSession = try sessionFactory(currentSize)
      AppModel.maybeAutoCapture(newSession)
      AppModel.applyThemePalette(to: newSession)
      let newTab = Tab(
        id: UUID().uuidString,
        position: 1,
        title: "Tab 1",
        isActive: true,
        sessionId: newSession.id
      )
      sessions[tab.sessionId]?.close()
      sessions.removeValue(forKey: tab.sessionId)
      sessions[newSession.id] = newSession
      tabs = [newTab]
      return
    }

    // Determine next active tab before removing
    let wasActive = tab.isActive
    sessions[tab.sessionId]?.close()
    sessions.removeValue(forKey: tab.sessionId)
    tabs.remove(at: idx)

    // Recompute one-based positions
    for i in tabs.indices {
      tabs[i].position = i + 1
    }

    if wasActive {
      let newActiveIdx = min(idx, tabs.count - 1)
      tabs[newActiveIdx].isActive = true
    }
  }

  public func updateTitle(_ title: String, forTab tabId: Tab.ID) throws {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else {
      throw AppError.tabNotFound
    }
    guard let sanitized = TerminalTitle.sanitize(title) else { return }
    tabs[idx].title = sanitized
  }

  /// Consume any pending title update from the session, apply the title policy,
  /// and update the stored tab title only when the result differs.
  /// Returns true if the tab title was changed.
  @discardableResult
  public func syncTitle(forTab tabId: Tab.ID, from session: Session) -> Bool {
    let (dirty, raw) = session.consumeTitle()
    guard dirty else { return false }
    guard let sanitized = TerminalTitle.sanitize(raw) else { return false }
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    guard tabs[idx].title != sanitized else { return false }
    tabs[idx].title = sanitized
    return true
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
    return true
  }

  /// Force-sets a tab's status directly. Internal; exposed for unit tests only.
  func forceExitState(forTab tabId: Tab.ID, status: TabStatus) {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    tabs[idx].status = status
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
      session.resize(size)
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
