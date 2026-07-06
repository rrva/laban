import Foundation
import LabanControl
import LabanCore

/// Builds `SessionLaunchContext` values with control-plane discovery env and,
/// for agent-attached sessions only, a single-use attach bootstrap (C10/C14).
final class ControlSessionLaunchCoordinator {
  weak var controlServer: LabanControlServer?
  private(set) var controlSocketPath: String?
  private var pendingAttachSessionIDs: Set<String> = []

  func noteControlServerStarted(_ server: LabanControlServer, socketPath: String) {
    controlServer = server
    controlSocketPath = socketPath
  }

  func noteControlServerStopped() {
    controlServer = nil
    controlSocketPath = nil
    pendingAttachSessionIDs.removeAll()
  }

  func prepareLaunch(tabID: Tab.ID?, isAgentAttached: Bool) -> SessionLaunchContext {
    let sessionID = UUID().uuidString
    var env: [String: String] = [:]
    if let controlSocketPath {
      env[ControlEnvironmentKeys.controlURL] = controlSocketPath
    }
    var bootstrap: String?
    if isAgentAttached, let controlServer {
      bootstrap = controlServer.mintSessionAttachBootstrap(sessionID: sessionID)
      env[ControlEnvironmentKeys.sessionAttach] = bootstrap
      pendingAttachSessionIDs.insert(sessionID)
    }
    return SessionLaunchContext(
      sessionID: sessionID,
      tabID: tabID,
      isAgentAttached: isAgentAttached,
      environmentOverrides: env,
      sessionObserveBootstrap: bootstrap)
  }

  /// Registers the session shell PID when metadata is available (C14).
  func tryRegisterShellPID(sessionID: String, session: Session) {
    guard pendingAttachSessionIDs.contains(sessionID) else { return }
    guard let childPid = session.processMetadata()?.childPid, childPid > 0 else { return }
    noteSessionShellStarted(sessionID: sessionID, shellPID: pid_t(childPid))
  }

  func retryPendingShellRegistrations(in model: AppModel) {
    guard !pendingAttachSessionIDs.isEmpty else { return }
    for (_, session) in model.allSessions() where pendingAttachSessionIDs.contains(session.id) {
      tryRegisterShellPID(sessionID: session.id, session: session)
    }
  }

  func noteSessionShellStarted(sessionID: String, shellPID: pid_t) {
    controlServer?.registerAttachShellPID(sessionID: sessionID, shellPID: shellPID)
    pendingAttachSessionIDs.remove(sessionID)
  }

  func mergeControlDiscovery(into base: [String: String]) -> [String: String] {
    guard let controlSocketPath else { return base }
    var merged = base
    merged[ControlEnvironmentKeys.controlURL] = controlSocketPath
    return merged
  }

  #if DEBUG
  func hasPendingAttachRegistration(sessionID: String) -> Bool {
    pendingAttachSessionIDs.contains(sessionID)
  }
  #endif
}
