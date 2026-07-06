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
  }

  private enum ContentLengthResult {
    case success(Int)
    case failure(status: Int)
  }

  private static let requestReadTimeout: TimeInterval = 5
  private static let maxHeaderBytes = 64 * 1024
  private static let maxBodyBytes = 4 * 1024 * 1024

  public static let endpoints: [ControlEndpointDescriptor] = ControlRouteCatalog.endpoints

  public static let routes: [HTTPBinding] = ControlRouteCatalog.bindings

  let router: IntentRouter
  private let surface: Surface
  private let catalog: IntentCatalog
  private let readinessRunID: String?
  private weak var securityObserver: (any ControlSecurityObserver)?
  private let connectionQueue = DispatchQueue(
    label: "com.laban.control.conn", attributes: .concurrent)
  private var fd: Int32 = -1
  private var socketPath: String?
  private var tokens: [String: ControlTokenTier] = [:]
  private var attachBootstraps: [String: SessionAttachBootstrap] = [:]
  private let attachLock = NSLock()
  private var thread: Thread?

  private struct SessionAttachBootstrap: Equatable {
    let sessionID: String
    var consumed: Bool
    var redeemerPID: pid_t?
  }

  public static let sessionAttachPath = "/control/session/attach"

  public init(
    router: IntentRouter,
    surface: Surface,
    catalog: IntentCatalog = .all,
    readinessRunID: String? = nil,
    securityObserver: (any ControlSecurityObserver)? = nil
  ) {
    self.router = router
    self.surface = surface
    self.catalog = catalog
    self.readinessRunID = readinessRunID
    self.securityObserver = securityObserver
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
    attachBootstraps[bootstrap] = SessionAttachBootstrap(sessionID: sessionID, consumed: false)
    attachLock.unlock()
    return bootstrap
  }

  /// Registers the shell PID allowed to redeem a session's attach bootstrap (C14).
  public func registerAttachRedeemerPID(sessionID: String, pid: pid_t) {
    attachLock.lock()
    defer { attachLock.unlock() }
    for (bootstrap, var entry) in attachBootstraps where entry.sessionID == sessionID {
      entry.redeemerPID = pid
      attachBootstraps[bootstrap] = entry
    }
  }

  /// Redeems a bootstrap once, registering a session-observe bearer token.
  public func redeemSessionAttachBootstrap(_ bootstrap: String, peerPID: pid_t) -> (token: String, sessionID: String)? {
    attachLock.lock()
    defer { attachLock.unlock() }
    guard var entry = attachBootstraps[bootstrap], !entry.consumed else {
      return nil
    }
    if let redeemerPID = entry.redeemerPID, redeemerPID != peerPID {
      return nil
    }
    entry.consumed = true
    attachBootstraps[bootstrap] = entry
    let token = mintSessionObserveToken(sessionID: entry.sessionID)
    return (token, entry.sessionID)
  }

  /// Mints a session-observe token bound to `sessionID`.
  public func mintSessionObserveToken(sessionID: String) -> String {
    let token = Self.makeToken()
    registerToken(token, tier: .sessionObserve(sessionID: sessionID))
    return token
  }

  public func stop() {
    let listener = fd
    fd = -1
    if listener >= 0 { Darwin.close(listener) }
    if let socketPath {
      unlink(socketPath)
      self.socketPath = nil
    }
    tokens = [:]
    attachLock.lock()
    attachBootstraps = [:]
    attachLock.unlock()
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
    tokens[token] = tier
  }

  private func bindListener(at path: String) throws {
    guard fd < 0 else { throw LabanControlServerError.alreadyStarted }

    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    unlink(path)

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw LabanControlServerError.socketFailed }

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

  private func handleConnection(_ clientFD: Int32) {
    defer { Darwin.close(clientFD) }
    setReceiveTimeout(clientFD)

    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var headerEnd = -1
    let headerDeadline = Date().addingTimeInterval(Self.requestReadTimeout)
    while raw.count < Self.maxHeaderBytes {
      if Date() > headerDeadline { return }
      let n = recv(clientFD, &buffer, buffer.count, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return }
      raw.append(contentsOf: buffer[0..<n])
      if let range = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
        headerEnd = range.upperBound
        break
      }
    }

    guard headerEnd >= 0 else {
      send(clientFD, .error(413, "request too large"))
      return
    }
    guard let headerString = String(data: raw[0..<headerEnd], encoding: .utf8) else {
      send(clientFD, .error(400, "bad request"))
      return
    }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      send(clientFD, .error(400, "bad request"))
      return
    }
    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else {
      send(clientFD, .error(400, "bad request"))
      return
    }

    let method = parts[0]
    let rawPath = parts[1]
    let parsedTarget = Self.parseRequestTarget(rawPath)
    let headers = parseHeaders(Array(lines.dropFirst()))

    guard method == "GET" || method == "POST" else {
      send(clientFD, .error(405, "method not allowed"))
      return
    }
    guard headers.authorizationCount <= 1 else {
      send(clientFD, .error(400, "duplicate authorization header"))
      return
    }

    let contentLength: Int
    switch parseContentLength(headers.contentLengthHeader, method: method) {
    case .success(let length):
      contentLength = length
    case .failure(let status):
      send(clientFD, .error(status, status == 413 ? "request too large" : "bad request"))
      return
    }

    var body = Data(raw[headerEnd...].prefix(contentLength))
    let bodyDeadline = Date().addingTimeInterval(Self.requestReadTimeout)
    while body.count < contentLength {
      if Date() > bodyDeadline { return }
      let need = min(contentLength - body.count, 4096)
      var bodyBuffer = [UInt8](repeating: 0, count: need)
      let n = recv(clientFD, &bodyBuffer, need, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return }
      body.append(contentsOf: bodyBuffer[0..<n])
    }

    let peerOutcome = Self.evaluatePeerCredential(clientFD: clientFD)
    if method == "POST", parsedTarget.path == Self.sessionAttachPath {
      let peerPID = Self.peerPID(clientFD: clientFD)
      send(clientFD, handleSessionAttach(body: body, peerOutcome: peerOutcome, peerPID: peerPID))
      return
    }

    let (authOutcome, tokenTier) = Self.evaluateAuthorization(
      peerOutcome: peerOutcome,
      authorization: headers.authorization,
      tokens: tokens)
    switch authOutcome {
    case .forbidden:
      reportDeny(
        reason: peerOutcome == .forbidden ? .peerCredential : .forbiddenCapability,
        targetSession: sessionID(from: tokenTier),
        tokenTier: tokenTier)
      send(clientFD, .error(403, "forbidden"))
      return
    case .unauthorized:
      reportDeny(reason: .unauthorized, targetSession: sessionID(from: tokenTier))
      send(clientFD, Self.unauthorizedResponse())
      return
    case .ok:
      break
    }

    guard let tokenTier else {
      send(clientFD, Self.unauthorizedResponse())
      return
    }

    send(
      clientFD,
      route(
        method: method,
        path: parsedTarget.path,
        query: parsedTarget.query,
        body: body,
        tokenTier: tokenTier))
  }

  private func handleSessionAttach(body: Data, peerOutcome: GuardOutcome, peerPID: pid_t?) -> ControlResponse {
    guard peerOutcome == .ok else {
      return .error(403, "forbidden")
    }
    guard let peerPID else {
      return .error(403, "forbidden")
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let bootstrap = json["bootstrap"] as? String,
      !bootstrap.isEmpty
    else {
      return .error(400, "bad request")
    }
    guard let redeemed = redeemSessionAttachBootstrap(bootstrap, peerPID: peerPID) else {
      return .error(401, "invalid or spent bootstrap")
    }
    let payload: [String: Any] = [
      "ok": true,
      "token": redeemed.token,
      "sessionID": redeemed.sessionID,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else {
      return .error(500, "internal error")
    }
    return ControlResponse(status: 200, contentType: "application/json", body: data)
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
    switch route.resolveIntentID(request) {
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
    guard granted.contains(descriptor.requiredCapability) else {
      reportDeny(
        intentID: intentID,
        capability: descriptor.requiredCapability,
        reason: .forbiddenCapability,
        targetSession: targetSession,
        tokenTier: tokenTier)
      return .error(403, "forbidden")
    }
    guard
      LabanControlPolicy.authorize(
        intentID: intentID,
        catalog: catalog,
        granted: granted,
        targetSession: targetSession,
        tokenScope: scope)
    else {
      reportDeny(
        intentID: intentID,
        capability: descriptor.requiredCapability,
        reason: .forbiddenScope,
        targetSession: targetSession,
        tokenTier: tokenTier)
      return .error(403, "forbidden")
    }

    reportAuthorize(
      intentID: intentID,
      capability: descriptor.requiredCapability,
      targetSession: targetSession,
      tokenTier: tokenTier)
    return route.dispatch(self, request, tokenTier)
  }

  private func sessionID(from tokenTier: ControlTokenTier?) -> String? {
    guard let tokenTier else { return nil }
    if case .sessionObserve(let sessionID) = tokenTier {
      return sessionID
    }
    return nil
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

  func legacyQueryInput(
    intentID: String,
    params: [String: String],
    tokenTier: ControlTokenTier
  ) -> LegacyDebugQueryInput {
    let scopedSessionID: String?
    if case .sessionObserve(let sessionID) = tokenTier {
      scopedSessionID = sessionID
    } else {
      scopedSessionID = nil
    }
    return LegacyDebugQueryInput(
      intentID: intentID, params: params, scopedSessionID: scopedSessionID)
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

  func dispatchDebugAction(_ request: ControlHTTPRequest, tokenTier: ControlTokenTier) -> ControlResponse {
    guard let envelope = try? JSONDecoder().decode(DebugActionEnvelope.self, from: request.body)
    else {
      return .error(400, "bad request")
    }

    guard let intentID = DebugActionIntentID.intentID(forAction: envelope.action) else {
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

  private func send(_ clientFD: Int32, _ response: ControlResponse) {
    var header = "HTTP/1.1 \(response.status) \(Self.statusText(response.status))\r\n"
    header += "Content-Type: \(response.contentType)\r\n"
    header += "Content-Length: \(response.body.count)\r\n"
    header += "Connection: close\r\n"
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

  private func setReceiveTimeout(_ clientFD: Int32) {
    var timeout = timeval(tv_sec: Int(Self.requestReadTimeout), tv_usec: 0)
    setsockopt(
      clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
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
    case 413: return "Payload Too Large"
    case 500: return "Internal Server Error"
    case 501: return "Not Implemented"
    default: return "Unknown"
    }
  }
}
