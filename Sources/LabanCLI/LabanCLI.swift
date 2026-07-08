import Darwin
import Foundation
import LabanControl

struct LabanCLIResult {
  var exitCode: Int32
  var stdout: String
  var stderr: String
}

typealias LabanCLIRequest = (
  _ socketPath: String,
  _ token: String,
  _ method: String,
  _ path: String,
  _ body: Data?
) throws -> (status: Int, body: Data)

enum LabanCLI {
  static func run(
    command: LabanCommand,
    controlDirectory: URL? = nil,
    request: @escaping LabanCLIRequest = liveRequest,
    executablePath: @escaping () -> String = liveExecutablePath
  ) -> LabanCLIResult {
    do {
      return try runThrowing(
        command: command,
        controlDirectory: controlDirectory,
        request: request,
        executablePath: executablePath)
    } catch let error as ControlDiscoveryError {
      return LabanCLIResult(
        exitCode: 3,
        stdout: "",
        stderr: "laban: control plane unavailable: \(redactedDiscoveryError(error))")
    } catch let error as LabanArgumentError {
      return LabanCLIResult(
        exitCode: 2,
        stdout: "",
        stderr: "laban: \(error)")
    } catch let error as LabanCLIError {
      return LabanCLIResult(
        exitCode: 2,
        stdout: "",
        stderr: "laban: \(error)")
    } catch {
      return LabanCLIResult(
        exitCode: 6,
        stdout: "",
        stderr: "laban: error: \(error)")
    }
  }

  /// Formats the result for terminal output. Empty streams stay empty so
  /// errors do not print a blank line to stdout.
  static func formattedOutput(_ outcome: LabanCLIResult) -> (stdout: String, stderr: String) {
    let stdout = outcome.stdout.isEmpty ? "" : outcome.stdout + "\n"
    let stderr = outcome.stderr.isEmpty ? "" : outcome.stderr + "\n"
    return (stdout, stderr)
  }

  // MARK: - Private

  private static func runThrowing(
    command: LabanCommand,
    controlDirectory: URL?,
    request: LabanCLIRequest,
    executablePath: () -> String
  ) throws -> LabanCLIResult {
    switch command {
    case .discover(let json):
      let (record, path) = try readRecord(controlDirectory: controlDirectory)
      let redacted = ControlDiscovery.redacted(record: record, path: path)
      if json {
        let data = try JSONEncoder().encode(redacted)
        let text = String(data: data, encoding: .utf8) ?? ""
        return LabanCLIResult(exitCode: 0, stdout: text, stderr: "")
      }
      let text = """
        Control plane: \(redacted.path)
        URL: \(redacted.url)
        PID: \(redacted.pid)
        Run ID: \(redacted.runId)
        App-observe token: \(redacted.hasAppObserveToken ? "present" : "absent")
        """
      return LabanCLIResult(exitCode: 0, stdout: text, stderr: "")

    case .status(let json):
      return try performReadRequest(
        controlDirectory: controlDirectory,
        request: request,
        method: "GET",
        path: "/debug/state",
        body: nil,
        json: json)

    case .health(let json):
      return try performReadRequest(
        controlDirectory: controlDirectory,
        request: request,
        method: "GET",
        path: "/debug/health",
        body: nil,
        json: json)

    case .capabilities(let json):
      return try performReadRequest(
        controlDirectory: controlDirectory,
        request: request,
        method: "GET",
        path: "/debug/capabilities",
        body: nil,
        json: json)

    case .request(let method, let path, let bodyString, let json):
      let (record, _) = try readRecord(controlDirectory: controlDirectory)
      let body = bodyString.flatMap { Data($0.utf8) }
      let (status, responseBody) = try request(
        record.url, record.token, method, path, body)
      return formatResponse(status: status, body: responseBody, json: json)

    case .completions(let shell):
      let script = try completionsScript(for: shell)
      return LabanCLIResult(exitCode: 0, stdout: script, stderr: "")

    case .installCLI(let prefix, let dryRun):
      let message = try installShim(
        prefix: prefix,
        dryRun: dryRun,
        executablePath: executablePath())
      return LabanCLIResult(exitCode: 0, stdout: message, stderr: "")

    case .help:
      return LabanCLIResult(exitCode: 0, stdout: usageText, stderr: "")
    }
  }

  private static func performReadRequest(
    controlDirectory: URL?,
    request: LabanCLIRequest,
    method: String,
    path: String,
    body: Data?,
    json: Bool
  ) throws -> LabanCLIResult {
    let (record, _) = try readRecord(controlDirectory: controlDirectory)
    let (status, responseBody) = try request(
      record.url, record.token, method, path, body)
    return formatResponse(status: status, body: responseBody, json: json)
  }

  private static func readRecord(
    controlDirectory: URL?
  ) throws -> (ControlAdvertisementRecord, String) {
    let directory = controlDirectory ?? ControlAdvertisement.directory()
    let record = try ControlDiscovery.read(controlDirectory: directory)
    let path = ControlDiscovery.controlFileURL(directory: directory).path
    return (record, path)
  }

  private static func formatResponse(
    status: Int,
    body: Data,
    json: Bool
  ) -> LabanCLIResult {
    let bodyText: String
    if json {
      // Re-encode valid JSON with sorted keys for stable machine output.
      if let obj = try? JSONSerialization.jsonObject(with: body) {
        let data = (try? JSONSerialization.data(
          withJSONObject: obj,
          options: [.sortedKeys])) ?? body
        bodyText = String(data: data, encoding: .utf8) ?? ""
      } else {
        bodyText = String(data: body, encoding: .utf8) ?? ""
      }
    } else {
      bodyText = String(data: body, encoding: .utf8) ?? ""
    }

    let exitCode: Int32 = (200..<300).contains(status) ? 0 : 5
    let stderr = exitCode == 0 ? "" : "laban: server returned \(status)"
    return LabanCLIResult(exitCode: exitCode, stdout: bodyText, stderr: stderr)
  }

  private static func redactedDiscoveryError(_ error: ControlDiscoveryError) -> String {
    // Keep diagnostics actionable but never include file contents.
    switch error {
    case .fileNotFound: return "control.json not found"
    case .notRegularFile: return "control.json is not a regular file"
    case .symlink: return "control.json is a symlink"
    case .wrongOwner: return "control.json is not owned by the current user"
    case .insecurePermissions: return "control.json permissions are insecure"
    case .oversized(let max): return "control.json exceeds \(max) bytes"
    case .malformedJSON: return "control.json is not valid JSON"
    case .missingField(let field): return "control.json missing field: \(field)"
    case .untrustedSocketPath: return "control.json socket path is outside the control directory"
    }
  }

  private static func liveRequest(
    socketPath: String,
    token: String,
    method: String,
    path: String,
    body: Data?
  ) throws -> (status: Int, body: Data) {
    try ControlUDSClient.request(
      socketPath: socketPath,
      method: method,
      path: path,
      token: token,
      body: body)
  }

  private static func liveExecutablePath() -> String {
    // `_NSGetExecutablePath` gives the path the kernel used to launch this
    // process, independent of `argv[0]` or PATH resolution. We then resolve
    // symlinks so shims that point at the real binary report the true path.
    var size = UInt32(0)
    _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else {
      return CommandLine.arguments[0]
    }
    let url = URL(fileURLWithPath: String(cString: path))
    return url.resolvingSymlinksInPath().standardizedFileURL.path
  }
}

let usageText = """
  Usage: laban <command> [options]

  App-observe commands:
    discover [--json]              Show the local control plane advertisement.
    status [--json]                GET /debug/state with the app-observe token.
    health [--json]                GET /debug/health.
    capabilities [--json]          GET /debug/capabilities.
    request METHOD PATH [--body JSON] [--json]
                                   Send a raw app-observe request.
    completions SHELL              Print shell completions (zsh, bash, fish).
    install-cli [--prefix PATH] [--dry-run]
                                   Install a shell shim for laban.

  Global options:
    --json                         Write machine-readable JSON to stdout.
    -h, --help                     Show this help.
"""

enum LabanCLIError: Error, Equatable {
  case unknownShell(String)
}

extension LabanCLIError: CustomStringConvertible {
  var description: String {
    switch self {
    case .unknownShell(let shell):
      return "unknown shell: \(shell)"
    }
  }
}

extension LabanArgumentError: CustomStringConvertible {
  var description: String {
    switch self {
    case .unknownCommand(let command):
      return "unknown command: \(command)"
    case .missingArgument(let argument):
      return "missing argument: \(argument)"
    }
  }
}
