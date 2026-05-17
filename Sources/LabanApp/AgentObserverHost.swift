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
  private let mirror: AgentJSONLMirror

  private let lock = NSLock()
  private var detectorsByTab: [String: AgentSessionDetector] = [:]

  public init(appModel: AppModel, mirror: AgentJSONLMirror) {
    self.appModel = appModel
    self.mirror = mirror
  }

  /// Begin watching `session`'s shell descendants for the configured
  /// agent binaries. No-op when the session has no PID (fixture
  /// mode); detectors only make sense against real PTY children.
  public func attach(session: Session, tabId: String) {
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
    // still running in some other window.
    mirror.untrack(tabId: tabId, finalSnapshot: true)
  }

  /// Snapshot every tracked tab's JSONL. Called from
  /// `applicationWillTerminate` so quit captures the final state of
  /// every active agent conversation.
  public func flushAll() {
    mirror.snapshotAll()
  }

  // MARK: - AgentSessionDetectorObserver

  public func agentSessionDetector(
    _ detector: AgentSessionDetector, didObserve agent: AgentInfo?
  ) {
    let tabId = detector.tabId
    appModel.updateAgent(agent, forTab: tabId)
    if let agent {
      mirror.track(tabId: tabId, jsonlPath: agent.jsonlPath)
    } else {
      // Agent died — leave the mirror tracking alone so quit /
      // close still produces a final snapshot; the periodic timer
      // simply won't have anything new to copy.
    }
  }
}
