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
  case nonLoopbackHost
}

public final class LabanControlServer {
  private struct ParsedHeaders {
    var host: String?
    var origin: String?
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
  private let connectionQueue = DispatchQueue(
    label: "com.laban.control.conn", attributes: .concurrent)
  private var fd: Int32 = -1
  private var token = ""
  private var thread: Thread?

  public init(router: IntentRouter, surface: Surface, catalog: IntentCatalog = .all) {
    self.router = router
    self.surface = surface
    self.catalog = catalog
  }

  public func start() throws -> (url: String, token: String) {
    let readiness = try start(host: "127.0.0.1", port: 0)
    return (readiness.debugServer, readiness.debugToken)
  }

  public func start(host: String, port: UInt16) throws -> ControlReadiness {
    guard fd < 0 else { throw LabanControlServerError.alreadyStarted }
    guard Self.isLoopbackBindHost(host) else { throw LabanControlServerError.nonLoopbackHost }

    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw LabanControlServerError.socketFailed }

    var one: Int32 = 1
    setsockopt(
      listener, SOL_SOCKET, SO_REUSEADDR, &one,
      socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(port)
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

    let bindResult = withUnsafeBytes(of: &addr) { ptr in
      Darwin.bind(
        listener,
        ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    guard bindResult == 0 else {
      Darwin.close(listener)
      throw LabanControlServerError.bindFailed
    }

    guard listen(listener, 16) == 0 else {
      Darwin.close(listener)
      throw LabanControlServerError.listenFailed
    }

    var bound = sockaddr_in()
    var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutableBytes(of: &bound) { ptr in
      getsockname(
        listener,
        ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        &boundLen)
    }
    let actualPort = CFSwapInt16BigToHost(bound.sin_port)

    let mintedToken = Self.makeToken()
    token = mintedToken
    fd = listener

    let acceptThread = Thread { self.acceptLoop() }
    acceptThread.name = "laban-control-accept"
    acceptThread.start()
    thread = acceptThread

    let process = ProcessInfo.processInfo
    return ControlReadiness(
      debugServer: "http://127.0.0.1:\(actualPort)",
      debugToken: mintedToken,
      pid: process.processIdentifier,
      runId: process.environment["LABAN_RUN_ID"] ?? "gui-\(process.processIdentifier)")
  }

  public func stop() {
    let listener = fd
    fd = -1
    if listener >= 0 { Darwin.close(listener) }
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
    // Any Origin header means a browser is calling this local API.
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

  private static func isLoopbackBindHost(_ host: String) -> Bool {
    host == "127.0.0.1" || host == "localhost"
  }

  private func acceptLoop() {
    while true {
      let listener = fd
      guard listener >= 0 else { break }
      var clientAddr = sockaddr_in()
      var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let clientFD = withUnsafeMutableBytes(of: &clientAddr) { ptr in
        accept(listener, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &clientLen)
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

    let guardOutcome = Self.evaluateGuard(
      host: headers.host,
      origin: headers.origin,
      authorization: headers.authorization,
      token: token)
    switch guardOutcome {
    case .forbidden:
      send(clientFD, .error(403, "forbidden"))
      return
    case .unauthorized:
      send(clientFD, Self.unauthorizedResponse())
      return
    case .ok:
      break
    }

    send(
      clientFD,
      route(
        method: method,
        path: parsedTarget.path,
        query: parsedTarget.query,
        body: body))
  }

  private func route(
    method: String,
    path: String,
    query: [String: String],
    body: Data
  ) -> ControlResponse {
    let request = ControlHTTPRequest(method: method, path: path, query: query, body: body)
    guard
      let route = ControlRouteCatalog.routes.first(where: { $0.matches(method: method, path: path) }
      )
    else {
      return .error(404, "not found")
    }

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
      return .error(404, "unavailable on \(surface)")
    }

    return route.dispatch(self, request)
  }

  func dispatchDebugAction(_ request: ControlHTTPRequest) -> ControlResponse {
    guard let envelope = try? JSONDecoder().decode(DebugActionEnvelope.self, from: request.body)
    else {
      return .error(400, "bad request")
    }

    switch DebugActionIntentID.intentID(forAction: envelope.action) {
    case "tab.select":
      return dispatchSelectTab(request)
    case "terminal.typeText":
      return dispatchTypeText(request)
    case "terminal.sendKey":
      return dispatchSendKey(request)
    case nil:
      return router.route(
        .unsupportedDebugAction(UnsupportedDebugActionInput(action: envelope.action)))
    default:
      return .error(501, "not yet ported")
    }
  }

  private func dispatchSelectTab(_ request: ControlHTTPRequest) -> ControlResponse {
    guard let action = try? JSONDecoder().decode(SelectTabActionRequest.self, from: request.body)
    else {
      return .error(400, "bad request")
    }
    _ = action.action
    guard let index = action.index else {
      return .error(400, "missing index")
    }
    return router.route(.tabSelect(TabSelectInput(index: index)))
  }

  private func dispatchTypeText(_ request: ControlHTTPRequest) -> ControlResponse {
    guard let action = try? JSONDecoder().decode(TextActionRequest.self, from: request.body)
    else {
      return .error(400, "bad request")
    }
    guard let text = action.text else {
      return .error(400, "missing text")
    }
    return router.route(.terminalTypeText(TypeTextInput(text: text)))
  }

  private func dispatchSendKey(_ request: ControlHTTPRequest) -> ControlResponse {
    guard let action = try? JSONDecoder().decode(DebugKeyActionRequest.self, from: request.body)
    else {
      return .error(400, "bad request")
    }
    guard let key = action.key else {
      return .error(400, "missing key")
    }
    return router.route(.terminalSendKey(SendKeyInput(key: key, modifiers: action.modifiers ?? [])))
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
      case "host":
        parsed.host = value
      case "origin":
        parsed.origin = value
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
