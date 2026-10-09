import Darwin
import Foundation

public enum ControlUDSClient {
  public static func connect(socketPath: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlUDSClientError.socketFailed }
    try ControlFD.setCloseOnExec(fd)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw ControlUDSClientError.pathTooLong
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (index, byte) in pathBytes.enumerated() where index < dest.count {
        dest[index] = UInt8(bitPattern: byte)
      }
    }

    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let error = errno
      Darwin.close(fd)
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(error),
        userInfo: [
          NSLocalizedDescriptionKey:
            "connect failed: \(String(cString: strerror(error)))"
        ])
    }
    return fd
  }

  public static func request(
    socketPath: String,
    method: String = "GET",
    path: String,
    token: String? = nil,
    body: Data? = nil,
    timeout: TimeInterval = 5
  ) throws -> (status: Int, body: Data) {
    let fd = try connect(socketPath: socketPath)
    defer { Darwin.close(fd) }
    return try request(
      fd: fd,
      method: method,
      path: path,
      token: token,
      body: body,
      timeout: timeout,
      keepConnectionOpen: false)
  }

  public static func request(
    fd: Int32,
    method: String = "GET",
    path: String,
    token: String? = nil,
    body: Data? = nil,
    timeout: TimeInterval = 5,
    keepConnectionOpen: Bool = false
  ) throws -> (status: Int, body: Data) {
    var recvTimeout = timeval(
      tv_sec: Int(timeout),
      tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
    setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout,
      socklen_t(MemoryLayout<timeval>.size))

    var request = "\(method) \(path) HTTP/1.1\r\n"
    request += "Host: localhost\r\n"
    if let token {
      request += "Authorization: Bearer \(token)\r\n"
    }
    if let body {
      request += "Content-Type: application/json\r\n"
      request += "Content-Length: \(body.count)\r\n"
    }
    request += keepConnectionOpen ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
    request += "\r\n"

    var payload = Data(request.utf8)
    if let body {
      payload.append(body)
    }
    try sendAll(fd: fd, data: payload)

    // Once a response is lost (EOF, reset, timeout, garbage) the connection's
    // framing is gone: a late response would be read as the answer to the
    // NEXT request. Poison the connection so any reuse fails loudly instead,
    // and throw so the caller can treat the peer as lost (issue #37).
    func lost(_ error: ControlUDSClientError) -> ControlUDSClientError {
      Darwin.shutdown(fd, SHUT_RDWR)
      return error
    }

    let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while raw.range(of: headerTerminator) == nil {
      guard raw.count < 64 * 1024 else { throw lost(.malformedResponse) }
      let n = recv(fd, &buffer, buffer.count, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { throw lost(Self.receiveFailure(n: n, errno: errno)) }
      raw.append(contentsOf: buffer[0..<n])
    }

    guard let headerEnd = raw.range(of: headerTerminator)?.upperBound,
      let headerString = String(data: raw[0..<headerEnd], encoding: .utf8),
      let statusLine = headerString.components(separatedBy: "\r\n").first
    else {
      throw lost(.malformedResponse)
    }

    let parts = statusLine.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else {
      throw lost(.malformedResponse)
    }

    var contentLength = 0
    for line in headerString.components(separatedBy: "\r\n").dropFirst() {
      let lower = line.lowercased()
      guard lower.hasPrefix("content-length:") else { continue }
      let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
      contentLength = Int(value) ?? 0
      break
    }

    var bodyData = Data(raw[headerEnd...].prefix(contentLength))
    while bodyData.count < contentLength {
      let need = min(contentLength - bodyData.count, buffer.count)
      let n = recv(fd, &buffer, need, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { throw lost(Self.receiveFailure(n: n, errno: errno)) }
      bodyData.append(contentsOf: buffer[0..<n])
    }

    return (status, bodyData)
  }

  private static func receiveFailure(n: Int, errno: Int32) -> ControlUDSClientError {
    if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
      return .responseTimedOut
    }
    return .connectionClosedBeforeResponse
  }

  /// Redeems a C14 attach bootstrap and leaves the connection open for session-scoped reads.
  public static func redeemAttachBootstrap(
    socketPath: String,
    bootstrap: String,
    timeout: TimeInterval = 5
  ) throws -> (fd: Int32, sessionID: String) {
    let fd = try connect(socketPath: socketPath)
    let body = Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8)
    let status: Int
    let responseBody: Data
    do {
      (status, responseBody) = try request(
        fd: fd,
        method: "POST",
        path: LabanControlServer.sessionAttachPath,
        body: body,
        timeout: timeout,
        keepConnectionOpen: true)
    } catch {
      Darwin.close(fd)
      throw error
    }
    switch status {
    case 200:
      break
    case 425:
      Darwin.close(fd)
      throw ControlUDSClientError.attachTooEarly
    default:
      Darwin.close(fd)
      throw ControlUDSClientError.attachRedeemFailed(status: status)
    }
    let json = try JSONSerialization.jsonObject(with: responseBody) as! [String: Any]
    guard json["ok"] as? Bool == true,
      let sessionID = json["sessionID"] as? String,
      !sessionID.isEmpty
    else {
      Darwin.close(fd)
      throw ControlUDSClientError.attachRedeemFailed(status: status)
    }
    return (fd, sessionID)
  }

  private static func sendAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var sent = 0
      while sent < rawBuffer.count {
        let n = Darwin.send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else {
          throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "send failed"])
        }
        sent += n
      }
    }
  }
}

public enum ControlUDSClientError: Error, Equatable, CustomStringConvertible, LocalizedError {
  case socketFailed
  case pathTooLong
  case attachRedeemFailed(status: Int)
  case attachTooEarly
  /// The peer closed or reset the connection before a complete HTTP response
  /// arrived.
  case connectionClosedBeforeResponse
  /// The receive timeout expired before a complete HTTP response arrived.
  case responseTimedOut
  /// The peer sent bytes that do not parse as an HTTP response.
  case malformedResponse

  public var description: String {
    switch self {
    case .connectionClosedBeforeResponse:
      return "the Laban control connection closed before a response arrived"
    case .responseTimedOut:
      return "the Laban control request timed out before a response arrived"
    case .malformedResponse:
      return "the Laban control connection returned a malformed response"
    case .socketFailed:
      return "failed to open the Laban control socket"
    case .pathTooLong:
      return "the Laban control socket path is too long"
    case .attachRedeemFailed(status: 401):
      return """
        direct session attach was rejected by Laban (HTTP 401). The bootstrap is \
        probably stale or this helper was launched from an already-running \
        agent/tool subprocess. For one-off session commands, use `laban session \
        ...` so lazy attach can ask for approval. For long-lived control, start \
        a fresh agent from the Laban tab shell with `laban agent run -- <agent>` \
        before launching the agent.
        """
    case .attachRedeemFailed(let status):
      return "direct session attach was rejected by Laban (HTTP \(status))"
    case .attachTooEarly:
      return "direct session attach is waiting for the shell to finish registering"
    }
  }

  public var errorDescription: String? {
    description
  }
}
