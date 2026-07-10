import Darwin
import Foundation
import LabanCore

// C14 direct attach: single-use session-attach bootstrap redemption bound to
// the registered session shell PID. Split out of LabanControlServer.swift;
// behavior-preserving code movement.
extension LabanControlServer {
  struct SessionAttachBootstrap: Equatable {
    let sessionID: String
    var consumed: Bool
    /// Shell leader PID; redeem allowed for a direct child of the shell (C14).
    var shellPID: pid_t?
  }

  /// Mints a single-use C14 attach bootstrap bound to `sessionID`.
  public func mintSessionAttachBootstrap(sessionID: String) -> String {
    let bootstrap = Self.makeToken()
    attachLock.lock()
    attachBootstraps[bootstrap] = SessionAttachBootstrap(
      sessionID: sessionID, consumed: false, shellPID: nil)
    attachLock.unlock()
    return bootstrap
  }

  /// Registers the session shell PID before attach redemption (C14).
  public func registerAttachShellPID(sessionID: String, shellPID: pid_t) {
    attachLock.lock()
    defer { attachLock.unlock() }
    for (bootstrap, var entry) in attachBootstraps where entry.sessionID == sessionID {
      entry.shellPID = shellPID
      attachBootstraps[bootstrap] = entry
    }

    guard let identity = processTreeInspector.identity(for: shellPID) else { return }
    let shellIdentity = RegisteredAttachShellIdentity(
      sessionID: sessionID,
      shellPID: shellPID,
      shellStartTime: identity.startTime,
      shellUID: identity.uid,
      shellExecutablePath: identity.executablePath)
    shellIdentityLock.lock()
    attachShellIdentitiesBySessionID[sessionID] = shellIdentity
    shellIdentityLock.unlock()
  }

  public func unregisterAttachShellIdentity(sessionID: String) {
    shellIdentityLock.lock()
    attachShellIdentitiesBySessionID.removeValue(forKey: sessionID)
    shellIdentityLock.unlock()
    lazyAttachLock.lock()
    for (key, context) in pendingLazyAttachRequests where context.sessionID == sessionID {
      pendingLazyAttachRequests.removeValue(forKey: key)
    }
    lazyAttachLock.unlock()
  }

  public func hasRegisteredShell(sessionID: String) -> Bool {
    shellIdentityLock.lock()
    defer { shellIdentityLock.unlock() }
    return attachShellIdentitiesBySessionID[sessionID] != nil
  }

  public func canLazyAttachDescendant(sessionID: String, peerPID: pid_t) -> Bool {
    guard let shellSession = resolveUniqueShellSessionAncestor(peerPID: peerPID) else {
      return false
    }
    guard shellSession.sessionID == sessionID else { return false }
    return resolveAttachProcessChain(peerPID: peerPID, shellPID: shellSession.shell.shellPID) != nil
  }

  public enum SessionAttachRedeemResult {
    case success(sessionID: String)
    case pending
    case invalid
  }

  /// Redeems a bootstrap once, binding session-observe auth to the redeeming connection (C14).
  public func redeemSessionAttachBootstrap(
    _ bootstrap: String,
    peerPID: pid_t
  ) -> SessionAttachRedeemResult {
    attachLock.lock()
    guard var entry = attachBootstraps[bootstrap], !entry.consumed else {
      attachLock.unlock()
      return .invalid
    }
    guard let shellPID = entry.shellPID else {
      attachLock.unlock()
      return .pending
    }
    guard
      Self.isAllowedAttachRedeemer(
        peerPID: peerPID,
        shellPID: shellPID,
        expectedAgentExecutablePath: expectedAgentExecutablePath,
        allowDevAgentExecutablePath: allowDevAgentExecutablePath)
    else {
      attachLock.unlock()
      return .invalid
    }
    entry.consumed = true
    attachBootstraps[bootstrap] = entry
    let sessionID = entry.sessionID
    attachLock.unlock()
    return .success(sessionID: sessionID)
  }

  #if DEBUG
    /// Mints a session-observe bearer for tests and fixture runtimes only — not C14 production attach.
    public func mintSessionObserveToken(sessionID: String) -> String {
      let token = Self.makeToken()
      registerToken(token, tier: .sessionObserve(sessionID: sessionID))
      return token
    }
  #endif

  func handleSessionAttach(body: Data, peerPID: pid_t?) -> (
    ControlResponse, ControlTokenTier?
  ) {
    guard let peerPID else {
      return (.error(403, "forbidden"), nil)
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let bootstrap = json["bootstrap"] as? String,
      !bootstrap.isEmpty
    else {
      return (.error(400, "bad request"), nil)
    }
    switch redeemSessionAttachBootstrap(bootstrap, peerPID: peerPID) {
    case .success(let sessionID):
      reportAttachAuthorize(sessionID: sessionID)
      let payload: [String: Any] = [
        "ok": true,
        "sessionID": sessionID,
      ]
      guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      else {
        return (.error(500, "internal error"), nil)
      }
      return (
        ControlResponse(status: 200, contentType: "application/json", body: data),
        .sessionObserve(sessionID: sessionID)
      )
    case .pending:
      return (.error(425, "too early"), nil)
    case .invalid:
      return (.error(401, "invalid or spent bootstrap"), nil)
    }
  }

  #if DEBUG
    /// Test hook to bypass the laban-agent executable verification during
    /// integration tests that redeem from the test process itself.
    public static var skipExecutableVerificationForTests = false
  #endif

  public static func isAllowedAttachRedeemer(
    peerPID: pid_t,
    shellPID: pid_t,
    expectedAgentExecutablePath: String? = ControlProcessInfo.defaultExpectedAgentExecutablePath(),
    allowDevAgentExecutablePath: Bool = false
  ) -> Bool {
    guard let parentPID = parentPID(of: peerPID), parentPID == shellPID else {
      return false
    }
    #if DEBUG
      if skipExecutableVerificationForTests { return true }
    #endif
    guard let executablePath = ControlProcessInfo.executablePath(for: peerPID),
      ControlProcessInfo.isLabanAgentExecutable(
        executablePath,
        expectedExecutablePath: expectedAgentExecutablePath,
        allowDevBuildPath: allowDevAgentExecutablePath)
    else {
      return false
    }
    return true
  }

  static func parentPID(of pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
      size >= MemoryLayout<kinfo_proc>.stride
    else {
      return nil
    }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
  }
}
