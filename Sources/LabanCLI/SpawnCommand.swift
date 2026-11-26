import Foundation
import LabanCore

/// `laban new`, `laban split`, and `laban run`: ask the running app to
/// open a terminal (ADR 0024, Amendment 2026-11-26). Inside a Laban session no
/// dialog appears; the server proves the caller runs in that session. The
/// default working directory is the caller's own, so `laban split -- make test`
/// runs where you typed it.
enum SpawnCommand {
  static func requestBody(options: SpawnOptions, currentDirectory: String) -> String {
    let isTab = options.placement == "tab"
    let request = ControlSpawnRequest(
      action: isTab ? "spawnTab" : "spawnSplit",
      argv: options.argv.isEmpty ? nil : options.argv,
      cwd: resolvedDirectory(options.cwd, currentDirectory: currentDirectory),
      label: options.label,
      focus: options.focus,
      direction: isTab ? nil : options.placement)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(request)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  static func resolvedDirectory(_ path: String?, currentDirectory: String) -> String {
    guard let path, !path.isEmpty else { return currentDirectory }
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
    return ((currentDirectory as NSString).appendingPathComponent(expanded) as NSString)
      .standardizingPath
  }

  /// The terminal starts the command with `execve`, which does no PATH search
  /// and resolves a relative path against Laban's directory, not the caller's.
  /// So resolve `argv[0]` here, the way the caller's shell would: a name with
  /// a `/` against `directory`, a bare name on the caller's `PATH`.
  static func resolveExecutable(
    _ name: String, path: String?, directory: String,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> String? {
    if name.contains("/") {
      let full = resolvedDirectory(name, currentDirectory: directory)
      return isExecutable(full) ? full : nil
    }
    for entry in (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") {
      let dir =
        entry.isEmpty
        ? directory : resolvedDirectory(String(entry), currentDirectory: directory)
      let candidate = (dir as NSString).appendingPathComponent(name)
      if isExecutable(candidate) { return candidate }
    }
    return nil
  }

  static func perform(
    options: SpawnOptions,
    agentProxyRequest: AgentProxyRequest,
    lazyAttachRequest: LazyAttachRequestHandler,
    agentProxyURL: String?,
    currentDirectory: String,
    waiter: RunWaiter = RunWaiter(),
    environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) throws -> LabanCLIResult {
    var options = options
    if let name = options.argv.first {
      guard
        let resolved = resolveExecutable(
          name, path: environmentPath,
          directory: resolvedDirectory(options.cwd, currentDirectory: currentDirectory),
          isExecutable: isExecutable)
      else {
        return LabanCLIResult(
          exitCode: 127, stdout: "", stderr: "laban: command not found: \(name)")
      }
      options.argv[0] = resolved
    }
    guard options.wait else {
      return try request(
        options: options, agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest, agentProxyURL: agentProxyURL,
        currentDirectory: currentDirectory)
    }
    let statusDirectory = try waiter.makeStatusDirectory()
    defer { waiter.removeStatusDirectory(statusDirectory) }
    var wrapped = options
    wrapped.argv = RunWaiter.wrappedArgv(options.argv, statusDirectory: statusDirectory)
    // The terminal runs the wrapper shell; name the tab after the real command.
    if wrapped.label == nil, wrapped.placement == "tab", let first = options.argv.first {
      let name = String((first as NSString).lastPathComponent.prefix(64))
      if !ControlSpawnRouting.containsUnsafeScalar(name) { wrapped.label = name }
    }
    wrapped.json = true
    let opened = try request(
      options: wrapped, agentProxyRequest: agentProxyRequest,
      lazyAttachRequest: lazyAttachRequest, agentProxyURL: agentProxyURL,
      currentDirectory: currentDirectory)
    guard opened.exitCode == 0,
      let response = try? JSONDecoder().decode(
        ControlSpawnResponse.self, from: Data(opened.stdout.utf8))
    else { return opened }
    switch waiter.wait(statusDirectory: statusDirectory) {
    case .exited(let status):
      guard options.json else { return LabanCLIResult(exitCode: status, stdout: "", stderr: "") }
      let object: [String: Any] = [
        "exitStatus": Int(status), "ok": true, "placement": response.placement,
        "sessionID": response.sessionID, "tabID": response.tabID,
      ]
      let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      return LabanCLIResult(exitCode: status, stdout: text, stderr: "")
    case .failed(let reason):
      return LabanCLIResult(exitCode: 1, stdout: "", stderr: "laban: \(reason)")
    }
  }

  private static func request(
    options: SpawnOptions,
    agentProxyRequest: AgentProxyRequest,
    lazyAttachRequest: LazyAttachRequestHandler,
    agentProxyURL: String?,
    currentDirectory: String
  ) throws -> LabanCLIResult {
    let body = requestBody(options: options, currentDirectory: currentDirectory)
    let cliCommand = options.placement == "tab" ? "session.spawnTab" : "session.spawnSplit"
    let (status, responseBody): (Int, String)
    if let proxyURL = LabanCLI.agentProxyURLFromEnvironment(override: agentProxyURL) {
      (status, responseBody) = try agentProxyRequest(
        proxyURL, AgentProxyEnvelope(method: "POST", path: "/debug/actions", body: body))
    } else {
      (status, responseBody) = try lazyAttachRequest(
        cliCommand, "POST", "/debug/actions", [:], body)
    }
    return result(status: status, body: responseBody, json: options.json)
  }

  /// Success prints the new session id (so `id=$(laban split -- ...)` works),
  /// or the whole response with `--json`. A refusal names the server's reason.
  static func result(status: Int, body: String, json: Bool) -> LabanCLIResult {
    let data = Data(body.utf8)
    guard (200..<300).contains(status),
      let response = try? JSONDecoder().decode(ControlSpawnResponse.self, from: data)
    else {
      let reason =
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        ?? "server returned \(status)"
      return LabanCLIResult(exitCode: 5, stdout: "", stderr: "laban: \(reason)")
    }
    guard json else {
      return LabanCLIResult(exitCode: 0, stdout: response.sessionID, stderr: "")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = (try? encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? body
    return LabanCLIResult(exitCode: 0, stdout: text, stderr: "")
  }
}
