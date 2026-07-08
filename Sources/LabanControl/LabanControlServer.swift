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

  public init(socketPath: String, appObserveToken: String) {
    self.socketPath = socketPath
    self.appObserveToken = appObserveToken
  }
}

public final class LabanControlServer {
  private struct ParsedHeaders {
    var authorization: String?
    var authorizationCount = 0
    var contentLengthHeader: String?
    var connection: String?
  }

  private enum ContentLengthResult {
    case success(Int)
    case failure(status: Int)
  }

  private enum ParseResult {
    case ok(IncomingHTTPRequest)
    case badRequest
    case methodNotAllowed
    case payloadTooLarge
    case connectionClosed
  }

  private static let requestReadTimeout: TimeInterval = 5
  private static let attachedConnectionReadTimeout: TimeInterval = 0
  private static let maxHeaderBytes = 64 * 1024
  private static let maxBodyBytes = 4 * 1024 * 1024

  public static let endpoints: [ControlEndpointDescriptor] = ControlRouteCatalog.endpoints

  public static let routes: [HTTPBinding] = ControlRouteCatalog.bindings

  let router: IntentRouter
  private let surface: Surface
  private let catalog: IntentCatalog
  private let readinessRunID: String?
  private let expectedAgentExecutablePath: String?
  private let allowDevAgentExecutablePath: Bool
  private weak var securityObserver: (any ControlSecurityObserver)?
  private let connectionQueue = DispatchQueue(
    label: "com.laban.control.conn", attributes: .concurrent)
  private var fd: Int32 = -1

  #if DEBUG
    public var testListenerFD: Int32 { fd }
  #endif

  private var socketPath: String?
  private var tokens: [String: ControlTokenTier] = [:]
  private let tokenLock = NSLock()
  private var attachBootstraps: [String: SessionAttachBootstrap] = [:]
  private let attachLock = NSLock()
  private var thread: Thread?

  private var attachShellIdentitiesBySessionID: [String: RegisteredAttachShellIdentity] = [:]
  private let shellIdentityLock = NSLock()

  private var pendingLazyAttachRequests: [String: ControlAttachApprovalContext] = [:]
  private let lazyAttachLock = NSLock()

  private var processTreeInspector: any ControlProcessTreeInspecting = ControlProcessTreeInspector()
  private var codeSigningInspector: any ControlCodeSigningInspecting = ControlCodeSigningInspector()
  private var approvalStore: ControlAttachApprovalStore = ControlAttachApprovalStore()
  public weak var approvalDelegate: (any ControlAttachApprovalDelegate)?

  private struct SessionAttachBootstrap: Equatable {
    let sessionID: String
    var consumed: Bool
    /// Shell leader PID; redeem allowed for a direct child of the shell (C14).
    var shellPID: pid_t?
  }

  public static let sessionAttachPath = "/control/session/attach"
  public static let lazyAttachRequestPath = "/control/session/attach/request"

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
    approvalStore: ControlAttachApprovalStore? = nil
  ) {
    self.router = router
    self.surface = surface
    self.catalog = catalog
    self.readinessRunID = readinessRunID
    self.expectedAgentExecutablePath = expectedAgentExecutablePath
    self.allowDevAgentExecutablePath = allowDevAgentExecutablePath
    self.securityObserver = securityObserver
    if let processTreeInspector {
      self.processTreeInspector = processTreeInspector
    }
    if let codeSigningInspector {
      self.codeSigningInspector = codeSigningInspector
    }
    if let approvalStore {
      self.approvalStore = approvalStore
    }
  }

  public static func defaultControlSocketPath() -> String {
    ControlAdvertisement.directory()
      .appendingPathComponent("control.sock")
      .path
  }

  public func setSecurityObserver(_ observer: (any ControlSecurityObserver)?) {
    securityObserver = observer
  }

  public func start() throws -> GUIControlStartResult {
    let path = Self.defaultControlSocketPath()
    let controlDir = ControlAdvertisement.directory()
    try ControlDirectorySecurity.rejectSymlinkDirectory(at: controlDir)
    try ControlDirectorySecurity.ensurePrivateDirectory(at: controlDir)
    try bindListener(at: path)
    let appObserveToken = Self.makeToken()
    registerToken(appObserveToken, tier: .appObserve)
    return GUIControlStartResult(socketPath: path, appObserveToken: appObserveToken)
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

    let identity = processTreeInspector.identity(for: shellPID)
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

  public func setApprovalDelegate(_ delegate: (any ControlAttachApprovalDelegate)?) {
    approvalDelegate = delegate
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
    return resolveAttachProcessChain(peerPID: peerPID, shellPID: shellSession.shellPID) != nil
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

  private static let localPeerPID: Int32 = 3

  public static func peerPID(clientFD: Int32) -> pid_t? {
    var pid: pid_t = 0
    var len = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(clientFD, SOL_LOCAL, localPeerPID, &pid, &len) == 0 else {
      return nil
    }
    return pid
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

  private static func parentPID(of pid: pid_t) -> pid_t? {
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

  private func evaluateAuthorization(
    peerOutcome: GuardOutcome,
    authorization: String?
  ) -> (GuardOutcome, ControlTokenTier?) {
    guard peerOutcome == .ok else {
      return (.forbidden, nil)
    }
    guard
      let authorization,
      authorization.count > 7,
      authorization.lowercased().hasPrefix("bearer ")
    else {
      return (.unauthorized, nil)
    }
    let presented = String(authorization.dropFirst(7))
    tokenLock.lock()
    defer { tokenLock.unlock() }
    for (token, tier) in tokens {
      if Self.constantTimeEquals(presented, token) {
        return (.ok, tier)
      }
    }
    return (.unauthorized, nil)
  }

  /// Retained for backward-compatible unit tests.
  public static func evaluateAuthorization(
    peerOutcome: GuardOutcome,
    authorization: String?,
    tokens: [String: ControlTokenTier]
  ) -> (GuardOutcome, ControlTokenTier?) {
    guard peerOutcome == .ok else {
      return (.forbidden, nil)
    }
    guard
      let authorization,
      authorization.count > 7,
      authorization.lowercased().hasPrefix("bearer ")
    else {
      return (.unauthorized, nil)
    }
    let presented = String(authorization.dropFirst(7))
    for (token, tier) in tokens {
      if constantTimeEquals(presented, token) {
        return (.ok, tier)
      }
    }
    return (.unauthorized, nil)
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

  private func registerToken(_ token: String, tier: ControlTokenTier) {
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
          try ControlFD.setCloseOnExec(clientFD)
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

  private struct IncomingHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: ParsedHeaders
    let body: Data

    var wantsKeepAlive: Bool {
      headers.connection?.lowercased().contains("keep-alive") == true
    }
  }

  private func handleConnection(_ clientFD: Int32) {
    defer { Darwin.close(clientFD) }
    guard Self.evaluatePeerCredential(clientFD: clientFD) == .ok else {
      send(clientFD, .error(403, "forbidden"), persistSession: false)
      return
    }
    setReceiveTimeout(clientFD)
    var connectionTier: ControlTokenTier?

    requestLoop: while true {
      let incoming: IncomingHTTPRequest
      switch readHTTPRequest(clientFD) {
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

  private func resolveAuthorization(
    authorization: String?,
    connectionTier: ControlTokenTier?
  ) -> (GuardOutcome, ControlTokenTier?) {
    if let connectionTier {
      return (.ok, connectionTier)
    }
    return evaluateAuthorization(peerOutcome: .ok, authorization: authorization)
  }

  private func readHTTPRequest(
    _ clientFD: Int32,
    timeout: TimeInterval = LabanControlServer.requestReadTimeout
  ) -> ParseResult {
    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var headerEnd = -1
    let headerDeadline = Date().addingTimeInterval(timeout)
    while raw.count < Self.maxHeaderBytes {
      if Date() > headerDeadline { return .badRequest }
      let n = recv(clientFD, &buffer, buffer.count, 0)
      if n < 0 && errno == EINTR { continue }
      if n == 0 { return .connectionClosed }
      if n < 0 { return .badRequest }
      raw.append(contentsOf: buffer[0..<n])
      if let range = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
        headerEnd = range.upperBound
        break
      }
    }

    guard headerEnd >= 0 else { return .badRequest }
    guard let headerString = String(data: raw[0..<headerEnd], encoding: .utf8) else {
      return .badRequest
    }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .badRequest }
    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else { return .badRequest }

    let method = parts[0]
    let parsedTarget = Self.parseRequestTarget(parts[1])
    let headers = parseHeaders(Array(lines.dropFirst()))

    guard method == "GET" || method == "POST" else { return .methodNotAllowed }
    guard headers.authorizationCount <= 1 else { return .badRequest }

    let contentLength: Int
    switch parseContentLength(headers.contentLengthHeader, method: method) {
    case .success(let length):
      contentLength = length
    case .failure(let status):
      switch status {
      case 413: return .payloadTooLarge
      default: return .badRequest
      }
    }

    var body = Data(raw[headerEnd...].prefix(contentLength))
    let bodyDeadline = Date().addingTimeInterval(timeout)
    while body.count < contentLength {
      if Date() > bodyDeadline { return .badRequest }
      let need = min(contentLength - body.count, 4096)
      var bodyBuffer = [UInt8](repeating: 0, count: need)
      let n = recv(clientFD, &bodyBuffer, need, 0)
      if n < 0 && errno == EINTR { continue }
      if n == 0 { return .connectionClosed }
      if n < 0 { return .badRequest }
      body.append(contentsOf: bodyBuffer[0..<n])
    }

    return .ok(
      IncomingHTTPRequest(
        method: method,
        path: parsedTarget.path,
        query: parsedTarget.query,
        headers: headers,
        body: body))
  }

  private func handleSessionAttach(body: Data, peerPID: pid_t?) -> (
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

  private func route(
    method: String,
    path: String,
    query: [String: String],
    body: Data,
    tokenTier: ControlTokenTier
  ) -> ControlResponse {
    var matchedRoute: ControlRoute?
    var pathParameters: [String: String] = [:]
    for candidate in ControlRouteCatalog.routes {
      guard let parameters = candidate.match(method: method, path: path) else {
        continue
      }
      matchedRoute = candidate
      pathParameters = parameters
      break
    }

    guard let route = matchedRoute else {
      return .error(404, "not found")
    }
    let request = ControlHTTPRequest(
      method: method,
      path: path,
      query: query,
      pathParameters: pathParameters,
      body: body)

    let intentID: String
    switch route.resolveIntentID(request, tokenTier) {
    case .resolved(let id):
      intentID = id
    case .failed(let response):
      return response
    }

    guard let descriptor = catalog.descriptor(id: intentID) else {
      return Self.missingDescriptorResponse(for: route)
    }
    guard descriptor.availability.permits(surface) else {
      reportDeny(
        intentID: intentID,
        capability: descriptor.requiredCapability,
        reason: .surfaceUnavailable,
        targetSession: resolveTargetSession(request: request, body: body),
        tokenTier: tokenTier)
      return .error(404, "unavailable on \(surface)")
    }

    let targetSession = resolveTargetSession(request: request, body: body)
    let granted = LabanControlPolicy.grants(for: tokenTier)
    let scope = LabanControlPolicy.tokenScope(for: tokenTier)
    let requiredCapability = descriptor.requiredCapability
    guard granted.contains(requiredCapability) else {
      reportDeny(
        intentID: intentID,
        capability: requiredCapability,
        reason: .forbiddenCapability,
        targetSession: targetSession,
        tokenTier: tokenTier)
      return .error(403, "forbidden")
    }
    let bodyHashForConstraint = (body.isEmpty ? nil : computeSHA256(body))
    guard
      LabanControlPolicy.authorize(
        intentID: intentID,
        catalog: catalog,
        granted: granted,
        targetSession: targetSession,
        tokenScope: scope,
        tokenTier: tokenTier,
        method: method,
        path: path,
        query: queryForConstraint(query),
        bodySHA256: bodyHashForConstraint)
    else {
      reportDeny(
        intentID: intentID,
        capability: requiredCapability,
        reason: .forbiddenScope,
        targetSession: targetSession,
        tokenTier: tokenTier)
      return .error(403, "forbidden")
    }

    let response = route.dispatch(self, request, tokenTier)
    if (200..<300).contains(response.status) {
      reportAuthorize(
        intentID: intentID,
        capability: requiredCapability,
        targetSession: targetSession,
        tokenTier: tokenTier)
    }
    return response
  }

  private func sessionID(from tokenTier: ControlTokenTier?) -> String? {
    guard let tokenTier else { return nil }
    switch tokenTier {
    case .sessionObserve(let sessionID), .approvedSession(let sessionID, _, _, _):
      return sessionID
    case .appObserve, .fixture:
      return nil
    }
  }

  private func reportDeny(
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

  private func reportAuthorize(
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

  private func reportAttachAuthorize(sessionID: String) {
    let context = ControlSecurityContext(
      intentID: "control.session.attach",
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachAuthorize(context)
  }

  func legacyQueryInput(
    intentID: String,
    params: [String: String],
    tokenTier: ControlTokenTier
  ) -> LegacyDebugQueryInput {
    let scopedSessionID: String?
    switch tokenTier {
    case .sessionObserve(let sessionID), .approvedSession(let sessionID, _, _, _):
      scopedSessionID = sessionID
    case .appObserve, .fixture:
      scopedSessionID = nil
    }
    let readRedaction: ControlReadRedaction =
      switch tokenTier {
      case .appObserve: .appObserveSummary
      case .sessionObserve, .approvedSession: .sessionObserveSummary
      case .fixture: .none
      }
    return LegacyDebugQueryInput(
      intentID: intentID,
      params: params,
      scopedSessionID: scopedSessionID,
      readRedaction: readRedaction)
  }

  private func queryForConstraint(_ query: [String: String]) -> String {
    var pairs: [String] = []
    for (key, value) in query.sorted(by: { $0.key < $1.key }) {
      pairs.append("\(key)=\(value)")
    }
    return pairs.joined(separator: "&")
  }

  private func resolveTargetSession(request: ControlHTTPRequest, body: Data) -> String? {
    if let id = request.pathParameters["id"], !id.isEmpty {
      return id
    }
    for key in ["sessionID", "sessionId", "targetSessionID", "targetSessionId"] {
      if let value = request.query[key], !value.isEmpty {
        return value
      }
    }
    if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
      for key in ["sessionID", "sessionId", "targetSessionID", "targetSessionId"] {
        if let value = json[key] as? String, !value.isEmpty {
          return value
        }
      }
    }
    return nil
  }

  func dispatchDebugAction(_ request: ControlHTTPRequest, tokenTier: ControlTokenTier)
    -> ControlResponse
  {
    guard let envelope = try? JSONDecoder().decode(DebugActionEnvelope.self, from: request.body)
    else {
      return .error(400, "bad request")
    }

    guard let intentID = DebugActionIntentID.intentID(forAction: envelope.action) else {
      if surface == .gui {
        return .error(404, "unavailable on gui")
      }
      return router.route(
        .unsupportedDebugAction(UnsupportedDebugActionInput(action: envelope.action)))
    }

    let scopedSessionID = sessionID(from: tokenTier)
    switch surface {
    case .gui:
      return dispatchGUIAction(
        intentID: intentID, request: request, scopedSessionID: scopedSessionID)
    case .headless:
      return router.route(
        .legacyDebugAction(
          LegacyDebugActionInput(
            intentID: intentID,
            action: envelope.action,
            body: request.body,
            scopedSessionID: scopedSessionID)))
    }
  }

  private func dispatchGUIAction(
    intentID: String,
    request: ControlHTTPRequest,
    scopedSessionID: String?
  ) -> ControlResponse {
    switch intentID {
    case "terminal.scrollViewport", "command.propose":
      guard let envelope = try? JSONDecoder().decode(DebugActionEnvelope.self, from: request.body)
      else {
        return .error(400, "bad request")
      }
      return router.route(
        .legacyDebugAction(
          LegacyDebugActionInput(
            intentID: intentID,
            action: envelope.action,
            body: request.body,
            scopedSessionID: scopedSessionID)))
    default:
      return .error(404, "unavailable on gui")
    }
  }

  private static func missingDescriptorResponse(for route: ControlRoute) -> ControlResponse {
    if route.endpoint.binding.method == "POST" && route.endpoint.binding.path == "/debug/actions" {
      return .error(400, "unsupported action")
    }
    return .error(404, "not found")
  }

  private static func parseRequestTarget(
    _ rawPath: String
  ) -> (path: String, query: [String: String]) {
    let parts = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let path = parts.first.map(String.init) ?? rawPath
    guard parts.count > 1 else {
      return (path, [:])
    }
    return (path, parseQueryString(String(parts[1])))
  }

  private static func parseQueryString(_ queryString: String) -> [String: String] {
    var query: [String: String] = [:]
    guard !queryString.isEmpty else { return query }

    for pair in queryString.split(separator: "&", omittingEmptySubsequences: false) {
      let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard keyValue.count == 2 else { continue }
      let rawKey = String(keyValue[0])
      let rawValue = String(keyValue[1])
      let key = rawKey.removingPercentEncoding ?? rawKey
      let value = rawValue.removingPercentEncoding ?? rawValue
      query[key] = value
    }
    return query
  }

  private static func unauthorizedResponse() -> ControlResponse {
    var response = ControlResponse.error(401, "missing or invalid bearer token")
    response.headers["WWW-Authenticate"] = "Bearer"
    return response
  }

  private func parseHeaders(_ lines: [String]) -> ParsedHeaders {
    var parsed = ParsedHeaders()
    for line in lines {
      if line.isEmpty { break }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      switch name {
      case "authorization":
        parsed.authorizationCount += 1
        if parsed.authorization == nil { parsed.authorization = value }
      case "content-length":
        parsed.contentLengthHeader = value
      case "connection":
        if parsed.connection == nil { parsed.connection = value }
      default:
        continue
      }
    }
    return parsed
  }

  private func parseContentLength(
    _ header: String?,
    method: String
  ) -> ContentLengthResult {
    guard let header, !header.isEmpty else {
      return method == "POST" ? .failure(status: 400) : .success(0)
    }
    guard let length = Int(header), length >= 0 else {
      return .failure(status: 400)
    }
    guard length <= Self.maxBodyBytes else {
      return .failure(status: 413)
    }
    return .success(length)
  }

  private func send(_ clientFD: Int32, _ response: ControlResponse, persistSession: Bool) {
    var header = "HTTP/1.1 \(response.status) \(Self.statusText(response.status))\r\n"
    header += "Content-Type: \(response.contentType)\r\n"
    header += "Content-Length: \(response.body.count)\r\n"
    header += persistSession ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
    for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
      header += "\(name): \(value)\r\n"
    }
    header += "\r\n"
    var data = Data(header.utf8)
    data.append(response.body)
    data.withUnsafeBytes { ptr in
      guard let base = ptr.baseAddress else { return }
      var offset = 0
      while offset < ptr.count {
        let n = Darwin.send(clientFD, base.advanced(by: offset), ptr.count - offset, 0)
        if n < 0 {
          if errno == EINTR { continue }
          return
        }
        if n == 0 { return }
        offset += n
      }
    }
  }

  private func setReceiveTimeout(
    _ clientFD: Int32,
    timeout: TimeInterval = LabanControlServer.requestReadTimeout
  ) {
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(
      clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv,
      socklen_t(MemoryLayout<timeval>.size))
  }

  private static func statusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 409: return "Conflict"
    case 413: return "Payload Too Large"
    case 425: return "Too Early"
    case 429: return "Too Many Requests"
    case 500: return "Internal Server Error"
    case 501: return "Not Implemented"
    default: return "Unknown"
    }
  }

  // MARK: - Lazy Attach

  private func handleLazyAttachRequest(
    clientFD: Int32,
    body: Data,
    peerPID: pid_t?,
    appObserveToken: String?
  ) -> ControlResponse {
    guard let peerPID = peerPID, peerPID > 0 else {
      reportLazyAttachDeny(sessionID: nil, reason: "processIdentityUnavailable")
      return .error(403, "processIdentityUnavailable")
    }

    let token = appObserveToken.flatMap { header -> String? in
      let value = header.trimmingCharacters(in: .whitespaces)
      guard value.lowercased().hasPrefix("bearer ") else { return nil }
      return String(value.dropFirst(7))
    }
    guard let token, validateAppObserveToken(token) else {
      return .error(401, "unauthorized")
    }

    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let clientRequestID = json["clientRequestID"] as? String,
      !clientRequestID.isEmpty,
      let cliCommand = json["cliCommand"] as? String,
      !cliCommand.isEmpty,
      let intendedRequest = json["intendedRequest"] as? [String: Any],
      let method = intendedRequest["method"] as? String,
      !method.isEmpty,
      let path = intendedRequest["path"] as? String,
      !path.isEmpty
    else {
      return .error(400, "bad request")
    }

    let queryString = intendedRequest["query"] as? String ?? ""
    let bodyData: Data?
    if let bodyString = intendedRequest["body"] as? String {
      bodyData = Data(bodyString.utf8)
    } else {
      bodyData = nil
    }
    let bodySHA256 = intendedRequest["bodySHA256"] as? String
    let computedHash = bodyData.map { computeSHA256($0) }
    if bodyData != nil, bodySHA256 == nil || bodySHA256 != computedHash {
      return .error(400, "bodySHA256 mismatch")
    }
    if bodyData == nil, bodySHA256 != nil {
      return .error(400, "bodySHA256 mismatch")
    }

    let peerIdentity = processTreeInspector.identity(for: peerPID)
    guard let peerStartTime = peerIdentity.startTime else {
      reportLazyAttachDeny(sessionID: nil, reason: "processIdentityUnavailable")
      return .error(403, "processIdentityUnavailable")
    }

    guard let shellSession = resolveUniqueShellSessionAncestor(peerPID: peerPID) else {
      reportLazyAttachDeny(sessionID: nil, reason: "notDescendantOfRegisteredSession")
      return .error(403, "notDescendantOfRegisteredSession")
    }

    let (sessionID, shellIdentity) = shellSession

    guard
      let chain = resolveAttachProcessChain(
        peerPID: peerPID,
        shellPID: shellIdentity.shellPID)
    else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "notDescendantOfRegisteredSession")
      return .error(403, "notDescendantOfRegisteredSession")
    }

    guard let principal = chain.principal else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "principalIdentityUnavailable")
      return .error(403, "principalIdentityUnavailable")
    }
    guard let principalStartTime = principal.identity.startTime else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "processIdentityUnavailable")
      return .error(403, "processIdentityUnavailable")
    }

    var identityWithSigning = principal.identity
    if let signing = codeSigningInspector.signingIdentity(
      forLivePID: principal.identity.pid,
      startTime: principalStartTime)
    {
      identityWithSigning.signing = signing
    }
    let principalWithSigning = ControlAttachPrincipal(
      identity: identityWithSigning,
      isGenericInterpreter: principal.isGenericInterpreter,
      isPersistable: principal.isPersistable
        && ControlAttachPrincipal.isPersistable(identityWithSigning),
      helperChain: principal.helperChain)

    let allowlistEntry =
      ControlLazyAttachAllowlist.entry(cliCommand: cliCommand)
      ?? ControlLazyAttachAllowlist.entry(method: method, path: path, intentID: "")
    let (
      resolvedRouteID, resolvedIntentID, resolvedCapability, resolvedSensitivity, resolvedSideEffect
    ) = resolveRouteAndIntent(
      method: method,
      path: path,
      query: parseQueryString(queryString),
      body: bodyData ?? Data())

    guard let resolvedRouteID = resolvedRouteID,
      let resolvedIntentID = resolvedIntentID,
      let resolvedCapability = resolvedCapability,
      let resolvedSensitivity = resolvedSensitivity,
      ControlLazyAttachAllowlist.isAllowlisted(
        method: method, path: path, intentID: resolvedIntentID)
    else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "lazyRouteNotAllowed")
      return .error(403, "lazyRouteNotAllowed")
    }

    let rawSessionRequest =
      method == "POST" && path == "/debug/actions"
      && cliCommand == "session.request"
    let allowlistMatch = ControlLazyAttachAllowlist.entry(
      method: method, path: path, intentID: resolvedIntentID)
    let isPersistableOperation = allowlistMatch?.persistable == true
    let canPersist =
      principalWithSigning.isPersistable && isPersistableOperation && !rawSessionRequest

    guard let descriptor = catalog.descriptor(id: resolvedIntentID) else {
      return .error(404, "not found")
    }
    guard descriptor.availability.permits(surface) else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "surfaceUnavailable")
      return .error(404, "unavailable on \(surface)")
    }

    let routeIDForRecord = "\(method) \(path)"
    let sideEffectClass = sideEffectClassFor(descriptor.sideEffects)
    let capabilities = [descriptor.requiredCapability]

    let approvalID = "\(sessionID.prefix(8))-\(clientRequestID.prefix(8))"
    let context = ControlAttachApprovalContext(
      approvalID: approvalID,
      sessionID: sessionID,
      peerPID: peerPID,
      peerStartTime: peerStartTime,
      principalFingerprint: principalWithSigning.identity.fingerprint,
      method: method,
      path: path,
      query: queryString,
      bodySHA256: computedHash,
      resolvedRouteID: routeIDForRecord,
      resolvedIntentID: resolvedIntentID,
      capabilities: capabilities,
      maxDataSensitivity: resolvedSensitivity,
      allowedSideEffectClasses: [sideEffectClass])

    let matchingRecord = approvalStore.findMatching(
      principal: principalWithSigning,
      sessionID: sessionID,
      shellIdentityFingerprint: shellIdentity.fingerprint,
      routeID: routeIDForRecord,
      intentID: resolvedIntentID,
      capabilities: Set(capabilities),
      dataSensitivity: resolvedSensitivity,
      sideEffectClass: sideEffectClass,
      signingInspector: codeSigningInspector)

    if let matchingRecord = matchingRecord {
      let approvedToken = makeToken()
      let approvedTier = ControlTokenTier.approvedSession(
        sessionID: sessionID,
        approvalID: matchingRecord.id,
        capabilities: capabilities,
        constraint: ControlTokenConstraint(
          method: method,
          path: path,
          query: queryString,
          bodySHA256: computedHash,
          resolvedRouteID: routeIDForRecord,
          resolvedIntentID: resolvedIntentID))
      tokenLock.lock()
      tokens[approvedToken] = approvedTier
      tokenLock.unlock()
      reportLazyAttachAutoApproved(
        sessionID: sessionID, approvalID: matchingRecord.id, intentID: resolvedIntentID)
      let downstream = route(
        method: method,
        path: path,
        query: parseQueryString(queryString),
        body: bodyData ?? Data(),
        tokenTier: approvedTier)
      tokenLock.lock()
      tokens.removeValue(forKey: approvedToken)
      tokenLock.unlock()
      approvalStore.updateLastUsed(id: matchingRecord.id)
      return lazyAttachResponse(
        sessionID: sessionID,
        approval: "always",
        downstream: downstream)
    }

    lazyAttachLock.lock()
    let existingKey = pendingLazyAttachRequests.first {
      $0.value.peerPID == peerPID && $0.value.resolvedIntentID == resolvedIntentID
    }?.key
    if existingKey != nil {
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "approvalRateLimited")
      return .error(429, "approvalRateLimited")
    }
    pendingLazyAttachRequests[clientRequestID] = context
    lazyAttachLock.unlock()

    reportLazyAttachRequest(sessionID: sessionID, intentID: resolvedIntentID)

    let delegate = approvalDelegate
    let request = ControlAttachApprovalRequest(
      id: approvalID,
      principalDisplayName: principalWithSigning.identity.displayName,
      helperChainSummary: chain.helperChainSummary,
      principalPath: principalWithSigning.identity.executablePath,
      sessionDisplay: "\(sessionID.suffix(4))",
      operationSummary: descriptor.summary,
      dataSensitivity: resolvedSensitivity,
      capabilities: capabilities.map(\.rawValue),
      canPersist: canPersist,
      persistenceDisabledReason: canPersist ? nil : "This app is not a stable signed application.")

    let semaphore = DispatchSemaphore(value: 0)
    var decision: ControlAttachApprovalDecision = .deny
    var delegateCompleted = false

    delegate?.requestControlAttachApproval(request) { [weak self] approvedDecision in
      guard let self else { return }
      self.lazyAttachLock.lock()
      self.pendingLazyAttachRequests.removeValue(forKey: clientRequestID)
      self.lazyAttachLock.unlock()
      decision = approvedDecision
      delegateCompleted = true
      semaphore.signal()
    }

    let timeoutResult = semaphore.wait(timeout: .now() + 30)
    if timeoutResult == .timedOut {
      lazyAttachLock.lock()
      pendingLazyAttachRequests.removeValue(forKey: clientRequestID)
      lazyAttachLock.unlock()
      reportLazyAttachDeny(sessionID: sessionID, reason: "approvalTimeout")
      return .error(408, "approvalTimeout")
    }

    switch decision {
    case .deny:
      reportLazyAttachDeny(sessionID: sessionID, reason: "userDenied")
      return .error(403, "userDenied")
    case .allowOnce, .alwaysAllowSignedIdentity:
      break
    }

    guard revalidateLazyAttachContext(context, clientFD: clientFD) else {
      reportLazyAttachDeny(sessionID: sessionID, reason: "sessionChanged")
      return .error(409, "sessionChanged")
    }

    let effectiveDecision: ControlAttachApprovalDecision
    if decision == .alwaysAllowSignedIdentity, !canPersist {
      effectiveDecision = .allowOnce
    } else {
      effectiveDecision = decision
    }

    if effectiveDecision == .alwaysAllowSignedIdentity {
      let record = ControlAttachApprovalRecord(
        id: approvalID,
        displayName: principalWithSigning.identity.displayName,
        bundleIdentifier: principalWithSigning.identity.signing?.bundleIdentifier,
        signing: principalWithSigning.identity.signing ?? ControlCodeSigningIdentity(),
        sessionID: sessionID,
        shellIdentityFingerprint: shellIdentity.fingerprint,
        allowedRouteIDs: [routeIDForRecord],
        allowedIntentIDs: [resolvedIntentID],
        capabilities: capabilities,
        maxDataSensitivity: resolvedSensitivity,
        allowedSideEffectClasses: [sideEffectClass])
      approvalStore.add(record)
    }

    let approvedToken = makeToken()
    let approvedTier = ControlTokenTier.approvedSession(
      sessionID: sessionID,
      approvalID: approvalID,
      capabilities: capabilities,
      constraint: ControlTokenConstraint(
        method: method,
        path: path,
        query: queryString,
        bodySHA256: computedHash,
        resolvedRouteID: routeIDForRecord,
        resolvedIntentID: resolvedIntentID))
    tokenLock.lock()
    tokens[approvedToken] = approvedTier
    tokenLock.unlock()
    reportLazyAttachApproved(
      sessionID: sessionID, approvalID: approvalID, intentID: resolvedIntentID,
      mode: effectiveDecision == .alwaysAllowSignedIdentity ? "always" : "once")
    let downstream = route(
      method: method,
      path: path,
      query: parseQueryString(queryString),
      body: bodyData ?? Data(),
      tokenTier: approvedTier)
    tokenLock.lock()
    tokens.removeValue(forKey: approvedToken)
    tokenLock.unlock()
    return lazyAttachResponse(
      sessionID: sessionID,
      approval: effectiveDecision == .alwaysAllowSignedIdentity ? "always" : "once",
      downstream: downstream)
  }

  private func validateAppObserveToken(_ token: String) -> Bool {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    guard let tier = tokens[token] else { return false }
    return tier == .appObserve
  }

  private func resolveUniqueShellSessionAncestor(
    peerPID: pid_t
  ) -> (sessionID: String, shell: RegisteredAttachShellIdentity)? {
    shellIdentityLock.lock()
    let identities = attachShellIdentitiesBySessionID
    shellIdentityLock.unlock()

    var matched: (sessionID: String, shell: RegisteredAttachShellIdentity)?
    var currentPID: pid_t? = peerPID

    while let pid = currentPID, pid > 1 {
      let identity = processTreeInspector.identity(for: pid)
      for (sessionID, shell) in identities where shell.shellPID == pid {
        if matched != nil {
          return nil
        }
        guard let shellStartTime = shell.shellStartTime,
          let currentStartTime = identity.startTime,
          currentStartTime == shellStartTime
        else {
          return nil
        }
        matched = (sessionID, shell)
      }
      currentPID = processTreeInspector.parentPID(of: pid)
    }

    guard let matched else { return nil }
    return matched
  }

  private func resolveAttachProcessChain(
    peerPID: pid_t,
    shellPID: pid_t
  ) -> ControlAttachProcessChain? {
    var entries: [ControlProcessIdentity] = []
    var currentPID: pid_t? = peerPID
    while let pid = currentPID, pid > 0 {
      let identity = processTreeInspector.identity(for: pid)
      entries.append(identity)
      if pid == shellPID { break }
      currentPID = processTreeInspector.parentPID(of: pid)
    }
    guard let last = entries.last, last.pid == shellPID else { return nil }
    return ControlAttachProcessChain(entries: entries)
  }

  private func resolveRouteAndIntent(
    method: String,
    path: String,
    query: [String: String],
    body: Data
  ) -> (
    routeID: String?,
    intentID: String?,
    capability: Capability?,
    sensitivity: String,
    sideEffectClass: String
  ) {
    for candidate in ControlRouteCatalog.routes {
      guard candidate.match(method: method, path: path) != nil else { continue }
      let request = ControlHTTPRequest(
        method: method,
        path: path,
        query: query,
        pathParameters: [:],
        body: body)
      switch candidate.resolveIntentID(request, .appObserve) {
      case .resolved(let intentID):
        guard let descriptor = catalog.descriptor(id: intentID) else { continue }
        return (
          "\(method) \(path)",
          intentID,
          descriptor.requiredCapability,
          descriptor.dataSensitivity.rawValue,
          sideEffectClassFor(descriptor.sideEffects)
        )
      case .failed:
        continue
      }
    }
    return (nil, nil, nil, "none", "none")
  }

  private func sideEffectClassFor(_ sideEffects: IntentDescriptor.SideEffects) -> String {
    if sideEffects.ptyInput { return "ptyInput" }
    if sideEffects.lifecycle { return "lifecycle" }
    if sideEffects.clipboard { return "clipboard" }
    if sideEffects.filesystem { return "filesystem" }
    if sideEffects.network { return "network" }
    return "none"
  }

  private func computeSHA256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func revalidateLazyAttachContext(
    _ context: ControlAttachApprovalContext,
    clientFD: Int32
  ) -> Bool {
    guard let currentPID = Self.peerPID(clientFD: clientFD) else { return false }
    guard currentPID == context.peerPID else { return false }
    let identity = processTreeInspector.identity(for: currentPID)
    guard let startTime = identity.startTime else { return false }
    guard startTime == context.peerStartTime else { return false }
    return true
  }

  private func lazyAttachResponse(
    sessionID: String,
    approval: String,
    downstream: ControlResponse
  ) -> ControlResponse {
    let bodyString = String(data: downstream.body, encoding: .utf8) ?? ""
    let payload: [String: Any] = [
      "ok": true,
      "sessionID": sessionID,
      "approval": approval,
      "downstreamStatus": downstream.status,
      "downstreamBody": bodyString,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else {
      return .error(500, "internal error")
    }
    return ControlResponse(
      status: 200,
      contentType: "application/json",
      body: data)
  }

  private func reportLazyAttachDeny(
    sessionID: String?,
    reason: String
  ) {
    let context = ControlSecurityContext(
      intentID: "control.attach.request",
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachDeny(context, reason: .forbiddenScope)
  }

  private func reportLazyAttachApproved(
    sessionID: String,
    approvalID: String,
    intentID: String,
    mode: String
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachApprove(context, mode: mode)
  }

  private func reportLazyAttachAutoApproved(
    sessionID: String,
    approvalID: String,
    intentID: String
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachAutoApprove(context, approvalID: approvalID)
  }

  private func reportLazyAttachRequest(
    sessionID: String,
    intentID: String
  ) {
    let context = ControlSecurityContext(
      intentID: intentID,
      capability: .observeSensitive,
      surface: surface,
      sessionID: sessionID)
    securityObserver?.didAttachRequest(context)
  }
}
