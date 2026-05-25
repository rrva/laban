import Darwin
import Foundation

// MARK: - Internal HTTP response

private struct HTTPResponse {
  var status: Int
  var contentType: String
  var extraHeaders: [String]
  var body: Data
}

private struct DebugHTTPRequest {
  var query: [String: String]
  var body: Data
}

private struct DebugRouteMatch {
  var sessionId: String?
}

private struct DebugHTTPRoute {
  var endpoint: DebugDiscoveryEndpoint
  var match: (String, String) -> DebugRouteMatch?
  var handle: (HeadlessDebugRuntime, DebugHTTPRequest, DebugRouteMatch) -> HTTPResponse

  init(
    method: String,
    path: String,
    category: String,
    summary: String,
    queryParameters: [String] = [],
    requestSchema: String? = nil,
    responseSchema: String? = nil,
    match: ((String, String) -> DebugRouteMatch?)? = nil,
    handle: @escaping (HeadlessDebugRuntime, DebugHTTPRequest, DebugRouteMatch) -> HTTPResponse
  ) {
    self.endpoint = DebugDiscoveryEndpoint(
      method: method,
      path: path,
      category: category,
      summary: summary,
      queryParameters: queryParameters,
      requestSchema: requestSchema,
      responseSchema: responseSchema)
    if let match {
      self.match = match
    } else {
      self.match = { requestMethod, requestPath in
        requestMethod == method && requestPath == path ? DebugRouteMatch() : nil
      }
    }
    self.handle = handle
  }
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

  static var discoveryEndpoints: [DebugDiscoveryEndpoint] {
    routes.map(\.endpoint)
  }

  private static let routes: [DebugHTTPRoute] = [
    DebugHTTPRoute(
      method: "GET",
      path: "/debug",
      category: "discovery",
      summary: "List the live debug endpoints, controls, and command examples.",
      responseSchema: "schemas/debug/discovery.schema.json"
    ) { runtime, _, _ in
      json(runtime.discovery())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/capabilities",
      category: "discovery",
      summary: "Alias for /debug for agents that look for a capabilities document.",
      responseSchema: "schemas/debug/discovery.schema.json"
    ) { runtime, _, _ in
      json(runtime.discovery())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/health",
      category: "readiness",
      summary: "Check whether the process is ready and report the current frame."
    ) { runtime, _, _ in
      json(runtime.health())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/state",
      category: "state",
      summary: "Return tabs, active session identity, window size, and focus state.",
      responseSchema: "schemas/debug/state.schema.json"
    ) { runtime, _, _ in
      json(runtime.state())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Return the current rendered surface as PNG bytes."
    ) { runtime, _, _ in
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
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Write a screenshot PNG under the artifact directory.",
      responseSchema: "schemas/debug/screenshot-result.schema.json"
    ) { runtime, _, _ in
      json(runtime.writeScreenshotArtifact())
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/actions",
      category: "control",
      summary: "Drive tabs, input, mouse, clipboard, selection, and frames.",
      requestSchema: "schemas/debug/action.schema.json",
      responseSchema: "schemas/debug/action-result.schema.json"
    ) { runtime, request, _ in
      json(runtime.applyAction(request.body))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/persistence/state",
      category: "state",
      summary: "Inspect workspace.json, transcript files, and agent JSONL mirrors."
    ) { runtime, _, _ in
      json(runtime.persistenceState())
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/persistence/flush",
      category: "control",
      summary:
        "Drain the persistence debounce + transcript writers synchronously (simulates applicationWillTerminate)."
    ) { runtime, _, _ in
      json(runtime.persistenceFlush())
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/persistence/relaunch",
      category: "control",
      summary:
        "Flush, close every session, then rebuild from workspace.json. Use to run quit/restore cycles inside one debug-server lifetime."
    ) { runtime, _, _ in
      json(runtime.persistenceRelaunch())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/persistence/restore-picker",
      category: "state",
      summary:
        "Return pending Claude/Codex semantic restore candidates after a laband daemon-loss restore."
    ) { runtime, _, _ in
      json(runtime.persistenceRestorePicker())
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/persistence/restore-picker/select",
      category: "control",
      summary:
        "Launch selected Claude/Codex semantic restores through the native resume trampoline."
    ) { runtime, request, _ in
      json(runtime.persistenceRestoreSelection(request.body))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/find/start",
      category: "control",
      summary: "Start literal find in the active or named terminal session.",
      requestSchema: "schemas/debug/find-start.schema.json",
      responseSchema: "schemas/debug/find-state.schema.json"
    ) { runtime, request, _ in
      json(runtime.findStart(request.body))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/find/step",
      category: "control",
      summary: "Advance the selected find match in the active or named terminal session.",
      requestSchema: "schemas/debug/find-step.schema.json",
      responseSchema: "schemas/debug/find-state.schema.json"
    ) { runtime, request, _ in
      json(runtime.findStep(request.body))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/find/stop",
      category: "control",
      summary: "Stop find and clear highlights in the active or named terminal session.",
      requestSchema: "schemas/debug/find-stop.schema.json"
    ) { runtime, request, _ in
      json(runtime.findStop(request.body))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/find/state",
      category: "state",
      summary: "Return current find state for the active or named terminal session.",
      queryParameters: ["sessionID", "sessionId"],
      responseSchema: "schemas/debug/find-state.schema.json"
    ) { runtime, request, _ in
      json(runtime.findState(query: request.query))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/shell-integration/state",
      category: "state",
      summary:
        "Return OSC 133 shell-integration phase + last exit code for the active or named session.",
      queryParameters: ["sessionID", "sessionId"],
      responseSchema: "schemas/debug/shell-integration-state.schema.json"
    ) { runtime, request, _ in
      json(runtime.shellIntegrationState(query: request.query))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/wait",
      category: "control",
      summary: "Block until a frame, state, text, event, or render condition is true.",
      requestSchema: "schemas/debug/wait.schema.json",
      responseSchema: "schemas/debug/wait-result.schema.json"
    ) { runtime, request, _ in
      json(runtime.wait(request.body))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/sessions",
      category: "state",
      summary: "Return terminal-session lifecycle and metadata for all tabs.",
      responseSchema: "schemas/debug/sessions.schema.json"
    ) { runtime, _, _ in
      json(runtime.sessions())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/sessions/<id>",
      category: "state",
      summary: "Return one terminal session, optionally with bounded visible-grid cells.",
      queryParameters: ["includeGrid"],
      responseSchema: "schemas/debug/session.schema.json",
      match: { requestMethod, requestPath in
        guard requestMethod == "GET", requestPath.hasPrefix("/debug/sessions/") else {
          return nil
        }
        let rawId = String(requestPath.dropFirst("/debug/sessions/".count))
        return DebugRouteMatch(sessionId: rawId.removingPercentEncoding ?? rawId)
      },
      handle: { runtime, request, match in
        json(runtime.session(id: match.sessionId ?? "", query: request.query))
      }
    ),
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/render",
      category: "rendering",
      summary: "Return surface, viewport, cell size, damage, and draw stats.",
      responseSchema: "schemas/debug/render.schema.json"
    ) { runtime, _, _ in
      json(runtime.renderState())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/frame-commands",
      category: "rendering",
      summary: "Return bounded frame commands, optionally filtered by source.",
      queryParameters: ["source", "limit"],
      responseSchema: "schemas/debug/frame-commands.schema.json"
    ) { runtime, request, _ in
      json(runtime.frameCommands(query: request.query))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/render-trace",
      category: "rendering",
      summary: "Return render contributors, resources, passes, probes, and invariants.",
      requestSchema: "schemas/debug/render-trace-request.schema.json",
      responseSchema: "schemas/debug/render-trace.schema.json"
    ) { runtime, request, _ in
      json(runtime.renderTrace(request.body))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/pixel-probe",
      category: "exploration",
      summary: "Sample exact pixels and rectangular regions from the rendered surface.",
      requestSchema: "schemas/debug/pixel-probe.schema.json",
      responseSchema: "schemas/debug/pixel-probe-result.schema.json"
    ) { runtime, request, _ in
      json(runtime.pixelProbe(request.body))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/atlas",
      category: "rendering",
      summary: "Return font, cell, and glyph diagnostics for the active renderer.",
      responseSchema: "schemas/debug/atlas.schema.json"
    ) { runtime, _, _ in
      json(runtime.atlas())
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/snapshot",
      category: "exploration",
      summary: "Write a one-shot diagnostic bundle with JSON state and a screenshot.",
      responseSchema: "schemas/debug/snapshot-result.schema.json"
    ) { runtime, _, _ in
      json(runtime.artifactSnapshot())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/events",
      category: "logs",
      summary: "Return bounded app/debug events after a sequence number.",
      queryParameters: ["since"],
      responseSchema: "schemas/debug/events.schema.json"
    ) { runtime, request, _ in
      json(runtime.events(since: request.query["since"].flatMap { Int($0) } ?? 0))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/input-log",
      category: "logs",
      summary: "Return keyboard/text routing diagnostics after a sequence number.",
      queryParameters: ["since"],
      responseSchema: "schemas/debug/input-log.schema.json"
    ) { runtime, request, _ in
      json(runtime.inputLogResponse(since: request.query["since"].flatMap { Int($0) } ?? 0))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/terminal-log",
      category: "logs",
      summary: "Return bounded escaped terminal input/output byte-flow diagnostics.",
      queryParameters: ["sessionId", "since", "limit"],
      responseSchema: "schemas/debug/terminal-log.schema.json"
    ) { runtime, request, _ in
      json(runtime.terminalLogResponse(query: request.query))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/timing",
      category: "logs",
      summary: "Return frame and endpoint timing fields for sluggishness diagnosis.",
      responseSchema: "schemas/debug/timing.schema.json"
    ) { runtime, _, _ in
      json(runtime.timingResponse())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/metrics",
      category: "logs",
      summary: "Return local counters for frames, input, terminal bytes, and draw work.",
      responseSchema: "schemas/debug/metrics.schema.json"
    ) { runtime, _, _ in
      json(runtime.metricsResponse())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/errors",
      category: "logs",
      summary: "Return structured warnings and errors after a sequence number.",
      queryParameters: ["since"],
      responseSchema: "schemas/debug/errors.schema.json"
    ) { runtime, request, _ in
      json(runtime.errors(since: request.query["since"].flatMap { Int($0) } ?? 0))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/fixture",
      category: "control",
      summary: "Load, restart, or step fixture sessions without restarting the server.",
      requestSchema: "schemas/debug/fixture-control.schema.json",
      responseSchema: "schemas/debug/fixture-control.schema.json"
    ) { runtime, request, _ in
      json(runtime.fixtureControl(request.body))
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/capture/status",
      category: "capture",
      summary: "Return whether full capture recording is active."
    ) { runtime, _, _ in
      json(runtime.captureStatus())
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/capture/start",
      category: "capture",
      summary: "Start full capture recording under the artifact directory."
    ) { runtime, request, _ in
      json(runtime.startCapture(request.body))
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/capture/stop",
      category: "capture",
      summary: "Stop full capture recording and return manifest metadata."
    ) { runtime, _, _ in
      json(runtime.stopCapture())
    },
    DebugHTTPRoute(
      method: "POST",
      path: "/debug/capture/snapshot",
      category: "capture",
      summary: "Write a snapshot inside the active capture run."
    ) { runtime, _, _ in
      json(runtime.captureSnapshot())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/cast/recent",
      category: "capture",
      summary:
        "Snapshot the last N seconds of a tab's PTY output as an asciinema v2 cast.",
      queryParameters: ["seconds", "tabId"]
    ) { runtime, request, _ in
      let seconds = Double(request.query["seconds"] ?? "") ?? 10
      let tabId = request.query["tabId"]
      switch runtime.recentCastBytes(seconds: seconds, tabId: tabId) {
      case .success(let data, let resolvedTabId, let chunks, let windowSeconds):
        return HTTPResponse(
          status: 200,
          contentType: "application/x-asciicast",
          extraHeaders: [
            "X-App-Tab: \(resolvedTabId)",
            "X-App-Cast-Chunks: \(chunks)",
            "X-App-Cast-Window-Seconds: \(windowSeconds)",
          ],
          body: data)
      case .failure(let status, let message):
        return json(jsonError(message, status: status))
      }
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/selection",
      category: "state",
      summary: "Return the current terminal selection projection.",
      responseSchema: "schemas/debug/selection.schema.json"
    ) { runtime, _, _ in
      json(runtime.selection())
    },
    DebugHTTPRoute(
      method: "GET",
      path: "/debug/clipboard",
      category: "state",
      summary: "Return debug clipboard copy/paste diagnostics.",
      responseSchema: "schemas/debug/clipboard.schema.json"
    ) { runtime, _, _ in
      json(runtime.clipboard())
    },
  ]

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
      guard let base = ptr.baseAddress else { return }
      var offset = 0
      while offset < ptr.count {
        let n = send(fd, base.advanced(by: offset), ptr.count - offset, 0)
        if n < 0 {
          if errno == EINTR { continue }
          return
        }
        if n == 0 { return }
        offset += n
      }
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

    let request = DebugHTTPRequest(query: query, body: body)
    for route in Self.routes {
      if let match = route.match(method, path) {
        return route.handle(runtime, request, match)
      }
    }
    return Self.json(jsonError("not found", status: 404))
  }

  // MARK: - Helpers

  private static func json(_ r: DebugResponse) -> HTTPResponse {
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
