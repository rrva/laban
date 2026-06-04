import Foundation

/// Synchronizes session-derived metadata into tab state.
///
/// `AppModel` owns the model lock and passes its tab array inout while locked.
/// This type owns the bookkeeping that decides whether a terminal title still
/// belongs to the current foreground process and when process metadata may be
/// polled again.
/// The signals `TabMetadataSynchronizer.syncSurfaceMetadata` applies on
/// every cycle. Built from a local `Session` for in-process tabs, or
/// synthesized from a `LabandSessionInfo` for laband-backed tabs. Holding
/// the shape in one place is what keeps the two writer paths from drifting:
/// both feed the same apply method with the same struct and inherit one
/// canonical policy. The bug this consolidation fixes: with two writers
/// operating on the same `TabMetadataSynchronizer` instance, the local
/// fixture's empty `processMetadata` was clobbering the daemon-supplied
/// identity every other frame, flip-flopping the tab title between "~" and
/// "~\nzsh" at 4 Hz.
public struct TabSurfaceSignals {
  /// `nil` means "no process-metadata update this cycle" (caller is
  /// throttled or has nothing to say). Non-nil flows through
  /// `applyProcessMetadata`, where the existing identity-change policy
  /// also clears the terminal title when the foreground process changes.
  public var processMetadata: Session.ProcessMetadata?
  /// Matches the `consumeTitle()` contract: `dirty=true` carries a
  /// candidate raw title to apply (`nil` raw clears). `dirty=false` is
  /// "no title update this cycle." Idempotent re-applies are safe — the
  /// inner `syncTitle` compares before/after and reports modelChanged
  /// only on real changes.
  public var titleDirty: Bool
  public var titleRaw: String?
  /// `.running` means "no exit-state update" — non-running transitions
  /// the tab status exactly once.
  public var exitState: TabStatus
  /// `nil` means "leave agent status alone." Non-nil is an explicit
  /// surface-owned status, used for transport degradation that is not
  /// emitted by the child process itself.
  public var agentStatus: TabAgentStatus?
  /// `nil` means "no shell-integration update this cycle." Local sessions can
  /// report their live OSC 133 state directly; daemon-backed sessions omit this
  /// until they have an authoritative source.
  public var shellIntegrationState: ShellIntegrationState?

  public init(
    processMetadata: Session.ProcessMetadata? = nil,
    titleDirty: Bool = false,
    titleRaw: String? = nil,
    exitState: TabStatus = .running,
    agentStatus: TabAgentStatus? = nil,
    shellIntegrationState: ShellIntegrationState? = nil
  ) {
    self.processMetadata = processMetadata
    self.titleDirty = titleDirty
    self.titleRaw = titleRaw
    self.exitState = exitState
    self.agentStatus = agentStatus
    self.shellIntegrationState = shellIntegrationState
  }
}

final class TabMetadataSynchronizer {
  typealias BranchResolved = @Sendable (_ branch: String?, _ tabId: Tab.ID, _ cwd: String) -> Void

  struct SurfaceMetadataSyncResult {
    var modelChanged = false
    var processMetadataChanged = false
    var titleChangedTab: Tab?
  }

  private struct ProcessIdentity: Equatable {
    var pid: Int?
    var process: String?
    var command: String?
    var arguments: [String]?

    init?(_ metadata: Session.ProcessMetadata) {
      let pid = metadata.foregroundPid ?? metadata.childPid
      let process = TerminalTitle.sanitize(metadata.foregroundProcess)
      let command = TerminalTitle.sanitize(metadata.foregroundCommand)
      let arguments = metadata.foregroundArguments?.compactMap { TerminalTitle.sanitize($0) }
      guard pid != nil || process != nil || command != nil || arguments?.isEmpty == false else {
        return nil
      }
      self.pid = pid
      self.process = process
      self.command = command
      self.arguments = arguments?.isEmpty == false ? arguments : nil
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
    return syncTitle(raw: raw, forTab: tabId, at: idx, tabs: &tabs)
  }

  @discardableResult
  private func syncTitle(raw: String?, forTab tabId: Tab.ID, at idx: Int, tabs: inout [Tab])
    -> Bool
  {
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
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
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
      at: idx,
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
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    return applyProcessMetadata(
      metadata,
      forTab: tabId,
      at: idx,
      now: now,
      tabs: &tabs,
      onBranchResolved: onBranchResolved
    )
  }

  @discardableResult
  private func applyProcessMetadata(
    _ metadata: Session.ProcessMetadata,
    forTab tabId: Tab.ID,
    at idx: Int,
    now: Date,
    tabs: inout [Tab],
    onBranchResolved: @escaping BranchResolved
  ) -> Bool {
    _ = now
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
    process.foregroundArguments = metadata.foregroundArguments
    process.pid = metadata.foregroundPid

    tabs[idx].titleMetadata.workspace = workspace
    tabs[idx].titleMetadata.process = process
    Self.resolveTitle(in: &tabs, at: idx)
    return tabs[idx].titleMetadata != before
  }

  @discardableResult
  func syncExitState(forTab tabId: Tab.ID, from session: Session, tabs: inout [Tab]) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    return applyExitState(session.exitState(), at: idx, tabs: &tabs)
  }

  @discardableResult
  private func applyExitState(_ state: TabStatus, at idx: Int, tabs: inout [Tab]) -> Bool {
    guard tabs[idx].status == .running else { return false }
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
    return noteOutput(forTab: tabId, at: idx, date: date, tabs: &tabs)
  }

  @discardableResult
  func noteOutput(forTab tabId: Tab.ID, at idx: Int, date: Date, tabs: inout [Tab]) -> Bool {
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
  func noteBell(forTab tabId: Tab.ID, at date: Date, tabs: inout [Tab]) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    let before = tabs[idx].titleMetadata
    tabs[idx].titleMetadata.lastActivityAt = date
    if tabs[idx].status == .running {
      tabs[idx].titleMetadata.bellAttention = !tabs[idx].isActive
    }
    Self.resolveTitle(in: &tabs, at: idx)
    return tabs[idx].titleMetadata != before
  }

  func syncSurfaceMetadata(
    forTab tabId: Tab.ID,
    at idx: Int,
    from session: Session,
    now: Date,
    tabs: inout [Tab],
    onBranchResolved: @escaping BranchResolved
  ) -> SurfaceMetadataSyncResult {
    let throttled: Bool
    if let last = lastProcessMetadataSyncAtByTab[tabId],
      now.timeIntervalSince(last) < processMetadataSyncInterval
    {
      throttled = true
    } else {
      throttled = false
      lastProcessMetadataSyncAtByTab[tabId] = now
    }
    let (titleDirty, titleRaw) = session.consumeTitle()
    let signals = TabSurfaceSignals(
      processMetadata: throttled ? nil : session.processMetadata(),
      titleDirty: titleDirty,
      titleRaw: titleRaw,
      exitState: session.exitState(),
      shellIntegrationState: session.shellIntegrationState()
    )
    return syncSurfaceMetadata(
      forTab: tabId,
      at: idx,
      signals: signals,
      now: now,
      tabs: &tabs,
      onBranchResolved: onBranchResolved
    )
  }

  /// Canonical surface-metadata apply. Both the local-session writer (via
  /// the `from session:` wrapper above) and the laband coordinator
  /// (`AppSessionCoordinator.refreshTabMetadata`) funnel through
  /// here so neither path can develop its own slightly-different write
  /// policy.
  func syncSurfaceMetadata(
    forTab tabId: Tab.ID,
    at idx: Int,
    signals: TabSurfaceSignals,
    now: Date,
    tabs: inout [Tab],
    onBranchResolved: @escaping BranchResolved
  ) -> SurfaceMetadataSyncResult {
    guard tabs.indices.contains(idx), tabs[idx].id == tabId else {
      return SurfaceMetadataSyncResult()
    }

    var result = SurfaceMetadataSyncResult()
    if let metadata = signals.processMetadata,
      applyProcessMetadata(
        metadata,
        forTab: tabId,
        at: idx,
        now: now,
        tabs: &tabs,
        onBranchResolved: onBranchResolved
      )
    {
      result.modelChanged = true
      result.processMetadataChanged = true
    }

    if signals.titleDirty,
      syncTitle(raw: signals.titleRaw, forTab: tabId, at: idx, tabs: &tabs)
    {
      result.modelChanged = true
      result.titleChangedTab = tabs[idx]
    }

    if applyExitState(signals.exitState, at: idx, tabs: &tabs) {
      result.modelChanged = true
    }

    if let agentStatus = signals.agentStatus,
      tabs[idx].titleMetadata.agentStatus != agentStatus
    {
      tabs[idx].titleMetadata.agentStatus = agentStatus
      result.modelChanged = true
    }

    if let shellIntegrationState = signals.shellIntegrationState {
      let metadata = tabs[idx].titleMetadata
      if metadata.shellPhase != shellIntegrationState.phase
        || metadata.lastCommandExitCode != shellIntegrationState.lastExitCode
      {
        tabs[idx].titleMetadata.shellPhase = shellIntegrationState.phase
        tabs[idx].titleMetadata.lastCommandExitCode = shellIntegrationState.lastExitCode
        result.modelChanged = true
      }
    }

    return result
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
