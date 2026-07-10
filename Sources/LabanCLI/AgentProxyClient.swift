import Darwin
import Foundation
import LabanControl

/// JSONL envelope sent to the `laban-agent` session proxy.
struct AgentProxyEnvelope: Encodable {
  var method: String?
  var path: String
  var body: String?
}

/// JSONL response received from the `laban-agent` session proxy.
struct AgentProxyResponse: Decodable {
  var path: String
  var status: Int
  var body: String
}

enum AgentProxyClientError: Error, Equatable, CustomStringConvertible {
  case missingAgentControlURL
  case connectionFailed(Int32)
  case sendFailed
  case responseTooLarge
  case invalidResponse

  var description: String {
    switch self {
    case .missingAgentControlURL:
      return "LABAN_AGENT_CONTROL_URL is not set; try `laban agent run -- <command>`"
    case .connectionFailed(let code):
      return "proxy connection failed (errno \(code))"
    case .sendFailed:
      return "proxy send failed"
    case .responseTooLarge:
      return "proxy response too large"
    case .invalidResponse:
      return "proxy returned invalid JSONL"
    }
  }
}

enum AgentProxyClient {
  static let maxResponseBytes = 16 * 1024 * 1024

  /// Sends a single request to the proxy and returns the parsed response.
  static func send(
    proxyURL: String,
    request: AgentProxyEnvelope
  ) throws -> AgentProxyResponse {
    let fd = try connect(proxyURL: proxyURL)
    defer { Darwin.close(fd) }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(request)
    let line = payload + Data([0x0A])
    try sendAll(fd: fd, data: line)

    guard let raw = try readLine(fd: fd, maxBytes: maxResponseBytes) else {
      throw AgentProxyClientError.invalidResponse
    }
    return try JSONDecoder().decode(AgentProxyResponse.self, from: raw)
  }

  /// Reads JSONL from stdin, forwards each line to the proxy, and writes JSONL
  /// responses to stdout. Stops at EOF or transport failure.
  static func proxyStdio(proxyURL: String) throws {
    let fd = try connect(proxyURL: proxyURL)
    defer { Darwin.close(fd) }

    while let line = Swift.readLine(strippingNewline: false) {
      let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      try sendAll(fd: fd, data: Data((trimmed + "\n").utf8))
      guard let raw = try readLine(fd: fd, maxBytes: maxResponseBytes) else {
        throw AgentProxyClientError.invalidResponse
      }
      guard let text = String(data: raw, encoding: .utf8) else {
        throw AgentProxyClientError.invalidResponse
      }
      print(text)
      fflush(stdout)
    }
  }

  // MARK: - Request builders

  static func stateRequest() -> AgentProxyEnvelope {
    AgentProxyEnvelope(method: "GET", path: "/debug/state", body: nil)
  }

  static func sessionDetailRequest(sessionID: String) -> AgentProxyEnvelope {
    AgentProxyEnvelope(method: "GET", path: "/debug/sessions/\(sessionID)", body: nil)
  }

  static func shellIntegrationStateRequest() -> AgentProxyEnvelope {
    AgentProxyEnvelope(method: "GET", path: "/debug/shell-integration/state", body: nil)
  }

  static func getTextRequest(
    source: String,
    startLine: Int? = nil,
    endLine: Int? = nil,
    maxLines: Int? = nil
  ) -> AgentProxyEnvelope {
    var query: [String] = ["source=\(source)"]
    if let startLine { query.append("startLine=\(startLine)") }
    if let endLine { query.append("endLine=\(endLine)") }
    if let maxLines { query.append("maxLines=\(maxLines)") }
    let path = "/debug/text?" + query.joined(separator: "&")
    return AgentProxyEnvelope(method: "GET", path: path, body: nil)
  }

  static func scrollRequest(rows: Int) -> AgentProxyEnvelope {
    let body = #"{"action":"scrollViewport","deltaRows":\#(rows)}"#
    return AgentProxyEnvelope(method: "POST", path: "/debug/actions", body: body)
  }

  static func proposeRequest(purpose: String, command: [String]) -> AgentProxyEnvelope {
    let displayCommand: String
    if command.count == 1 {
      displayCommand = command[0]
    } else {
      displayCommand = command.map(shellEscapeIfNeeded).joined(separator: " ")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // Encode the action body as JSON so the proxy can forward it verbatim.
    let bodyDict: [String: Any] = [
      "action": "propose",
      "command": displayCommand,
      "purpose": purpose,
    ]
    let bodyData = try! JSONSerialization.data(withJSONObject: bodyDict, options: [.sortedKeys])
    let body = String(data: bodyData, encoding: .utf8)!
    return AgentProxyEnvelope(method: "POST", path: "/debug/actions", body: body)
  }

  // MARK: - Private

  /// Quotes a string only when it contains characters that would change shape
  /// in a POSIX shell word. Safe words are emitted verbatim so ordinary
  /// command sequences like `git status --short` stay readable.
  private static func shellEscapeIfNeeded(_ string: String) -> String {
    let safe = CharacterSet.alphanumerics
      .union(CharacterSet(charactersIn: "_/-=+.,:@%"))
    if string.rangeOfCharacter(from: safe.inverted) == nil {
      return string
    }
    return shellSingleQuote(string)
  }

  private static func connect(proxyURL: String) throws -> Int32 {
    do {
      let fd = try ControlUDSClient.connect(socketPath: proxyURL)
      try ControlFD.setNoSigPipe(fd)
      return fd
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
      throw AgentProxyClientError.connectionFailed(Int32(error.code))
    } catch {
      throw AgentProxyClientError.connectionFailed(0)
    }
  }

  private static func sendAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else {
          throw AgentProxyClientError.sendFailed
        }
        sent += n
      }
    }
  }

  private static func readLine(fd: Int32, maxBytes: Int) throws -> Data? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    var data = Data()

    while data.count < maxBytes {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if n == 0 { return nil }
      data.append(contentsOf: buffer[0..<n])
      if let newline = data.firstIndex(of: 0x0A) {
        return data[..<newline]
      }
    }
    throw AgentProxyClientError.responseTooLarge
  }
}
