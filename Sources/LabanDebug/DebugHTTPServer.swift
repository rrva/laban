import Darwin
import Foundation

// MARK: - Internal HTTP response

private struct HTTPResponse {
  var status: Int
  var contentType: String
  var extraHeaders: [String]
  var body: Data
}

// MARK: - Server

public final class DebugHTTPServer {
  private static let maxHeaderBytes = 64 * 1024
  private static let maxBodyBytes = 4 * 1024 * 1024
  private static let requestReadTimeout: TimeInterval = 2.0

  private let runtime: HeadlessDebugRuntime
  private let connectionQueue = DispatchQueue(
    label: "debug-http-connections", attributes: .concurrent)
  private var serverFD: Int32 = -1
  private var bearerToken: String = ""

  public init(runtime: HeadlessDebugRuntime) {
    self.runtime = runtime
  }

  public func start(host: String, port: UInt16) throws -> DebugReadiness {
    guard host == "127.0.0.1" || host == "localhost" else {
      throw DebugServerError.nonLoopbackHost
    }

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DebugServerError.socketFailed }

    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(port)
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

    let bindResult = withUnsafeBytes(of: &addr) { ptr in
      bind(
        fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    guard bindResult == 0 else {
      Darwin.close(fd)
      throw DebugServerError.bindFailed
    }

    guard listen(fd, 16) == 0 else {
      Darwin.close(fd)
      throw DebugServerError.listenFailed
    }

    // Discover actual bound port (handles port 0).
    var bound = sockaddr_in()
    var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutableBytes(of: &bound) { ptr in
      getsockname(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &boundLen)
    }
    let actualPort = CFSwapInt16BigToHost(bound.sin_port)

    let token = Self.makeBearerToken()
    bearerToken = token
    serverFD = fd

    let thread = Thread { self.acceptLoop() }
    thread.name = "debug-http-accept"
    thread.start()

    return DebugReadiness(
      debugServer: "http://127.0.0.1:\(actualPort)",
      debugToken: token,
      pid: ProcessInfo.processInfo.processIdentifier,
      runId: runtime.runId
    )
  }

  public func stop() {
    let fd = serverFD
    serverFD = -1
    if fd >= 0 { Darwin.close(fd) }
  }

  // MARK: - Accept loop

  private func acceptLoop() {
    while true {
      let listenFD = serverFD
      guard listenFD >= 0 else { break }
      var clientAddr = sockaddr_in()
      var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let clientFD = withUnsafeMutableBytes(of: &clientAddr) { ptr in
        accept(listenFD, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &clientLen)
      }
      if clientFD >= 0 {
        connectionQueue.async { [self] in
          handleConnection(clientFD)
        }
        continue
      }

      let err = errno
      if serverFD < 0 || err == EBADF || err == EINVAL {
        break
      }
      if err == EINTR || err == ECONNABORTED {
        continue
      }
      if err == EMFILE || err == ENFILE {
        usleep(100_000)
        continue
      }
      break
    }
  }

  // MARK: - Connection handling (one request per connection)

  private func handleConnection(_ fd: Int32) {
    defer { Darwin.close(fd) }
    setReceiveTimeout(fd)

    // Read until \r\n\r\n to find end of headers.
    var raw = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    var headerEnd = -1

    let headerDeadline = Date().addingTimeInterval(Self.requestReadTimeout)
    while raw.count < Self.maxHeaderBytes {
      if Date() > headerDeadline { return }
      let n = recv(fd, &buf, buf.count, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return }
      raw.append(contentsOf: buf[0..<n])
      if let range = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
        headerEnd = range.upperBound
        break
      }
    }
    guard headerEnd >= 0 else { return }

    guard let headerStr = String(data: raw[0..<headerEnd], encoding: .utf8) else { return }
    let lines = headerStr.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return }

    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else { return }
    let method = parts[0]
    let rawPath = parts[1]

    let pathAndQuery = rawPath.components(separatedBy: "?")
    let path = pathAndQuery[0]
    let queryString = pathAndQuery.count > 1 ? pathAndQuery[1] : ""

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard !line.isEmpty else { break }
      if let colonIdx = line.firstIndex(of: ":") {
        let key = line[..<colonIdx].lowercased()
        let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        headers[key] = val
      }
    }

    // Clamp Content-Length: signed parse + cap. A negative value would
    // crash `prefix(contentLength)`; an unbounded huge value would
    // block the single-threaded server in the read loop. The cap is
    // generous enough for any legitimate debug request and small
    // enough to refuse hostile bodies cheaply.
    let parsed = headers["content-length"].flatMap { Int($0) } ?? 0
    let contentLength = max(0, min(parsed, Self.maxBodyBytes))
    var body = Data(raw[headerEnd...].prefix(contentLength))
    let readDeadline = Date().addingTimeInterval(Self.requestReadTimeout)
    while body.count < contentLength {
      // Bound the read loop in wall time too — a peer that stops
      // sending mid-body must not pin our handler forever.
      if Date() > readDeadline { break }
      let need = min(contentLength - body.count, 4096)
      var bodyBuf = [UInt8](repeating: 0, count: need)
      let n = recv(fd, &bodyBuf, need, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { break }
      body.append(contentsOf: bodyBuf[0..<n])
    }

    let resp = route(
      method: method, path: path, query: parseQuery(queryString), headers: headers, body: body)
    let bytes = buildHTTPResponse(resp)
    bytes.withUnsafeBytes { ptr in
      _ = send(fd, ptr.baseAddress!, ptr.count, 0)
    }
  }

  // MARK: - Routing

  private func route(
    method: String, path: String, query: [String: String], headers: [String: String], body: Data
  )
    -> HTTPResponse
  {
    guard isAuthorized(headers: headers) else {
      return HTTPResponse(
        status: 401, contentType: "application/json",
        extraHeaders: ["WWW-Authenticate: Bearer"],
        body: #"{"error":"missing or invalid bearer token"}"#.data(using: .utf8)!)
    }

    switch (method, path) {
    case ("GET", "/debug"), ("GET", "/debug/capabilities"):
      return json(runtime.discovery())

    case ("GET", "/debug/health"):
      return json(runtime.health())

    case ("GET", "/debug/state"):
      return json(runtime.state())

    case ("GET", "/debug/screenshot"):
      do {
        let (data, frame, width, height) = try runtime.screenshotBytes()
        return HTTPResponse(
          status: 200, contentType: "image/png",
          extraHeaders: [
            "X-App-Frame: \(frame)",
            "X-App-Size: \(width)x\(height)",
          ],
          body: data
        )
      } catch {
        return json(jsonError("screenshot failed: \(error)", status: 500))
      }

    case ("POST", "/debug/screenshot"):
      return json(runtime.writeScreenshotArtifact())

    case ("POST", "/debug/actions"):
      return json(runtime.applyAction(body))

    case ("GET", "/debug/sessions"):
      return json(runtime.sessions())

    case ("GET", let sessionPath) where sessionPath.hasPrefix("/debug/sessions/"):
      let rawId = String(sessionPath.dropFirst("/debug/sessions/".count))
      let id = rawId.removingPercentEncoding ?? rawId
      return json(runtime.session(id: id, query: query))

    case ("GET", "/debug/render"):
      return json(runtime.renderState())

    case ("GET", "/debug/frame-commands"):
      return json(runtime.frameCommands(query: query))

    case ("POST", "/debug/render-trace"):
      return json(runtime.renderTrace(body))

    case ("POST", "/debug/pixel-probe"):
      return json(runtime.pixelProbe(body))

    case ("GET", "/debug/atlas"):
      return json(runtime.atlas())

    case ("POST", "/debug/wait"):
      return json(runtime.wait(body))

    case ("POST", "/debug/fixture"):
      return json(runtime.fixtureControl(body))

    case ("POST", "/debug/snapshot"):
      return json(runtime.artifactSnapshot())

    case ("GET", "/debug/events"):
      let since = query["since"].flatMap { Int($0) } ?? 0
      return json(runtime.events(since: since))

    case ("GET", "/debug/input-log"):
      let since = query["since"].flatMap { Int($0) } ?? 0
      return json(runtime.inputLogResponse(since: since))

    case ("GET", "/debug/terminal-log"):
      return json(runtime.terminalLogResponse(query: query))

    case ("GET", "/debug/timing"):
      return json(runtime.timingResponse())

    case ("GET", "/debug/metrics"):
      return json(runtime.metricsResponse())

    case ("GET", "/debug/errors"):
      let since = query["since"].flatMap { Int($0) } ?? 0
      return json(runtime.errors(since: since))

    case ("GET", "/debug/capture/status"):
      return json(runtime.captureStatus())

    case ("POST", "/debug/capture/start"):
      return json(runtime.startCapture(body))

    case ("POST", "/debug/capture/stop"):
      return json(runtime.stopCapture())

    case ("POST", "/debug/capture/snapshot"):
      return json(runtime.captureSnapshot())

    case ("GET", "/debug/selection"):
      return json(runtime.selection())

    case ("GET", "/debug/clipboard"):
      return json(runtime.clipboard())

    default:
      return json(jsonError("not found", status: 404))
    }
  }

  // MARK: - Helpers

  private func json(_ r: DebugResponse) -> HTTPResponse {
    HTTPResponse(status: r.status, contentType: "application/json", extraHeaders: [], body: r.body)
  }

  private func parseQuery(_ s: String) -> [String: String] {
    var result: [String: String] = [:]
    guard !s.isEmpty else { return result }
    for pair in s.components(separatedBy: "&") {
      let kv = pair.components(separatedBy: "=")
      if kv.count == 2 {
        let k = kv[0].removingPercentEncoding ?? kv[0]
        let v = kv[1].removingPercentEncoding ?? kv[1]
        result[k] = v
      }
    }
    return result
  }

  private func buildHTTPResponse(_ r: HTTPResponse) -> Data {
    var header = "HTTP/1.1 \(r.status) \(statusText(r.status))\r\n"
    header += "Content-Type: \(r.contentType)\r\n"
    header += "Content-Length: \(r.body.count)\r\n"
    header += "Connection: close\r\n"
    for h in r.extraHeaders { header += "\(h)\r\n" }
    header += "\r\n"
    var data = header.data(using: .utf8)!
    data.append(r.body)
    return data
  }

  private func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 401: return "Unauthorized"
    case 400: return "Bad Request"
    case 409: return "Conflict"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "Unknown"
    }
  }

  private func setReceiveTimeout(_ fd: Int32) {
    var timeout = timeval(tv_sec: Int(Self.requestReadTimeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  private func isAuthorized(headers: [String: String]) -> Bool {
    guard let value = headers["authorization"] else { return false }
    guard value.count > 7, value.lowercased().hasPrefix("bearer ") else { return false }
    let token = String(value.dropFirst(7))
    return Self.constantTimeEquals(token, bearerToken)
  }

  private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
    let count = max(a.count, b.count)
    for i in 0..<count {
      diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
    }
    return diff == 0
  }

  private static func makeBearerToken() -> String {
    var rng = SystemRandomNumberGenerator()
    return (0..<32)
      .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }
      .joined()
  }
}
