import AppKit
import Darwin
import Dispatch
import Foundation
import LabanCore
import LabanRenderer

/// Loopback HTTP control surface for diagnosing the overlay scroll-indicator bug
/// (`linesBack > 0` while pinned to the live bottom) on a *real headful* window —
/// the one tier the headless `laban-agent` cannot reproduce, because the bug
/// lives in the labpty background-timer byte-ring feed racing the main-thread
/// viewport sample.
///
/// Opt-in only: created from `--scroll-debug[=port]` / `LABAN_SCROLL_DEBUG=1`. It
/// holds weak references to the live `AppModel`, `TerminalBitmapView`, and
/// `TerminalScrollIndicatorView`, hops to the main thread to read/drive them, and
/// exposes:
///
///   GET  /scroll/state              current viewport numbers, view-internal
///                                   scroll belief, window focus, the overlay's
///                                   `decide()` output, and the indicator's real
///                                   on-screen layer opacity.
///   GET  /scroll/trace[?clear=1]    the ScrollDiagnostics event ring (JSON).
///   POST /scroll/trace/clear        clear the ring.
///   POST /scroll/input              write the raw request body to the active
///                                   session (e.g. start a streaming program).
///   POST /scroll/wheel?rows=N       scroll N rows (negative = up into history,
///                                   positive = toward the bottom).
///   POST /scroll/snap-bottom        snap the viewport to the active bottom.
///   GET  /scroll/screenshot.png     PNG of the live render surface.
///
/// Bound to 127.0.0.1 only; no auth (the loopback boundary plus the explicit
/// opt-in flag is the gate, matching the debug-only nature of the surface).
final class ScrollDebugServer {
  struct Config {
    var port: UInt16
    var traceFilePath: String?

    /// Parse `--scroll-debug`, `--scroll-debug=PORT`, or `LABAN_SCROLL_DEBUG`.
    /// `LABAN_SCROLL_DEBUG` accepts `1`/`true` (default port) or a bare port.
    /// Returns nil when the launch did not ask for the surface.
    static func fromLaunchEnvironment() -> Config? {
      let defaultPort: UInt16 = 8787
      var requested = false
      var port = defaultPort

      for arg in CommandLine.arguments {
        if arg == "--scroll-debug" {
          requested = true
        } else if arg.hasPrefix("--scroll-debug=") {
          requested = true
          if let p = UInt16(arg.dropFirst("--scroll-debug=".count)) { port = p }
        }
      }
      if let env = ProcessInfo.processInfo.environment["LABAN_SCROLL_DEBUG"],
        !env.isEmpty, env != "0", env.lowercased() != "false"
      {
        requested = true
        if let p = UInt16(env) { port = p }
      }
      guard requested else { return nil }

      let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Laban/scroll-trace", isDirectory: true)
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let file = dir.appendingPathComponent("scroll-\(stamp).jsonl").path
      return Config(port: port, traceFilePath: file)
    }
  }

  private weak var model: AppModel?
  private weak var termView: TerminalBitmapView?
  private weak var indicator: TerminalScrollIndicatorView?

  private var serverFD: Int32 = -1
  private let connectionQueue = DispatchQueue(
    label: "com.laban.scrolldebug.conn", attributes: .concurrent)

  init(model: AppModel, termView: TerminalBitmapView, indicator: TerminalScrollIndicatorView) {
    self.model = model
    self.termView = termView
    self.indicator = indicator
  }

  func start(config: Config) {
    let path = ScrollDiagnostics.shared.enable(filePath: config.traceFilePath)
    DispatchQueue.main.async { [weak termView] in
      termView?.debugEnableScreenshotReadback()
    }
    do {
      let port = try bind(port: config.port)
      let thread = Thread { self.acceptLoop() }
      thread.name = "scroll-debug-accept"
      thread.start()
      NSLog("[scroll-debug] listening on http://127.0.0.1:\(port)  trace=\(path ?? "(ring only)")")
      FileHandle.standardError.write(
        Data("laban: scroll-debug http://127.0.0.1:\(port) (trace: \(path ?? "ring"))\n".utf8))
    } catch {
      NSLog("[scroll-debug] failed to start: \(error)")
    }
  }

  func stop() {
    let fd = serverFD
    serverFD = -1
    if fd >= 0 { Darwin.close(fd) }
  }

  // MARK: - Socket

  private func bind(port: UInt16) throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ServerError.socketFailed }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(port)
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    let bindResult = withUnsafeBytes(of: &addr) { ptr in
      Darwin.bind(
        fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    guard bindResult == 0 else {
      Darwin.close(fd)
      throw ServerError.bindFailed
    }
    guard listen(fd, 16) == 0 else {
      Darwin.close(fd)
      throw ServerError.listenFailed
    }
    var bound = sockaddr_in()
    var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutableBytes(of: &bound) { ptr in
      getsockname(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &boundLen)
    }
    serverFD = fd
    return CFSwapInt16BigToHost(bound.sin_port)
  }

  private enum ServerError: Error { case socketFailed, bindFailed, listenFailed }

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
        connectionQueue.async { [self] in handleConnection(clientFD) }
        continue
      }
      let err = errno
      if serverFD < 0 || err == EBADF || err == EINVAL { break }
      if err == EINTR || err == ECONNABORTED { continue }
      if err == EMFILE || err == ENFILE {
        usleep(100_000)
        continue
      }
      break
    }
  }

  // MARK: - Connection

  private func handleConnection(_ fd: Int32) {
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var raw = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    var headerEnd = -1
    let deadline = Date().addingTimeInterval(5)
    while raw.count < 64 * 1024 {
      if Date() > deadline { return }
      let n = recv(fd, &buf, buf.count, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return }
      raw.append(contentsOf: buf[0..<n])
      if let range = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
        headerEnd = range.upperBound
        break
      }
    }
    guard headerEnd >= 0,
      let headerStr = String(data: raw[0..<headerEnd], encoding: .utf8)
    else { return }
    let lines = headerStr.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return }
    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else { return }
    let method = parts[0]
    let pathAndQuery = parts[1].components(separatedBy: "?")
    let path = pathAndQuery[0]
    let query = parseQuery(pathAndQuery.count > 1 ? pathAndQuery[1] : "")

    var contentLength = 0
    for line in lines.dropFirst() {
      if line.isEmpty { break }
      if let colon = line.firstIndex(of: ":") {
        let key = line[..<colon].lowercased()
        let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if key == "content-length" { contentLength = max(0, min(Int(val) ?? 0, 1 << 20)) }
      }
    }
    var body = Data(raw[headerEnd...].prefix(contentLength))
    let bodyDeadline = Date().addingTimeInterval(5)
    while body.count < contentLength {
      if Date() > bodyDeadline { break }
      let need = min(contentLength - body.count, 4096)
      var bodyBuf = [UInt8](repeating: 0, count: need)
      let n = recv(fd, &bodyBuf, need, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { break }
      body.append(contentsOf: bodyBuf[0..<n])
    }

    let response = route(method: method, path: path, query: query, body: body)
    send(fd: fd, response)
  }

  private func send(fd: Int32, _ r: Response) {
    var header = "HTTP/1.1 \(r.status) \(Self.statusText(r.status))\r\n"
    header += "Content-Type: \(r.contentType)\r\n"
    header += "Content-Length: \(r.body.count)\r\n"
    header += "Connection: close\r\n\r\n"
    var data = Data(header.utf8)
    data.append(r.body)
    data.withUnsafeBytes { ptr in
      guard let base = ptr.baseAddress else { return }
      var offset = 0
      while offset < ptr.count {
        let n = Darwin.send(fd, base.advanced(by: offset), ptr.count - offset, 0)
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

  private struct Response {
    var status: Int
    var contentType: String
    var body: Data
    static func json(_ object: Any, status: Int = 200) -> Response {
      let data =
        (try? JSONSerialization.data(
          withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
        ?? Data("{}".utf8)
      return Response(status: status, contentType: "application/json", body: data)
    }
    static func text(_ s: String, status: Int = 200) -> Response {
      Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
    }
  }

  private func route(method: String, path: String, query: [String: String], body: Data) -> Response
  {
    switch (method, path) {
    case ("GET", "/"), ("GET", "/scroll"):
      return Response.text(Self.helpText)
    case ("GET", "/scroll/state"):
      return stateResponse(query: query)
    case ("GET", "/scroll/trace"):
      return traceResponse(clear: query["clear"] == "1")
    case ("POST", "/scroll/trace/clear"):
      ScrollDiagnostics.shared.clear()
      return Response.json(["ok": true])
    case ("POST", "/scroll/input"):
      return inputResponse(body: body)
    case ("POST", "/scroll/wheel"):
      let rows = Int(query["rows"] ?? "0") ?? 0
      return onMain { tv, _, _ in
        tv.debugScrollByRows(rows)
        return Response.json(["ok": true, "rows": rows])
      }
    case ("POST", "/scroll/snap-bottom"):
      return onMain { tv, _, _ in
        tv.debugSnapToBottom()
        return Response.json(["ok": true])
      }
    case ("GET", "/scroll/screenshot.png"):
      return screenshotResponse()
    default:
      return Response.json(["error": "not found", "path": path], status: 404)
    }
  }

  // MARK: - Handlers (each hops to main to touch AppKit state)

  private func stateResponse(query: [String: String]) -> Response {
    let hover = (query["hover"] ?? "false").lowercased() == "true"
    return onMain { tv, ind, _ in
      let view = tv.debugScrollSnapshot()
      var payload: [String: Any] = ["view": view.dictionary]
      if view.available {
        let input = TerminalScrollIndicator.Input(
          viewportOffset: view.off, totalRows: view.total, viewportRows: view.vp,
          isHoverEdge: hover, isAltScreen: view.alt, isMouseTracking: view.mouse)
        let output = TerminalScrollIndicator.decide(input)
        payload["decide"] = [
          "shouldHold": output.shouldHold,
          "pillVisible": output.pillVisible,
          "pillText": output.pillText,
          "linesBack": TerminalScrollIndicator.linesBack(input),
        ]
      }
      payload["indicator"] = ind.debugVisibility().dictionary
      return Response.json(payload)
    }
  }

  private func traceResponse(clear: Bool) -> Response {
    let events = ScrollDiagnostics.shared.snapshot()
    if clear { ScrollDiagnostics.shared.clear() }
    let data =
      (try? JSONEncoder().encode(events)).map {
        // Wrap the array in an object so curl pretty-printers see one document.
        var d = Data("{\"count\":\(events.count),\"events\":".utf8)
        d.append($0)
        d.append(Data("}".utf8))
        return d
      } ?? Data("{\"count\":0,\"events\":[]}".utf8)
    return Response(status: 200, contentType: "application/json", body: data)
  }

  private func inputResponse(body: Data) -> Response {
    let bytes = [UInt8](body)
    return onMain { tv, _, _ in
      let wrote = tv.debugWriteInput(bytes)
      return Response.json(["ok": wrote, "bytes": bytes.count])
    }
  }

  private func screenshotResponse() -> Response {
    let png: Data? = onMainValue { tv, _, _ in tv.debugFramePNG() }.flatMap { $0 }
    guard let png else {
      return Response.json(["error": "no frame available"], status: 503)
    }
    return Response(status: 200, contentType: "image/png", body: png)
  }

  // MARK: - Main-thread hop helpers

  private func onMain(
    _ body: @escaping (TerminalBitmapView, TerminalScrollIndicatorView, AppModel) -> Response
  ) -> Response {
    onMainValue { tv, ind, model in body(tv, ind, model) }
      ?? Response.json(["error": "window not available"], status: 503)
  }

  private func onMainValue<T>(
    _ body: @escaping (TerminalBitmapView, TerminalScrollIndicatorView, AppModel) -> T
  ) -> T? {
    var result: T?
    DispatchQueue.main.sync {
      guard let tv = self.termView, let ind = self.indicator, let model = self.model else { return }
      result = body(tv, ind, model)
    }
    return result
  }

  // MARK: - Helpers

  private func parseQuery(_ s: String) -> [String: String] {
    var result: [String: String] = [:]
    guard !s.isEmpty else { return result }
    for pair in s.components(separatedBy: "&") {
      let kv = pair.components(separatedBy: "=")
      if kv.count == 2 {
        result[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
      } else if kv.count == 1 {
        result[kv[0]] = ""
      }
    }
    return result
  }

  private static func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 404: return "Not Found"
    case 503: return "Service Unavailable"
    default: return "Unknown"
    }
  }

  private static let helpText = """
    laban scroll-debug control surface

    GET  /scroll/state[?hover=true]   viewport numbers + view belief + focus + indicator opacity
    GET  /scroll/trace[?clear=1]      ScrollDiagnostics event ring (JSON)
    POST /scroll/trace/clear          clear the ring
    POST /scroll/input                request body bytes -> active session input
    POST /scroll/wheel?rows=N         scroll N rows (negative = up, positive = toward bottom)
    POST /scroll/snap-bottom          pin viewport to the active bottom
    GET  /scroll/screenshot.png       PNG of the live render surface
    """
}
