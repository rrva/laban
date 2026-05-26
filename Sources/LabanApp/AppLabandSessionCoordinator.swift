import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class AppLabandSessionCoordinator {
  private let client: LabandTerminalSessionClient
  private let shellLaunch: ShellIntegrationLaunch
  private let cwdByTabId: [Tab.ID: String]
  private let supportsThemeApplication: Bool
  private let supportsViewportScroll: Bool
  private var infoByTabId: [Tab.ID: LabandSessionInfo] = [:]
  private var infoByLocalSessionId: [Session.ID: LabandSessionInfo] = [:]
  private var labandProcess: Process?
  private var themeChangeObserver: NSObjectProtocol?

  init(
    client: LabandTerminalSessionClient,
    shellLaunch: ShellIntegrationLaunch,
    cwdByTabId: [Tab.ID: String] = [:],
    labandProcess: Process? = nil
  ) {
    self.client = client
    self.shellLaunch = shellLaunch
    self.cwdByTabId = cwdByTabId
    self.labandProcess = labandProcess
    let capabilities = (try? client.hello().capabilities) ?? []
    self.supportsThemeApplication = capabilities.contains("theme-palette/v1")
    self.supportsViewportScroll = capabilities.contains("viewport-scroll/v1")
    self.themeChangeObserver = NotificationCenter.default.addObserver(
      forName: Theme.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.applyCurrentThemeToKnownSessions()
    }
  }

  deinit {
    removeThemeChangeObserver()
  }

  var transportMode: String { client.transportMode }
  var terminalClient: TerminalSessionClient { client }

  func ensureSessions(for tabs: [Tab], size: LabanTerminalSize) throws {
    for tab in tabs {
      _ = try ensureSession(for: tab, size: size)
    }
  }

  @discardableResult
  func ensureSession(for tab: Tab, size: LabanTerminalSize) throws -> LabandSessionInfo {
    if let cached = infoByTabId[tab.id], cached.lifecycleState == .running {
      return cached
    }

    if let attached = try? client.attachSession(logicalSessionId: tab.id),
      attached.lifecycleState == .running
    {
      let controlled = try ensureControlLease(attached)
      store(controlled, for: tab)
      attachSnapshotRing(for: controlled.logicalSessionId)
      applyCurrentTheme(to: controlled.logicalSessionId)
      return controlled
    }

    let request = launchRequest(for: tab, size: size)
    let created = try client.createSession(request)
    store(created, for: tab)
    attachSnapshotRing(for: created.logicalSessionId)
    applyCurrentTheme(to: created.logicalSessionId)
    return created
  }

  func sessionInfo(for tab: Tab) -> LabandSessionInfo? {
    infoByTabId[tab.id] ?? infoByLocalSessionId[tab.sessionId]
  }

  func snapshot(for tab: Tab, size: LabanTerminalSize) throws -> LabandSnapshotResponse {
    let info = try ensureSession(for: tab, size: size)
    return try client.snapshot(sessionId: info.logicalSessionId)
  }

  func write(_ bytes: [UInt8], to tab: Tab, size: LabanTerminalSize) throws {
    guard !bytes.isEmpty else { return }
    let info = try ensureSession(for: tab, size: size)
    try client.writeInput(sessionId: info.logicalSessionId, bytes: bytes)
    if let refreshed = try? client.attachSession(logicalSessionId: info.logicalSessionId) {
      store(refreshed, for: tab)
    }
  }

  func resize(tabs: [Tab], size: LabanTerminalSize) {
    for tab in tabs {
      do {
        let info = try ensureSession(for: tab, size: size)
        let resized = try client.resize(
          sessionId: info.logicalSessionId,
          rows: Int(size.rows),
          cols: Int(size.cols)
        )
        store(resized, for: tab)
      } catch {
        AppLog.app.error("laband resize failed for tab \(tab.id): \(String(describing: error))")
      }
    }
  }

  @discardableResult
  func scrollViewport(tab: Tab, size: LabanTerminalSize, deltaRows: Int) throws -> Bool {
    guard supportsViewportScroll, deltaRows != 0 else { return false }
    let info = try ensureSession(for: tab, size: size)
    let scrolled = try client.scrollViewport(
      sessionId: info.logicalSessionId,
      deltaRows: deltaRows
    )
    store(scrolled, for: tab)
    return true
  }

  func markRendered(tab: Tab) {
    guard let info = sessionInfo(for: tab) else { return }
    try? client.markRendered(sessionId: info.logicalSessionId)
  }

  func terminate(tab: Tab) {
    do {
      let info = try ensureSession(for: tab, size: fallbackSize())
      let terminated = try client.terminate(sessionId: info.logicalSessionId)
      store(terminated, for: tab)
    } catch {
      AppLog.app.error("laband terminate failed for tab \(tab.id): \(String(describing: error))")
    }
    infoByTabId.removeValue(forKey: tab.id)
    infoByLocalSessionId.removeValue(forKey: tab.sessionId)
  }

  func detach() {
    removeThemeChangeObserver()
    client.close()
    infoByTabId.removeAll()
    infoByLocalSessionId.removeAll()
    labandProcess = nil
  }

  private func ensureControlLease(_ info: LabandSessionInfo) throws -> LabandSessionInfo {
    guard info.lease?.holderClientId != client.clientIdentifier else { return info }
    return try client.transferLease(
      sessionId: info.logicalSessionId,
      holderClientId: client.clientIdentifier
    )
  }

  private func store(_ info: LabandSessionInfo, for tab: Tab) {
    infoByTabId[tab.id] = info
    infoByLocalSessionId[tab.sessionId] = info
  }

  private func attachSnapshotRing(for logicalSessionId: String) {
    _ = try? client.attachSnapshotRing(sessionId: logicalSessionId)
  }

  private func applyCurrentThemeToKnownSessions() {
    let logicalSessionIds = Set(infoByTabId.values.map(\.logicalSessionId))
    for logicalSessionId in logicalSessionIds {
      applyCurrentTheme(to: logicalSessionId)
    }
  }

  private func applyCurrentTheme(to logicalSessionId: String) {
    guard supportsThemeApplication else { return }
    let theme = Theme.current
    let colorScheme: TerminalColorScheme = theme.isDark ? .dark : .light
    do {
      try client.applyTheme(
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

  private func fallbackSize() -> LabanTerminalSize {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return size
  }
}
