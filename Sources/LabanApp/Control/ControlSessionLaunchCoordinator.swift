import Foundation
import LabanControl
import LabanCore

/// Builds `SessionLaunchContext` values with control-plane discovery env.
///
/// Agent-attached sessions receive a single-use `LABAN_SESSION_ATTACH` bootstrap
/// that `laban-agent --control-attach` redeems for a connection-bound
/// session-observe credential. Redemption requires the peer to be the
/// `laban-agent` executable and a direct child of the registered shell PID, so
/// the inheritable env alone is not a credential.
final class ControlSessionLaunchCoordinator {
  weak var controlServer: LabanControlServer?
  private(set) var controlSocketPath: String?
  private var pendingAttachSessionIDs: Set<String> = []
  private var sessionIDsByTabID: [Tab.ID: String] = [:]

  func noteControlServerStarted(_ server: LabanControlServer, socketPath: String) {
    controlServer = server
    controlSocketPath = socketPath
  }

  func noteControlServerStopped() {
    controlServer = nil
    controlSocketPath = nil
    pendingAttachSessionIDs.removeAll()
    sessionIDsByTabID.removeAll()
  }

  func prepareLaunch(
    tabID: Tab.ID?, isAgentAttached: Bool, defaults: UserDefaults = .standard
  ) -> SessionLaunchContext {
    let sessionID = UUID().uuidString
    if let tabID {
      sessionIDsByTabID[tabID] = sessionID
    }
    var env: [String: String] = [:]
    if let controlSocketPath {
      env[ControlEnvironmentKeys.controlURL] = controlSocketPath
    }
    var bootstrap: String?
    let attachEnvOptIn =
      ProcessInfo.processInfo.environment[ControlEnvironmentKeys.attachEnvOptIn] == "1"
      || AgentAttachedSessionSettings.isEnabled(defaults: defaults)
    if isAgentAttached,
      ControlSessionAttachPolicy.injectBootstrapIntoEnvironment,
      attachEnvOptIn,
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

  /// Registers the session shell PID when metadata is available.
  ///
  /// Fresh C14 bootstraps are pending only for agent-attached launches, but lazy
  /// attach also needs this live shell identity after the GUI reconnects to an
  /// existing labpty session during restart.
  func tryRegisterShellPID(sessionID: String, session: Session, shellPID override: pid_t? = nil) {
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

  func noteTabClosed(tabID: Tab.ID) {
    guard let sessionID = sessionIDsByTabID.removeValue(forKey: tabID) else { return }
    pendingAttachSessionIDs.remove(sessionID)
    controlServer?.unregisterAttachShellIdentity(sessionID: sessionID)
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
