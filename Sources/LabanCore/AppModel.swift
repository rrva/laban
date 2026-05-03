import Foundation
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
    tabs[idx].title = title
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
