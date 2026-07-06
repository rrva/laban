import Foundation
import LabanControl
import LabanCore

/// Builds `SessionLaunchContext` values with control-plane discovery env and,
/// for agent-attached sessions only, a single-use attach bootstrap (C10/C14).
final class ControlSessionLaunchCoordinator {
  weak var controlServer: LabanControlServer?
  private(set) var controlSocketPath: String?

  func noteControlServerStarted(_ server: LabanControlServer, socketPath: String) {
    controlServer = server
    controlSocketPath = socketPath
  }

  func noteControlServerStopped() {
    controlServer = nil
    controlSocketPath = nil
  }

  func prepareLaunch(tabID: Tab.ID?, isAgentAttached: Bool) -> SessionLaunchContext {
    let sessionID = UUID().uuidString
    var env: [String: String] = [:]
    if let controlSocketPath {
      env[ControlEnvironmentKeys.controlURL] = controlSocketPath
    }
    var bootstrap: String?
    if isAgentAttached,
      ControlSessionAttachPolicy.injectBootstrapIntoEnvironment,
      let controlServer
    {
      bootstrap = controlServer.mintSessionAttachBootstrap(sessionID: sessionID)
      env[ControlEnvironmentKeys.sessionAttach] = bootstrap
    }
    return SessionLaunchContext(
      sessionID: sessionID,
      tabID: tabID,
      isAgentAttached: isAgentAttached,
      environmentOverrides: env,
      sessionObserveBootstrap: bootstrap)
  }

  func noteSessionShellStarted(sessionID: String, shellPID: pid_t) {
    controlServer?.registerAttachShellPID(sessionID: sessionID, shellPID: shellPID)
  }

  func mergeControlDiscovery(into base: [String: String]) -> [String: String] {
    guard let controlSocketPath else { return base }
    var merged = base
    merged[ControlEnvironmentKeys.controlURL] = controlSocketPath
    return merged
  }
}
