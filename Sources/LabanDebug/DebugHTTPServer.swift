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
  private let runtime: HeadlessDebugRuntime
  private var serverFD: Int32 = -1

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

    serverFD = fd

    let thread = Thread { self.acceptLoop() }
    thread.name = "debug-http-accept"
    thread.start()

    return DebugReadiness(
      debugServer: "http://127.0.0.1:\(actualPort)",
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
      var clientAddr = sockaddr_in()
      var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let clientFD = withUnsafeMutableBytes(of: &clientAddr) { ptr in
        accept(serverFD, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &clientLen)
      }
      guard clientFD >= 0 else { break }
      handleConnection(clientFD)
    }
  }

  // MARK: - Connection handling (one request per connection)

  private func handleConnection(_ fd: Int32) {
    defer { Darwin.close(fd) }

    // Read until \r\n\r\n to find end of headers.
    var raw = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    var headerEnd = -1

    while raw.count < 65536 {
      let n = recv(fd, &buf, buf.count, 0)
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

    let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
    var body = Data(raw[headerEnd...].prefix(contentLength))
    while body.count < contentLength {
      let need = min(contentLength - body.count, 4096)
      var bodyBuf = [UInt8](repeating: 0, count: need)
      let n = recv(fd, &bodyBuf, need, 0)
      guard n > 0 else { break }
      body.append(contentsOf: bodyBuf[0..<n])
    }

    let resp = route(method: method, path: path, query: parseQuery(queryString), body: body)
    let bytes = buildHTTPResponse(resp)
    bytes.withUnsafeBytes { ptr in
      _ = send(fd, ptr.baseAddress!, ptr.count, 0)
    }
  }

  // MARK: - Routing

  private func route(method: String, path: String, query: [String: String], body: Data)
    -> HTTPResponse
  {
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

    case ("GET", "/debug/render"):
      return json(runtime.renderState())

    case ("GET", "/debug/frame-commands"):
      return json(runtime.frameCommands(query: query))

    case ("POST", "/debug/render-trace"):
      return json(runtime.renderTrace(body))

    case ("POST", "/debug/pixel-probe"):
      return json(runtime.pixelProbe(body))

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
    case 400: return "Bad Request"
    case 409: return "Conflict"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "Unknown"
    }
  }
}
