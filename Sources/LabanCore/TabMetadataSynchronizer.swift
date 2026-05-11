import Foundation

/// Synchronizes session-derived metadata into tab state.
///
/// `AppModel` owns the model lock and passes its tab array inout while locked.
/// This type owns the bookkeeping that decides whether a terminal title still
/// belongs to the current foreground process and when process metadata may be
/// polled again.
final class TabMetadataSynchronizer {
  typealias BranchResolved = @Sendable (_ branch: String?, _ tabId: Tab.ID, _ cwd: String) -> Void

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

  private var lastProcessMetadataSyncAtByTab: [Tab.ID: Date] = [:]
  private var processIdentityByTab: [Tab.ID: ProcessIdentity] = [:]
  private var terminalTitleOwnerByTab: [Tab.ID: ProcessIdentity] = [:]
  private let processMetadataSyncInterval: TimeInterval = 0.25
  private let gitInfo = GitInfoTracker()

  func reset(closedCwds: [String]) {
    for cwd in closedCwds {
      gitInfo.forget(cwd: cwd)
    }
    lastProcessMetadataSyncAtByTab.removeAll()
    processIdentityByTab.removeAll()
    terminalTitleOwnerByTab.removeAll()
  }

  func forget(tab: Tab) {
    if let cwd = tab.titleMetadata.workspace.cwd {
      gitInfo.forget(cwd: cwd)
    }
    lastProcessMetadataSyncAtByTab.removeValue(forKey: tab.id)
    processIdentityByTab.removeValue(forKey: tab.id)
    terminalTitleOwnerByTab.removeValue(forKey: tab.id)
  }

  @discardableResult
  func syncTitle(forTab tabId: Tab.ID, from session: Session, tabs: inout [Tab]) -> Bool {
    let (dirty, raw) = session.consumeTitle()
    guard dirty else { return false }
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    let before = tabs[idx].titleMetadata
    setTerminalTitle(TerminalTitle.sanitize(raw), forTab: tabId, at: idx, tabs: &tabs)
    Self.resolveTitle(in: &tabs, at: idx)
    return tabs[idx].titleMetadata != before
  }

  @discardableResult
  func syncProcessMetadata(
    forTab tabId: Tab.ID,
    from session: Session,
    now: Date,
    tabs: inout [Tab],
    onBranchResolved: @escaping BranchResolved
  ) -> Bool {
    guard tabs.contains(where: { $0.id == tabId }) else { return false }
    if let last = lastProcessMetadataSyncAtByTab[tabId],
      now.timeIntervalSince(last) < processMetadataSyncInterval
    {
      return false
    }
    lastProcessMetadataSyncAtByTab[tabId] = now

    guard let metadata = session.processMetadata() else { return false }
    return applyProcessMetadata(
      metadata,
      forTab: tabId,
      now: now,
      tabs: &tabs,
      onBranchResolved: onBranchResolved
    )
  }

  @discardableResult
  func applyProcessMetadata(
    _ metadata: Session.ProcessMetadata,
    forTab tabId: Tab.ID,
    now: Date,
    tabs: inout [Tab],
    onBranchResolved: @escaping BranchResolved
  ) -> Bool {
    _ = now
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    let before = tabs[idx].titleMetadata
    let newIdentity = ProcessIdentity(metadata)
    let oldIdentity = processIdentityByTab[tabId]
    let processChanged = oldIdentity != nil && oldIdentity != newIdentity

    if processChanged {
      tabs[idx].titleMetadata.terminalTitle = nil
      terminalTitleOwnerByTab.removeValue(forKey: tabId)
    } else if let owner = terminalTitleOwnerByTab[tabId], owner != newIdentity {
      tabs[idx].titleMetadata.terminalTitle = nil
      terminalTitleOwnerByTab.removeValue(forKey: tabId)
    } else if terminalTitleOwnerByTab[tabId] == nil,
      tabs[idx].titleMetadata.terminalTitle != nil,
      let newIdentity
    {
      terminalTitleOwnerByTab[tabId] = newIdentity
    }

    if let newIdentity {
      processIdentityByTab[tabId] = newIdentity
    } else {
      processIdentityByTab.removeValue(forKey: tabId)
    }

    var workspace = tabs[idx].titleMetadata.workspace
    if let cwd = metadata.cwd {
      workspace.cwd = cwd
      gitInfo.refresh(cwd: cwd) { resolvedCwd, branch in
        onBranchResolved(branch, tabId, resolvedCwd)
      }
    }

    var process = tabs[idx].titleMetadata.process
    process.foregroundProcess = metadata.foregroundProcess
    process.foregroundCommand = metadata.foregroundCommand
    process.pid = metadata.foregroundPid

    tabs[idx].titleMetadata.workspace = workspace
    tabs[idx].titleMetadata.process = process
    Self.resolveTitle(in: &tabs, at: idx)
    return tabs[idx].titleMetadata != before
  }

  @discardableResult
  func syncExitState(forTab tabId: Tab.ID, from session: Session, tabs: inout [Tab]) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    guard tabs[idx].status == .running else { return false }
    let state = session.exitState()
    guard state != .running else { return false }
    tabs[idx].status = state
    tabs[idx].titleMetadata.activityState = .exited
    switch state {
    case .exited(let code), .exitedSignal(let code):
      tabs[idx].titleMetadata.exitStatus = code
    case .running:
      break
    }
    return true
  }

  @discardableResult
  func noteOutput(forTab tabId: Tab.ID, at date: Date, tabs: inout [Tab]) -> Bool {
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
    Self.resolveTitle(in: &tabs, at: idx)
    return tabs[idx].titleMetadata != before
  }

  @discardableResult
  func applyResolvedBranch(
    _ branch: String?,
    forTab tabId: Tab.ID,
    cwd: String,
    tabs: inout [Tab]
  ) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    guard tabs[idx].titleMetadata.workspace.cwd == cwd else { return false }
    guard tabs[idx].titleMetadata.workspace.branch != branch else { return false }
    tabs[idx].titleMetadata.workspace.branch = branch
    Self.resolveTitle(in: &tabs, at: idx)
    return true
  }

  func setTerminalTitle(_ title: String?, forTab tabId: Tab.ID, at idx: Int, tabs: inout [Tab]) {
    tabs[idx].titleMetadata.terminalTitle = title
    if title != nil, let owner = processIdentityByTab[tabId] {
      terminalTitleOwnerByTab[tabId] = owner
    } else {
      terminalTitleOwnerByTab.removeValue(forKey: tabId)
    }
  }

  static func resolveTitle(in tabs: inout [Tab], at idx: Int) {
    tabs[idx].titleMetadata = TabTitleResolver.resolvedMetadata(
      tabs[idx].titleMetadata,
      fallbackPosition: tabs[idx].position
    )
  }
}
