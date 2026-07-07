import Foundation
import LabanControl
import LabanCore

/// Builds `SessionLaunchContext` values with control-plane discovery env.
///
/// `LABAN_SESSION_ATTACH` bootstrap delivery is intentionally off by default:
/// an inheritable shell environment cannot be the release security boundary for
/// session-observe. Set `LABAN_CONTROL_ATTACH_ENV=1` only for explicit
/// development / E2E paths that accept that env exposure.
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
    if isAgentAttached, ControlSessionAttachPolicy.injectBootstrapIntoEnvironment,
      let controlServer
    {
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
  func tryRegisterShellPID(sessionID: String, session: Session, shellPID override: pid_t? = nil) {
    guard pendingAttachSessionIDs.contains(sessionID) else { return }
    let resolved: pid_t?
    if let override, override > 0 {
      resolved = override
    } else if let childPid = session.processMetadata()?.childPid, childPid > 0 {
      resolved = pid_t(childPid)
    } else {
      resolved = nil
    }
    guard let resolved else { return }
    noteSessionShellStarted(sessionID: sessionID, shellPID: resolved)
  }

  func retryPendingShellRegistrations(
    in model: AppModel,
    shellPIDProvider: ((Tab.ID, Session) -> pid_t?)? = nil
  ) {
    guard !pendingAttachSessionIDs.isEmpty else { return }
    for (tab, session) in model.allSessions() where pendingAttachSessionIDs.contains(session.id) {
      let override = shellPIDProvider?(tab.id, session)
      tryRegisterShellPID(sessionID: session.id, session: session, shellPID: override)
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
