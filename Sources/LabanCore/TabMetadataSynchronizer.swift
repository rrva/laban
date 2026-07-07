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
  /// Per-tab high-water mark of `ShellIntegrationState.completedCommandCount`
  /// the user has acknowledged by viewing the tab. The failed-command dot
  /// only arms for a completion newer than this, so a dot dismissed by
  /// focusing the tab stays dismissed across prompt re-emissions and metadata
  /// syncs, yet a genuinely new failing command re-arms it.
  private var acknowledgedCommandCountByTab: [Tab.ID: Int] = [:]
  private let processMetadataSyncInterval: TimeInterval = 0.25

  /// Probes whether the recorded title-owner pid is still running. kill(pid, 0)
  /// checks existence without delivering a signal; EPERM still proves liveness.
  /// Injectable so unit tests can pin the owner's fate deterministically.
  var processIsAlive: (Int?) -> Bool = { pid in
    guard let pid, pid > 0 else { return false }
    if kill(pid_t(pid), 0) == 0 { return true }
    return errno == EPERM
  }
  private let gitInfo = GitInfoTracker()

  func reset(closedCwds: [String]) {
    for cwd in closedCwds {
      gitInfo.forget(cwd: cwd)
    }
    lastProcessMetadataSyncAtByTab.removeAll()
    processIdentityByTab.removeAll()
    terminalTitleOwnerByTab.removeAll()
    acknowledgedCommandCountByTab.removeAll()
  }

  /// Mark every command that has finished so far on `tabId` as acknowledged —
  /// the user is now looking at (or has just left) the tab, so its last
  /// command's outcome has been seen. Wired to tab selection in `AppModel`.
  func acknowledgeShellCommands(forTab tabId: Tab.ID, upTo count: Int) {
    acknowledgedCommandCountByTab[tabId] = count
  }

  /// The exit code the steady failed-command dot should show for `tabId`, or
  /// nil for no dot. A non-zero exit only arms the dot while it is a *new*,
  /// unacknowledged completion on a background tab. The active tab is the user
  /// watching: every completion so far is acknowledged (so a foreground
  /// failure never arms, and leaving the tab can't later reveal one).
  func resolveFailedCommandDot(
    forTab tabId: Tab.ID,
    state: ShellIntegrationState,
    isActive: Bool
  ) -> Int? {
    if isActive {
      acknowledgedCommandCountByTab[tabId] = state.completedCommandCount
      return nil
    }
    let acknowledged = acknowledgedCommandCountByTab[tabId] ?? 0
    guard state.completedCommandCount > acknowledged,
      let code = state.lastExitCode, code != 0
    else { return nil }
    return code
  }

  func forget(tab: Tab) {
    if let cwd = tab.titleMetadata.workspace.cwd {
      gitInfo.forget(cwd: cwd)
    }
    lastProcessMetadataSyncAtByTab.removeValue(forKey: tab.id)
    processIdentityByTab.removeValue(forKey: tab.id)
    terminalTitleOwnerByTab.removeValue(forKey: tab.id)
    acknowledgedCommandCountByTab.removeValue(forKey: tab.id)
  }

  @discardableResult
  func syncTitle(forTab tabId: Tab.ID, from session: Session, tabs: inout [Tab]) -> Bool {
    // Resolve the tab before consuming: consumeTitle clears the C-side dirty
    // flag, so consuming first permanently drops a title that arrives while
    // the tab is mid-rebuild and not present in the array yet.
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    let (dirty, raw) = session.consumeTitle()
    guard dirty else { return false }
    return syncTitle(raw: raw, forTab: tabId, at: idx, ownerIsFresh: false, tabs: &tabs)
  }

  @discardableResult
  private func syncTitle(
    raw: String?,
    forTab tabId: Tab.ID,
    at idx: Int,
    ownerIsFresh: Bool,
    tabs: inout [Tab]
  )
    -> Bool
  {
    let before = tabs[idx].titleMetadata
    setTerminalTitle(
      TerminalTitle.sanitize(raw),
      forTab: tabId,
      at: idx,
      ownerIsFresh: ownerIsFresh,
      tabs: &tabs
    )
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

    // A foreground-identity change alone must not destroy the title: agents
    // flutter the foreground pid on every tool subprocess while the title's
    // owner keeps running and only re-sends sporadically, so wiping on change
    // made the displayed title a race between the last wipe and the last
    // re-send. Staleness is an ownership-liveness question: clear the title
    // only once the recorded owner process is actually gone.
    if let owner = terminalTitleOwnerByTab[tabId], owner != newIdentity,
      !processIsAlive(owner.pid)
    {
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
    // Per the tab-status contract, activity metadata must not outlive the
    // process that reported it: a dead session showing a live indicator,
    // an awaiting-input pulse, or a progress bar would be lying.
    tabs[idx].titleMetadata.agentStatus = TabAgentStatus()
    tabs[idx].titleMetadata.agent.awaitingInput = false
    tabs[idx].titleMetadata.progress = nil
    return true
  }

  @discardableResult
  func noteOutput(forTab tabId: Tab.ID, at date: Date, tabs: inout [Tab]) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    return noteOutput(forTab: tabId, at: idx, date: date, tabs: &tabs)
  }

  @discardableResult
  func noteOutput(forTab tabId: Tab.ID, at idx: Int, date: Date, tabs: inout [Tab]) -> Bool {
    // Activity timestamps live on Tab, not titleMetadata: writing them here no
    // longer mutates the title struct, so an output tick can't churn the
    // sidebar's metadata-keyed cache.
    tabs[idx].lastOutputAt = date
    tabs[idx].lastActivityAt = date
    guard tabs[idx].status == .running else { return false }
    let wantUnseen = !tabs[idx].isActive
    let wantState: TabActivityState = tabs[idx].isActive ? .active : .unseenOutput
    // Steady streaming on an already-active or already-unseen tab changes
    // nothing the sidebar renders. Short-circuit before the title struct copy,
    // re-resolve, and the `modelChanged` it would report — the per-output-tick
    // cost the profiler flagged.
    guard
      tabs[idx].titleMetadata.unseenOutput != wantUnseen
        || tabs[idx].titleMetadata.activityState != wantState
    else { return false }
    tabs[idx].titleMetadata.unseenOutput = wantUnseen
    tabs[idx].titleMetadata.activityState = wantState
    Self.resolveTitle(in: &tabs, at: idx)
    return true
  }

  @discardableResult
  func noteBell(forTab tabId: Tab.ID, at date: Date, tabs: inout [Tab]) -> Bool {
    guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    let before = tabs[idx].titleMetadata
    tabs[idx].lastActivityAt = date
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
      syncTitle(
        raw: signals.titleRaw,
        forTab: tabId,
        at: idx,
        ownerIsFresh: signals.processMetadata != nil,
        tabs: &tabs
      )
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
      let exitCode = resolveFailedCommandDot(
        forTab: tabId,
        state: shellIntegrationState,
        isActive: tabs[idx].isActive)
      if metadata.shellPhase != shellIntegrationState.phase
        || metadata.lastCommandExitCode != exitCode
      {
        tabs[idx].titleMetadata.shellPhase = shellIntegrationState.phase
        tabs[idx].titleMetadata.lastCommandExitCode = exitCode
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

  func setTerminalTitle(
    _ title: String?,
    forTab tabId: Tab.ID,
    at idx: Int,
    ownerIsFresh: Bool = true,
    tabs: inout [Tab]
  ) {
    tabs[idx].titleMetadata.terminalTitle = title
    if title != nil, ownerIsFresh, let owner = processIdentityByTab[tabId] {
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
