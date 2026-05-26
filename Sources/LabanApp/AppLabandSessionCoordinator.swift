import Foundation
import LabanCore
import LabanTerminalCore

final class AppLabandSessionCoordinator {
  private let client: LabandTerminalSessionClient
  private let shellLaunch: ShellIntegrationLaunch
  private let cwdByTabId: [Tab.ID: String]
  private var infoByTabId: [Tab.ID: LabandSessionInfo] = [:]
  private var infoByLocalSessionId: [Session.ID: LabandSessionInfo] = [:]
  private var labandProcess: Process?

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
      return controlled
    }

    let request = launchRequest(for: tab, size: size)
    let created = try client.createSession(request)
    store(created, for: tab)
    attachSnapshotRing(for: created.logicalSessionId)
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
