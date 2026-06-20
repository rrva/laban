import Darwin
import Dispatch
import Foundation

enum GuardOutcome: Equatable {
  case ok
  case unauthorized
  case forbidden
}

final class LabanControlServer {
  private struct Response {
    var status: Int
    var contentType: String
    var extraHeaders: [String] = []
    var body: Data

    static func json(_ object: Any, status: Int = 200, extraHeaders: [String] = []) -> Response {
      let body =
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        ?? Data("{}".utf8)
      return Response(
        status: status,
        contentType: "application/json",
        extraHeaders: extraHeaders,
        body: body)
    }

    static func encodable<T: Encodable>(_ value: T, status: Int = 200) -> Response {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
      return Response(status: status, contentType: "application/json", body: body)
    }
  }

  private struct ParsedHeaders {
    var host: String?
    var origin: String?
    var authorization: String?
    var authorizationCount = 0
    var contentLengthHeader: String?
  }

  private struct ActionRequest: Decodable {
    let action: String
    let index: Int?
  }

  private enum ContentLengthResult {
    case success(Int)
    case failure(status: Int)
  }

  private enum ServerError: Error {
    case socketFailed
    case bindFailed
    case listenFailed
    case alreadyStarted
  }

  private static let requestReadTimeout: TimeInterval = 5
  private static let maxHeaderBytes = 16 * 1024
  private static let maxBodyBytes = 1024 * 1024

  private let router: ControlRouter
  private let connectionQueue = DispatchQueue(
    label: "com.laban.control.conn", attributes: .concurrent)
  private var fd: Int32 = -1
  private var token = ""
  private var thread: Thread?

  init(router: ControlRouter) {
    self.router = router
  }

  func start() throws -> (url: String, token: String) {
    guard fd < 0 else { throw ServerError.alreadyStarted }

    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw ServerError.socketFailed }

    var one: Int32 = 1
    setsockopt(
      listener, SOL_SOCKET, SO_REUSEADDR, &one,
      socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(0)
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

    let bindResult = withUnsafeBytes(of: &addr) { ptr in
      Darwin.bind(
        listener,
        ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    guard bindResult == 0 else {
      Darwin.close(listener)
      throw ServerError.bindFailed
    }

    guard listen(listener, 16) == 0 else {
      Darwin.close(listener)
      throw ServerError.listenFailed
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

    return ("http://127.0.0.1:\(actualPort)", mintedToken)
  }

  func stop() {
    let listener = fd
    fd = -1
    if listener >= 0 { Darwin.close(listener) }
    thread = nil
  }

  deinit {
    stop()
  }

  static func evaluateGuard(
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

  static func isLoopbackHost(_ host: String?) -> Bool {
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

  static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
    let count = max(x.count, y.count)
    for i in 0..<count {
      diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return diff == 0
  }

  static func makeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32)
      .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
      .joined()
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
      send(clientFD, .json(["error": "request too large"], status: 413))
      return
    }
    guard let headerString = String(data: raw[0..<headerEnd], encoding: .utf8) else {
      send(clientFD, .json(["error": "bad request"], status: 400))
      return
    }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      send(clientFD, .json(["error": "bad request"], status: 400))
      return
    }
    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else {
      send(clientFD, .json(["error": "bad request"], status: 400))
      return
    }

    let method = parts[0]
    let rawPath = parts[1]
    let path = rawPath.components(separatedBy: "?")[0]
    let headers = parseHeaders(Array(lines.dropFirst()))

    guard method == "GET" || method == "POST" else {
      send(clientFD, .json(["error": "method not allowed"], status: 405))
      return
    }
    guard headers.authorizationCount <= 1 else {
      send(clientFD, .json(["error": "duplicate authorization header"], status: 400))
      return
    }

    let contentLength: Int
    switch parseContentLength(headers.contentLengthHeader, method: method) {
    case .success(let length):
      contentLength = length
    case .failure(let status):
      send(
        clientFD,
        .json(
          ["error": status == 413 ? "request too large" : "bad request"],
          status: status))
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
      send(clientFD, .json(["error": "forbidden"], status: 403))
      return
    case .unauthorized:
      send(
        clientFD,
        .json(
          ["error": "missing or invalid bearer token"],
          status: 401,
          extraHeaders: ["WWW-Authenticate: Bearer"]))
      return
    case .ok:
      break
    }

    send(clientFD, route(method: method, path: path, body: body))
  }

  private func route(method: String, path: String, body: Data) -> Response {
    switch (method, path) {
    case ("GET", "/debug/state"):
      return .encodable(router.snapshotState())
    case ("POST", "/debug/actions"):
      guard
        let request = try? JSONDecoder().decode(ActionRequest.self, from: body)
      else {
        return .json(["error": "bad request"], status: 400)
      }
      guard request.action == "selectTab" else {
        return .json(["error": "unsupported action"], status: 400)
      }
      guard let index = request.index else {
        return .json(["error": "missing index"], status: 400)
      }
      return .encodable(router.selectTab(index: index))
    default:
      return .json(["error": "not found"], status: 404)
    }
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

  private func send(_ clientFD: Int32, _ response: Response) {
    var header = "HTTP/1.1 \(response.status) \(Self.statusText(response.status))\r\n"
    header += "Content-Type: \(response.contentType)\r\n"
    header += "Content-Length: \(response.body.count)\r\n"
    header += "Connection: close\r\n"
    for extra in response.extraHeaders {
      header += "\(extra)\r\n"
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
    default: return "Unknown"
    }
  }
}
