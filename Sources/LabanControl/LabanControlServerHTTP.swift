import Darwin
import Foundation
import LabanCore

// Request parsing/framing and response helpers for LabanControlServer.
// Split out of LabanControlServer.swift; behavior-preserving code movement.
extension LabanControlServer {
  struct ParsedHeaders {
    var authorization: String?
    var authorizationCount = 0
    var contentLengthHeader: String?
    var connection: String?
  }

  private enum ContentLengthResult {
    case success(Int)
    case failure(status: Int)
  }

  enum ParseResult {
    case ok(IncomingHTTPRequest)
    case badRequest
    case methodNotAllowed
    case payloadTooLarge
    case connectionClosed
  }

  struct IncomingHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: ParsedHeaders
    let body: Data

    var wantsKeepAlive: Bool {
      headers.connection?.lowercased().contains("keep-alive") == true
    }
  }

  func readHTTPRequest(
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

    let isLazyAttach =
      method == "POST" && parsedTarget.path == Self.lazyAttachRequestPath
    let maxBodyBytes =
      isLazyAttach ? Self.maxLazyAttachBodySize : Self.maxBodyBytes

    let contentLength: Int
    switch parseContentLength(headers.contentLengthHeader, method: method, maxBytes: maxBodyBytes) {
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
    method: String,
    maxBytes: Int
  ) -> ContentLengthResult {
    guard let header, !header.isEmpty else {
      return method == "POST" ? .failure(status: 400) : .success(0)
    }
    guard let length = Int(header), length >= 0 else {
      return .failure(status: 400)
    }
    guard length <= maxBytes else {
      return .failure(status: 413)
    }
    return .success(length)
  }

  private static func parseRequestTarget(
    _ rawPath: String
  ) -> (path: String, query: [String: String]) {
    let parts = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let path = parts.first.map(String.init) ?? rawPath
    guard parts.count > 1 else {
      return (path, [:])
    }
    return (path, Self.parseQueryString(String(parts[1])))
  }

  static func parseQueryString(_ queryString: String) -> [String: String] {
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

  func send(_ clientFD: Int32, _ response: ControlResponse, persistSession: Bool) {
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

  func setReceiveTimeout(
    _ clientFD: Int32,
    timeout: TimeInterval = LabanControlServer.requestReadTimeout
  ) {
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(
      clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv,
      socklen_t(MemoryLayout<timeval>.size))
  }

  static func unauthorizedResponse() -> ControlResponse {
    var response = ControlResponse.error(401, "missing or invalid bearer token")
    response.headers["WWW-Authenticate"] = "Bearer"
    return response
  }
}
