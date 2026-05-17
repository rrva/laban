import Foundation
import LabanCore
import LabanTerminalCore

/// Per-tab orchestrator that owns one `AgentSessionDetector` and
/// drives the `AgentJSONLMirror` based on its observations. AppModel
/// calls the host on tab creation (so a fresh detector starts polling
/// the new shell's descendants) and on tab close (so the detector
/// timer cancels and the mirror takes one final snapshot).
///
/// The orchestrator routes every detector observation into AppModel
/// (`updateAgent(_:forTab:)`) so the captured `AgentInfo` ends up in
/// `WorkspaceState.tabs[].agent` when the persistence coordinator
/// next saves.
public final class AgentObserverHost: AgentSessionDetectorObserver {
  private let appModel: AppModel
  private let mirror: JSONLMirroring
  private let isEnabled: () -> Bool

  private let lock = NSLock()
  private var detectorsByTab: [String: AgentSessionDetector] = [:]

  public init(
    appModel: AppModel,
    mirror: JSONLMirroring,
    isEnabled: @escaping () -> Bool = { RestoreOnLaunchSettings.isEnabled }
  ) {
    self.appModel = appModel
    self.mirror = mirror
    self.isEnabled = isEnabled
  }

  /// Begin watching `session`'s shell descendants for the configured
  /// agent binaries. No-op when the session has no PID (fixture
  /// mode); detectors only make sense against real PTY children.
  /// No-op when the kill-switch toggle is off — detector and mirror
  /// stay completely dormant per the plan's toggle contract.
  public func attach(session: Session, tabId: String) {
    guard isEnabled() else { return }
    guard let pid = session.processMetadata()?.childPid, pid > 0 else { return }
    lock.lock()
    detectorsByTab[tabId]?.stop()
    let detector = AgentSessionDetector(tabId: tabId, shellPid: pid_t(pid))
    detector.observer = self
    detectorsByTab[tabId] = detector
    lock.unlock()
    detector.start()
  }

  public func detach(tabId: String) {
    lock.lock()
    let detector = detectorsByTab.removeValue(forKey: tabId)
    lock.unlock()
    detector?.stop()
    // Final mirror snapshot — captures the conversation as it
    // existed when the tab closed even if the agent process is
    // still running in some other window. Skipped when the toggle
    // is off (the detector never ran, so there's nothing tracked).
    if isEnabled() {
      mirror.untrack(tabId: tabId, finalSnapshot: true)
    }
  }

  /// Snapshot every tracked tab's JSONL. Called from
  /// `applicationWillTerminate` so quit captures the final state of
  /// every active agent conversation.
  public func flushAll() {
    guard isEnabled() else { return }
    mirror.snapshotAll()
  }

  // MARK: - AgentSessionDetectorObserver

  public func agentSessionDetector(
    _ detector: AgentSessionDetector, didObserve agent: AgentInfo?
  ) {
    guard isEnabled() else { return }
    let tabId = detector.tabId
    appModel.updateAgent(agent, forTab: tabId)
    if let agent, agent.wasRunningAtQuit {
      // Agent is alive — start (or refresh) the periodic mirror
      // timer pointed at its JSONL.
      mirror.track(tabId: tabId, jsonlPath: agent.jsonlPath)
    } else if agent != nil {
      // The detector preserves the captured identity but flips
      // `wasRunningAtQuit` to false when the agent disappears
      // (Ctrl-D, crash). Take one final mirror snapshot of the
      // last-known JSONL path and stop the periodic timer — per
      // the plan, periodic mirroring is only while the agent is
      // alive, with a single lifecycle snapshot on exit.
      mirror.untrack(tabId: tabId, finalSnapshot: true)
    }
  }
}
