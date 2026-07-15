import CryptoKit
import Darwin
import Dispatch
import Foundation
import LabanCore

public enum GuardOutcome: Equatable, Sendable {
  case ok
  case unauthorized
  case forbidden
}

public enum LabanControlServerError: Error, Equatable, Sendable {
  case socketFailed
  case bindFailed
  case listenFailed
  case alreadyStarted
  case socketPathTooLong
}

public struct GUIControlStartResult: Sendable, Equatable {
  public let socketPath: String
  public let appObserveToken: String
  public let diagnosticControlToken: String?
  public let diagnosticSessionObserveToken: String?

  public init(
    socketPath: String,
    appObserveToken: String,
    diagnosticControlToken: String? = nil,
    diagnosticSessionObserveToken: String? = nil
  ) {
    self.socketPath = socketPath
    self.appObserveToken = appObserveToken
    self.diagnosticControlToken = diagnosticControlToken
    self.diagnosticSessionObserveToken = diagnosticSessionObserveToken
  }
}

public final class LabanControlServer {
  static let defaultRequestReadTimeout: TimeInterval = 5
  static let attachedConnectionReadTimeout: TimeInterval = 0
  static let maxHeaderBytes = 64 * 1024
  static let maxBodyBytes = 4 * 1024 * 1024

  public static let endpoints: [ControlEndpointDescriptor] = ControlRouteCatalog.endpoints

  public static let routes: [HTTPBinding] = ControlRouteCatalog.bindings

  let router: IntentRouter
  let surface: Surface
  let catalog: IntentCatalog
  private let readinessRunID: String?
  let expectedAgentExecutablePath: String?
  let allowDevAgentExecutablePath: Bool
  let requestReadTimeout: TimeInterval
  weak var securityObserver: (any ControlSecurityObserver)?
  private let connectionQueue = DispatchQueue(
    label: "com.laban.control.conn", attributes: .concurrent)
  private var fd: Int32 = -1

  #if DEBUG
    public var testListenerFD: Int32 { fd }
  #endif

  private var socketPath: String?
  var tokens: [String: ControlTokenTier] = [:]
  let tokenLock = NSLock()
  var attachBootstraps: [String: SessionAttachBootstrap] = [:]
  let attachLock = NSLock()
  private var thread: Thread?

  var attachShellIdentitiesBySessionID: [String: RegisteredAttachShellIdentity] = [:]
  let shellIdentityLock = NSLock()

  var pendingLazyAttachRequests: [String: ControlAttachApprovalContext] = [:]
  var lastLazyDenyByPrincipalFingerprint: [String: Date] = [:]
  let lazyAttachLock = NSLock()
  let lazyDenyCooldown: TimeInterval = 2
  let maxConcurrentPendingLazyAttachRequests = 8

  var processTreeInspector: any ControlProcessTreeInspecting = ControlProcessTreeInspector()
  var codeSigningInspector: any ControlCodeSigningInspecting = ControlCodeSigningInspector()
  public var approvalStore: ControlAttachApprovalStore
  public weak var approvalDelegate: (any ControlAttachApprovalDelegate)?
  let lazyAttachApprovalTimeout: TimeInterval

  #if DEBUG
    /// Test seam: fires with each internal approved-dispatch token as it is
    /// minted, so tests can prove the token never leaks into responses,
    /// errors, or audit payloads. Production code never reads this.
    public var onApprovedTokenMintedForTesting: (@Sendable (String) -> Void)?
  #endif

  public static let sessionAttachPath = "/control/session/attach"
  public static let lazyAttachRequestPath = "/control/session/attach/request"
  public static let maxLazyAttachBodySize = 256 * 1024

  public init(
    router: IntentRouter,
    surface: Surface,
    catalog: IntentCatalog = .all,
    readinessRunID: String? = nil,
    expectedAgentExecutablePath: String? = ControlProcessInfo.defaultExpectedAgentExecutablePath(),
    allowDevAgentExecutablePath: Bool = false,
    securityObserver: (any ControlSecurityObserver)? = nil,
    processTreeInspector: (any ControlProcessTreeInspecting)? = nil,
    codeSigningInspector: (any ControlCodeSigningInspecting)? = nil,
    approvalStore: ControlAttachApprovalStore? = nil,
    lazyAttachApprovalTimeout: TimeInterval = 30,
    requestReadTimeout: TimeInterval = 5
  ) {
    self.router = router
    self.surface = surface
    self.catalog = catalog
    self.readinessRunID = readinessRunID
    self.expectedAgentExecutablePath = expectedAgentExecutablePath
    self.allowDevAgentExecutablePath = allowDevAgentExecutablePath
    self.requestReadTimeout = requestReadTimeout
    self.securityObserver = securityObserver
    self.lazyAttachApprovalTimeout = lazyAttachApprovalTimeout
    if let processTreeInspector {
      self.processTreeInspector = processTreeInspector
    }
    if let codeSigningInspector {
      self.codeSigningInspector = codeSigningInspector
    }
    if let approvalStore {
      self.approvalStore = approvalStore
    } else {
      self.approvalStore = ControlAttachApprovalStore(signer: Self.makeDefaultApprovalSigner())
    }
  }

  private static func makeDefaultApprovalSigner() -> ControlAttachApprovalRecordSigning? {
    ControlAttachApprovalStore.defaultSigner()
  }

  public static func defaultControlSocketPath() -> String {
    ControlAdvertisement.directory()
      .appendingPathComponent("control.sock")
      .path
  }

  public func setSecurityObserver(_ observer: (any ControlSecurityObserver)?) {
    securityObserver = observer
  }

  public func start(enableGUIFixtureControl: Bool = false) throws -> GUIControlStartResult {
    let path = Self.defaultControlSocketPath()
    let controlDir = ControlAdvertisement.directory()
    try ControlDirectorySecurity.rejectSymlinkDirectory(at: controlDir)
    try ControlDirectorySecurity.ensurePrivateDirectory(at: controlDir)
    try bindListener(at: path)
    let appObserveToken = Self.makeToken()
    registerToken(appObserveToken, tier: .appObserve)
    guard enableGUIFixtureControl else {
      return GUIControlStartResult(socketPath: path, appObserveToken: appObserveToken)
    }
    let diagnosticControlToken = Self.makeToken()
    registerToken(diagnosticControlToken, tier: .fixture)
    let diagnosticSessionObserveToken = Self.makeToken()
    registerToken(
      diagnosticSessionObserveToken,
      tier: .sessionObserve(sessionID: "diagnostic-control-denial"))
    return GUIControlStartResult(
      socketPath: path,
      appObserveToken: appObserveToken,
      diagnosticControlToken: diagnosticControlToken,
      diagnosticSessionObserveToken: diagnosticSessionObserveToken)
  }

  public func start(socketPath: String) throws -> ControlReadiness {
    try bindListener(at: socketPath)
    let fixtureToken = Self.makeToken()
    registerToken(fixtureToken, tier: .fixture)
    let process = ProcessInfo.processInfo
    return ControlReadiness(
      debugServer: socketPath,
      debugToken: fixtureToken,
      pid: process.processIdentifier,
      runId: readinessRunID ?? process.environment["LABAN_RUN_ID"]
        ?? "gui-\(process.processIdentifier)")
  }

  public func setApprovalDelegate(_ delegate: (any ControlAttachApprovalDelegate)?) {
    approvalDelegate = delegate
  }

  public func stop() {
    let listener = fd
    fd = -1
    if listener >= 0 { Darwin.close(listener) }
    if let socketPath {
      unlink(socketPath)
      self.socketPath = nil
    }
    tokenLock.lock()
    tokens = [:]
    tokenLock.unlock()
    attachLock.lock()
    attachBootstraps = [:]
    attachLock.unlock()
    shellIdentityLock.lock()
    attachShellIdentitiesBySessionID.removeAll()
    shellIdentityLock.unlock()
    lazyAttachLock.lock()
    pendingLazyAttachRequests.removeAll()
    lastLazyDenyByPrincipalFingerprint.removeAll()
    lazyAttachLock.unlock()
    thread = nil
  }

  deinit {
    stop()
  }

  public static func evaluateGuard(
    host: String?,
    origin: String?,
    authorization: String?,
    token: String
  ) -> GuardOutcome {
    // Retained for backward-compatible unit tests; UDS transport does not use Host/Origin.
    if origin != nil { return .forbidden }
    guard isLoopbackHost(host) else { return .forbidden }
    guard
      let authorization,
      authorization.count > 7,
      authorization.lowercased().hasPrefix("bearer "),
      constantTimeEquals(String(authorization.dropFirst(7)), token)
    else {
      return .unauthorized
    }
    return .ok
  }

  public static func evaluatePeerCredential(clientFD: Int32) -> GuardOutcome {
    var uid = uid_t(0)
    var gid = gid_t(0)
    guard getpeereid(clientFD, &uid, &gid) == 0 else {
      return .forbidden
    }
    guard uid == getuid() else {
      return .forbidden
    }
    return .ok
  }

  // LOCAL_PEERPID (0x002) retrieves the peer's real pid, not LOCAL_PEEREPID
  // (0x003, effective pid). Peer identity checks (C14 direct-child checks,
  // lazy-attach principal derivation, proxy descendant checks) must gate on
  // the real pid: effective pid can differ from real pid under setuid or
  // posix_spawn scenarios, which is the wrong identity to authorize against.
  private static let localPeerPID: Int32 = 2
  private static let localPeerToken: Int32 = 0x006

  public static func peerPID(clientFD: Int32) -> pid_t? {
    var pid: pid_t = 0
    var len = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(clientFD, SOL_LOCAL, localPeerPID, &pid, &len) == 0 else {
      return nil
    }
    return pid
  }

  public static func peerAuditToken(clientFD: Int32) -> Data? {
    var token = AuditToken()
    var len = socklen_t(MemoryLayout<AuditToken>.size)
    guard getsockopt(clientFD, SOL_LOCAL, localPeerToken, &token, &len) == 0 else {
      return nil
    }
    guard len == MemoryLayout<AuditToken>.size else { return nil }
    let data = withUnsafeBytes(of: &token) { Data($0) }
    return data
  }

  public static func isLoopbackHost(_ host: String?) -> Bool {
    guard let host, !host.isEmpty else { return false }
    if host.hasPrefix("[") {
      let rest = host.dropFirst()
      guard let close = rest.firstIndex(of: "]") else { return false }
      guard rest[rest.startIndex..<close] == "::1" else { return false }
      let after = rest[rest.index(after: close)...]
      return after.isEmpty || after.first == ":"
    }
    let label = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
    return label == "127.0.0.1" || label == "localhost"
  }

  public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
    let count = max(x.count, y.count)
    for i in 0..<count {
      diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return diff == 0
  }

  public static func makeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32)
      .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
      .joined()
  }

  func registerToken(_ token: String, tier: ControlTokenTier) {
    tokenLock.lock()
    tokens[token] = tier
    tokenLock.unlock()
  }

  private func bindListener(at path: String) throws {
    guard fd < 0 else { throw LabanControlServerError.alreadyStarted }

    try ControlDirectorySecurity.prepareSocketPath(path)

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw LabanControlServerError.socketFailed }
    try ControlFD.setCloseOnExec(listener)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(listener)
      throw LabanControlServerError.socketPathTooLong
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (index, byte) in pathBytes.enumerated() where index < dest.count {
        dest[index] = UInt8(bitPattern: byte)
      }
    }

    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.bind(listener, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      Darwin.close(listener)
      throw LabanControlServerError.bindFailed
    }

    guard listen(listener, 16) == 0 else {
      Darwin.close(listener)
      throw LabanControlServerError.listenFailed
    }

    fd = listener
    socketPath = path

    let acceptThread = Thread { self.acceptLoop() }
    acceptThread.name = "laban-control-accept"
    acceptThread.start()
    thread = acceptThread
  }

  private func acceptLoop() {
    while true {
      let listener = fd
      guard listener >= 0 else { break }
      var clientAddr = sockaddr_un()
      var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
      let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
        accept(listener, ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }, &clientLen)
      }
      if clientFD >= 0 {
        do {
          try Self.configureAcceptedSocket(clientFD)
        } catch {
          Darwin.close(clientFD)
          continue
        }
        connectionQueue.async { [self] in handleConnection(clientFD) }
        continue
      }

      let err = errno
      if fd < 0 || err == EBADF || err == EINVAL { break }
      if err == EINTR || err == ECONNABORTED { continue }
      if err == EMFILE || err == ENFILE {
        usleep(100_000)
        continue
      }
      break
    }
  }

  /// Applies the socket options required on every accepted control-plane
  /// connection before it is handed to `handleConnection`: close-on-exec so
  /// the fd does not leak into spawned children, and SO_NOSIGPIPE so a
  /// client closing its read side mid-send raises EPIPE instead of SIGPIPE
  /// (which would otherwise crash the process).
  public static func configureAcceptedSocket(_ clientFD: Int32) throws {
    try ControlFD.setCloseOnExec(clientFD)
    try ControlFD.setNoSigPipe(clientFD)
  }

  private func handleConnection(_ clientFD: Int32) {
    defer { Darwin.close(clientFD) }
    guard Self.evaluatePeerCredential(clientFD: clientFD) == .ok else {
      send(clientFD, .error(403, "forbidden"), persistSession: false)
      return
    }
    setReceiveTimeout(clientFD, timeout: requestReadTimeout)
    var connectionTier: ControlTokenTier?

    requestLoop: while true {
      let incoming: IncomingHTTPRequest
      switch readHTTPRequest(clientFD, timeout: requestReadTimeout) {
      case .ok(let request):
        incoming = request
      case .badRequest:
        send(clientFD, .error(400, "bad request"), persistSession: false)
        break requestLoop
      case .methodNotAllowed:
        send(clientFD, .error(405, "method not allowed"), persistSession: false)
        break requestLoop
      case .payloadTooLarge:
        send(clientFD, .error(413, "payload too large"), persistSession: false)
        break requestLoop
      case .connectionClosed:
        break requestLoop
      }

      if incoming.method == "POST", incoming.path == Self.sessionAttachPath {
        let peerPID = Self.peerPID(clientFD: clientFD)
        let (response, boundTier) = handleSessionAttach(
          body: incoming.body,
          peerPID: peerPID)
        if let boundTier {
          connectionTier = boundTier
          setReceiveTimeout(clientFD, timeout: LabanControlServer.attachedConnectionReadTimeout)
        }
        send(clientFD, response, persistSession: connectionTier != nil)
        if connectionTier == nil { break requestLoop }
        continue
      }

      if incoming.method == "POST", incoming.path == Self.lazyAttachRequestPath {
        let peerPID = Self.peerPID(clientFD: clientFD)
        let response = handleLazyAttachRequest(
          clientFD: clientFD,
          body: incoming.body,
          peerPID: peerPID,
          appObserveToken: incoming.headers.authorization)
        send(clientFD, response, persistSession: false)
        break requestLoop
      }

      let (authOutcome, tokenTier) = resolveAuthorization(
        authorization: incoming.headers.authorization,
        connectionTier: connectionTier)
      switch authOutcome {
      case .forbidden:
        reportDeny(
          reason: .peerCredential,
          targetSession: sessionID(from: tokenTier),
          tokenTier: tokenTier)
        send(clientFD, .error(403, "forbidden"), persistSession: connectionTier != nil)
        break requestLoop
      case .unauthorized:
        reportDeny(reason: .unauthorized, targetSession: sessionID(from: tokenTier))
        send(clientFD, Self.unauthorizedResponse(), persistSession: connectionTier != nil)
        break requestLoop
      case .ok:
        break
      }

      guard let tokenTier else {
        send(clientFD, Self.unauthorizedResponse(), persistSession: connectionTier != nil)
        break requestLoop
      }

      let response = route(
        method: incoming.method,
        path: incoming.path,
        query: incoming.query,
        body: incoming.body,
        tokenTier: tokenTier)
      let persist = connectionTier != nil || incoming.wantsKeepAlive
      send(clientFD, response, persistSession: persist)
      if !persist { break }
    }
  }

  func reportDeny(
    intentID: String? = nil,
    capability: Capability? = nil,
    reason: ControlSecurityDenyReason,
    targetSession: String? = nil,
    tokenTier: ControlTokenTier? = nil
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: capability,
      surface: surface,
      sessionID: targetSession ?? sessionID(from: tokenTier))
    securityObserver?.didDeny(context, reason: reason)
  }

  func reportAuthorize(
    intentID: String,
    capability: Capability,
    targetSession: String?,
    tokenTier: ControlTokenTier
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: capability,
      surface: surface,
      sessionID: targetSession ?? sessionID(from: tokenTier))
    if LabanControlPolicy.isPrivileged(capability) {
      securityObserver?.didPrivilegedActivity(context)
    } else {
      securityObserver?.didAuthorize(context)
    }
  }

  func reportAttachAuthorize(sessionID: String) {
    let context = ControlSecurityContext(
      intentID: "control.session.attach",
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachAuthorize(context)
  }
}
