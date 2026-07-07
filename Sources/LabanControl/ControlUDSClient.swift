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
    timeout: TimeInterval = 5,
    keepConnectionOpen: Bool = false
  ) throws -> (status: Int, body: Data) {
    let fd = try connect(socketPath: socketPath)
    if keepConnectionOpen {
      return try request(
        fd: fd,
        method: method,
        path: path,
        token: token,
        body: body,
        timeout: timeout,
        keepConnectionOpen: true)
    }
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

    var raw = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) == nil && raw.count < 64 * 1024 {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { break }
      raw.append(contentsOf: buffer[0..<n])
    }

    guard let headerEnd = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))?.upperBound,
      let headerString = String(data: raw[0..<headerEnd], encoding: .utf8),
      let statusLine = headerString.components(separatedBy: "\r\n").first
    else {
      return (-1, Data())
    }

    let parts = statusLine.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else {
      return (-1, Data())
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
      guard n > 0 else { break }
      bodyData.append(contentsOf: buffer[0..<n])
    }

    return (status, bodyData)
  }

  /// Redeems a C14 attach bootstrap and leaves the connection open for session-scoped reads.
  public static func redeemAttachBootstrap(
    socketPath: String,
    bootstrap: String,
    timeout: TimeInterval = 5
  ) throws -> (fd: Int32, sessionID: String) {
    let fd = try connect(socketPath: socketPath)
    let body = Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8)
    let (status, responseBody) = try request(
      fd: fd,
      method: "POST",
      path: LabanControlServer.sessionAttachPath,
      body: body,
      timeout: timeout,
      keepConnectionOpen: true)
    guard status == 200 else {
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

public enum ControlUDSClientError: Error, Equatable {
  case socketFailed
  case pathTooLong
  case attachRedeemFailed(status: Int)
}
