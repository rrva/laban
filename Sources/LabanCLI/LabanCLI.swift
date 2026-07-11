import Darwin
import Foundation
import LabanControl
import LabanCore

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

typealias AgentProxyRequest = (
  _ proxyURL: String,
  _ envelope: AgentProxyEnvelope
) throws -> (status: Int, body: String)

typealias LazyAttachRequestHandler = (
  _ cliCommand: String,
  _ method: String,
  _ path: String,
  _ query: [String: String],
  _ body: String?
) throws -> (status: Int, body: String)

/// Injectable wall clock for `wait` commands' bounded polling loop, so tests
/// can drive a fake clock instead of sleeping in real time.
typealias WaitClock = () -> Date

/// Injectable sleep for `wait` commands' bounded polling loop.
typealias WaitSleep = (TimeInterval) -> Void

enum LabanCLI {
  static func run(
    command: LabanCommand,
    controlDirectory: URL? = nil,
    request: @escaping LabanCLIRequest = liveRequest,
    agentProxyRequest: @escaping AgentProxyRequest = liveAgentProxyRequest,
    lazyAttachRequest: @escaping LazyAttachRequestHandler = LazyAttachClient.perform,
    agentProxyURL: String? = nil,
    executablePath: @escaping () -> String = liveExecutablePath,
    now: @escaping WaitClock = Date.init,
    sleep: @escaping WaitSleep = { Thread.sleep(forTimeInterval: $0) }
  ) -> LabanCLIResult {
    do {
      return try runThrowing(
        command: command,
        controlDirectory: controlDirectory,
        request: request,
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        executablePath: executablePath,
        now: now,
        sleep: sleep)
    } catch let error as ControlDiscoveryError {
      return LabanCLIResult(
        exitCode: 3,
        stdout: "",
        stderr: "laban: control plane unavailable: \(redactedDiscoveryError(error))")
    } catch LabanCLIError.agentControlUnavailable {
      return LabanCLIResult(
        exitCode: 3,
        stdout: "",
        stderr: "laban: \(LabanCLIError.agentControlUnavailable)")
    } catch LabanCLIError.sessionProxyRequiresBroker {
      return LabanCLIResult(
        exitCode: 3,
        stdout: "",
        stderr: "laban: \(LabanCLIError.sessionProxyRequiresBroker)")
    } catch let error as LazyAttachClientError {
      return LabanCLIResult(
        exitCode: lazyAttachExitCode(error),
        stdout: "",
        stderr: "laban: \(error)")
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
    agentProxyRequest: AgentProxyRequest,
    lazyAttachRequest: LazyAttachRequestHandler,
    agentProxyURL: String?,
    executablePath: () -> String,
    now: WaitClock,
    sleep: WaitSleep
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

    case .agentRun(let command):
      AgentLauncher.invoke(command: command)

    case .sessionState(let json):
      return try performSessionRequest(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        cliCommand: "session.state",
        method: "GET",
        path: "/debug/state",
        query: [:],
        body: nil,
        json: json)

    case .sessionRequest(let method, let path, let body, let json):
      return try performSessionRequest(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        cliCommand: "session.request",
        method: method,
        path: path,
        query: [:],
        body: body,
        json: json)

    case .sessionScroll(let rows, let json):
      return try performSessionRequest(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        cliCommand: "session.scroll",
        method: "POST",
        path: "/debug/actions",
        query: ["rows": String(rows)],
        body: AgentProxyClient.scrollRequest(rows: rows).body,
        json: json)

    case .sessionProxy:
      guard let proxyURL = agentProxyURLFromEnvironment(override: agentProxyURL) else {
        throw LabanCLIError.sessionProxyRequiresBroker
      }
      try AgentProxyClient.proxyStdio(proxyURL: proxyURL)
      return LabanCLIResult(exitCode: 0, stdout: "", stderr: "")

    case .sessionCurrent(let json):
      switch try resolveBoundSessionDetail(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        json: json)
      {
      case .success(let resolved):
        return formatJSONObject(resolved.detail)
      case .failure(let result):
        return result
      }

    case .sessionGetText(let source, let startLine, let endLine, let maxLines, let json):
      let (status, body) = try dispatchSessionLeg(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        cliCommand: "terminal.getText",
        envelope: AgentProxyClient.getTextRequest(
          source: source, startLine: startLine, endLine: endLine, maxLines: maxLines))
      return formatProxyResponse(status: status, body: body, json: json)

    case .sessionScreenshot(let outputPath, let json):
      let (status, body) = try dispatchSessionLeg(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        cliCommand: "window.screenshot",
        envelope: AgentProxyEnvelope(
          method: "GET", path: "/debug/window-screenshot", body: nil))
      guard (200..<300).contains(status) else {
        return formatProxyResponse(status: status, body: body, json: json)
      }
      guard let data = body.data(using: .utf8),
        let response = try? JSONDecoder().decode(WindowScreenshotResponse.self, from: data),
        response.ok,
        let pngData = Data(base64Encoded: response.pngBase64),
        pngData.count == response.byteCount,
        pngData.count <= 10 * 1024 * 1024,
        [UInt8](pngData.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      else {
        throw LabanCLIError.invalidWindowScreenshot
      }
      let outputURL = try writeWindowScreenshot(pngData, outputPath: outputPath)
      if json {
        return formatJSONObject([
          "ok": true,
          "path": outputURL.path,
          "width": response.width,
          "height": response.height,
          "byteCount": response.byteCount,
          "includesDialogs": response.includesDialogs,
        ])
      }
      return LabanCLIResult(exitCode: 0, stdout: outputURL.path, stderr: "")

    case .context(let json, let maxLines):
      switch try resolveBoundSessionDetail(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        json: json)
      {
      case .failure(let result):
        return result
      case .success(let resolved):
        let (textStatus, textBody) = try dispatchSessionLeg(
          agentProxyRequest: agentProxyRequest,
          lazyAttachRequest: lazyAttachRequest,
          agentProxyURL: agentProxyURL,
          cliCommand: "terminal.getText",
          envelope: AgentProxyClient.getTextRequest(source: "scrollback", maxLines: maxLines))
        guard (200..<300).contains(textStatus) else {
          return formatProxyResponse(status: textStatus, body: textBody, json: json)
        }
        guard let textObject = jsonObject(from: textBody) else {
          return LabanCLIResult(
            exitCode: 6, stdout: "", stderr: "laban: malformed terminal.getText response")
        }
        let bundle: [String: Any] = [
          "ok": true,
          "sessionId": resolved.sessionId,
          "shellIntegration": [
            "phase": resolved.phase,
            "lastExitCode": resolved.lastExitCode.map { $0 as Any } ?? NSNull(),
          ],
          "session": resolved.detail,
          "recentText": textObject,
        ]
        return formatJSONObject(bundle)
      }

    case .waitPrompt(let timeoutSeconds, let json):
      switch try pollShellIntegrationState(
        agentProxyRequest: agentProxyRequest,
        agentProxyURL: agentProxyURL,
        json: json,
        timeoutSeconds: timeoutSeconds,
        now: now,
        sleep: sleep,
        until: { $0.phase == "atPrompt" })
      {
      case .failure(let result):
        return result
      case .timeout:
        return LabanCLIResult(
          exitCode: 4, stdout: "",
          stderr: "laban: timed out after \(timeoutSeconds)s waiting for prompt")
      case .success(let poll):
        return formatJSONObject(["ok": true, "phase": poll.phase])
      }

    case .waitCommandFinished(let timeoutSeconds, let json):
      let proxyURL = try requireAgentControlURL(override: agentProxyURL)
      let (initialStatus, initialBody) = try agentProxyRequest(
        proxyURL, AgentProxyClient.shellIntegrationStateRequest())
      guard (200..<300).contains(initialStatus) else {
        return formatProxyResponse(status: initialStatus, body: initialBody, json: json)
      }
      guard let initialObject = jsonObject(from: initialBody),
        let baseline = initialObject["completedCommandCount"] as? Int
      else {
        return LabanCLIResult(
          exitCode: 6, stdout: "", stderr: "laban: malformed shellIntegration.state response")
      }
      switch try pollShellIntegrationState(
        agentProxyRequest: agentProxyRequest,
        agentProxyURL: agentProxyURL,
        json: json,
        timeoutSeconds: timeoutSeconds,
        now: now,
        sleep: sleep,
        until: { $0.completedCommandCount > baseline })
      {
      case .failure(let result):
        return result
      case .timeout:
        return LabanCLIResult(
          exitCode: 4, stdout: "",
          stderr: "laban: timed out after \(timeoutSeconds)s waiting for command to finish")
      case .success(let poll):
        return formatJSONObject([
          "ok": true,
          "completedCommandCount": poll.completedCommandCount,
          "lastExitCode": poll.lastExitCode.map { $0 as Any } ?? NSNull(),
        ])
      }

    case .propose(let purpose, let command):
      return try performSessionRequest(
        agentProxyRequest: agentProxyRequest,
        lazyAttachRequest: lazyAttachRequest,
        agentProxyURL: agentProxyURL,
        cliCommand: "command.propose",
        method: "POST",
        path: "/debug/actions",
        query: [:],
        body: AgentProxyClient.proposeRequest(purpose: purpose, command: command).body,
        json: true)

    case .proposalList(let json):
      return try performAgentProxyRequest(
        agentProxyRequest: agentProxyRequest,
        agentProxyURL: agentProxyURL,
        envelope: AgentProxyClient.proposalListRequest(),
        json: json)

    case .proposalStatus(let id, let json):
      return try performAgentProxyRequest(
        agentProxyRequest: agentProxyRequest,
        agentProxyURL: agentProxyURL,
        envelope: AgentProxyClient.proposalGetRequest(proposalID: id),
        json: json)

    case .proposalCancel(let id, let json):
      return try performAgentProxyRequest(
        agentProxyRequest: agentProxyRequest,
        agentProxyURL: agentProxyURL,
        envelope: AgentProxyClient.proposalCancelRequest(proposalID: id),
        json: json)

    case .waitProposal(let id, let state, let timeoutSeconds, let json):
      return try waitForProposalState(
        agentProxyRequest: agentProxyRequest,
        agentProxyURL: agentProxyURL,
        proposalID: id,
        targetState: state,
        timeoutSeconds: timeoutSeconds,
        now: now,
        sleep: sleep,
        json: json)

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
        let data =
          (try? JSONSerialization.data(
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

  private static func requireAgentControlURL(override: String?) throws -> String {
    if let override, !override.isEmpty { return override }
    guard let url = ProcessInfo.processInfo.environment[ControlEnvironmentKeys.agentControlURL],
      !url.isEmpty
    else {
      throw LabanCLIError.agentControlUnavailable
    }
    return url
  }

  private static func lazyAttachExitCode(_ error: LazyAttachClientError) -> Int32 {
    switch error {
    case .controlPlaneUnavailable:
      return 3
    case .timeout:
      return 4
    case .denied, .sessionChanged, .rateLimited:
      return 5
    case .malformedResponse:
      return 6
    }
  }

  private static func performSessionRequest(
    agentProxyRequest: AgentProxyRequest,
    lazyAttachRequest: LazyAttachRequestHandler,
    agentProxyURL: String?,
    cliCommand: String,
    method: String,
    path: String,
    query: [String: String],
    body: String?,
    json: Bool
  ) throws -> LabanCLIResult {
    if let proxyURL = agentProxyURLFromEnvironment(override: agentProxyURL) {
      let envelope = AgentProxyEnvelope(method: method, path: path, body: body)
      let (status, responseBody) = try agentProxyRequest(proxyURL, envelope)
      return formatProxyResponse(status: status, body: responseBody, json: json)
    }
    let (status, responseBody) = try lazyAttachRequest(
      cliCommand,
      method,
      path,
      query,
      body)
    return formatResponse(status: status, body: Data(responseBody.utf8), json: json)
  }

  private static func agentProxyURLFromEnvironment(override: String?) -> String? {
    if let override, !override.isEmpty { return override }
    guard let url = ProcessInfo.processInfo.environment[ControlEnvironmentKeys.agentControlURL],
      !url.isEmpty
    else {
      return nil
    }
    return url
  }

  private static func performAgentProxyRequest(
    agentProxyRequest: AgentProxyRequest,
    agentProxyURL: String?,
    envelope: AgentProxyEnvelope,
    json: Bool
  ) throws -> LabanCLIResult {
    let proxyURL = try requireAgentControlURL(override: agentProxyURL)
    let (status, body) = try agentProxyRequest(proxyURL, envelope)
    return formatProxyResponse(status: status, body: body, json: json)
  }

  /// Dispatches one session-observe leg through the broker when
  /// `LABAN_AGENT_CONTROL_URL` is present, otherwise through lazy attach. This
  /// is the single per-leg dispatch point `session get-text`, `session
  /// current`, and `context` share, so the broker branch always sends
  /// `envelope` unchanged (byte-identical to the pre-Milestone-3 broker-only
  /// path) and the lazy branch is chosen uniformly rather than reimplemented
  /// per call site. `cliCommand` must name a `ControlLazyAttachAllowlist`
  /// (own-session read family) entry; the server enforces membership
  /// independently, this is just the client-side label.
  private static func dispatchSessionLeg(
    agentProxyRequest: AgentProxyRequest,
    lazyAttachRequest: LazyAttachRequestHandler,
    agentProxyURL: String?,
    cliCommand: String,
    envelope: AgentProxyEnvelope
  ) throws -> (status: Int, body: String) {
    if let proxyURL = agentProxyURLFromEnvironment(override: agentProxyURL) {
      return try agentProxyRequest(proxyURL, envelope)
    }
    let (legPath, legQuery) = splitPathAndQuery(envelope.path)
    return try lazyAttachRequest(
      cliCommand, envelope.method ?? "GET", legPath, legQuery, envelope.body)
  }

  /// Splits a broker-style path (query baked in, e.g.
  /// `"/debug/text?source=scrollback&maxLines=40"`) into a clean path and a
  /// query dict, because `ControlRouteCatalog.match` splits on `"/"` and
  /// requires an exact segment match: a `"?"` left in the lazy leg's path
  /// would never match a route. Not `private`: unit-tested directly from
  /// `LazyAttachCLITests` (deviation from the brief, which specified
  /// `private`; kept internal, matching the existing `formattedOutput`
  /// precedent, so tests can call it without a same-file restriction).
  /// Splits on the first `"?"`; pairs split on `"&"` then the first `"="`; a
  /// pair with no `"="` maps to an empty-string value. Total: never throws or
  /// traps on malformed input.
  static func splitPathAndQuery(_ fullPath: String) -> (String, [String: String]) {
    guard let questionIndex = fullPath.firstIndex(of: "?") else {
      return (fullPath, [:])
    }
    let path = String(fullPath[fullPath.startIndex..<questionIndex])
    let queryString = fullPath[fullPath.index(after: questionIndex)...]
    guard !queryString.isEmpty else {
      return (path, [:])
    }
    var query: [String: String] = [:]
    for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
      if let equalsIndex = pair.firstIndex(of: "=") {
        let key = String(pair[pair.startIndex..<equalsIndex])
        let value = String(pair[pair.index(after: equalsIndex)...])
        query[key] = value
      } else {
        query[String(pair)] = ""
      }
    }
    return (path, query)
  }

  /// Resolved identity for `session current` and `context`.
  private struct BoundSessionDetail {
    var sessionId: String
    var phase: String
    var lastExitCode: Int?
    var detail: [String: Any]
  }

  private enum BoundSessionDetailOutcome {
    case success(BoundSessionDetail)
    case failure(LabanCLIResult)
  }

  /// Resolves the bound session's identity for `session current` and
  /// `context`: `shellIntegration.state` (no `sessionId` query) reports the
  /// caller's own scoped session, then `session.detail` fetches its full
  /// metadata. Each leg dispatches through `dispatchSessionLeg`: broker when
  /// `LABAN_AGENT_CONTROL_URL` is set, otherwise lazy attach (Milestone 3;
  /// this used to require the broker and throw `.agentControlUnavailable`
  /// with no session set). With no broker, each leg is an independent lazy
  /// dispatch: under "Allow Once" the user sees one dialog per leg, under
  /// "Always Allow" the first leg persists the family record and the second
  /// leg auto-approves silently. This is the accepted per-leg behavior, not a
  /// bug to "fix" with batching or a pre-warmed grant. Returns a formatted
  /// `LabanCLIResult` failure for a non-2xx or malformed leg so callers do not
  /// need their own status-code plumbing.
  private static func resolveBoundSessionDetail(
    agentProxyRequest: AgentProxyRequest,
    lazyAttachRequest: LazyAttachRequestHandler,
    agentProxyURL: String?,
    json: Bool
  ) throws -> BoundSessionDetailOutcome {
    let (shellStatus, shellBody) = try dispatchSessionLeg(
      agentProxyRequest: agentProxyRequest,
      lazyAttachRequest: lazyAttachRequest,
      agentProxyURL: agentProxyURL,
      cliCommand: "shellIntegration.state",
      envelope: AgentProxyClient.shellIntegrationStateRequest())
    guard (200..<300).contains(shellStatus) else {
      return .failure(formatProxyResponse(status: shellStatus, body: shellBody, json: json))
    }
    guard let shellObject = jsonObject(from: shellBody),
      let sessionId = shellObject["sessionId"] as? String
    else {
      return .failure(
        LabanCLIResult(
          exitCode: 6, stdout: "", stderr: "laban: malformed shellIntegration.state response"))
    }
    let phase = shellObject["phase"] as? String ?? "unknown"
    let lastExitCode = shellObject["lastExitCode"] as? Int

    let (detailStatus, detailBody) = try dispatchSessionLeg(
      agentProxyRequest: agentProxyRequest,
      lazyAttachRequest: lazyAttachRequest,
      agentProxyURL: agentProxyURL,
      cliCommand: "session.detail",
      envelope: AgentProxyClient.sessionDetailRequest(sessionID: sessionId))
    guard (200..<300).contains(detailStatus) else {
      return .failure(formatProxyResponse(status: detailStatus, body: detailBody, json: json))
    }
    guard let detailObject = jsonObject(from: detailBody) else {
      return .failure(
        LabanCLIResult(exitCode: 6, stdout: "", stderr: "laban: malformed session.detail response"))
    }

    return .success(
      BoundSessionDetail(
        sessionId: sessionId,
        phase: phase,
        lastExitCode: lastExitCode,
        detail: redactingTokenLikeKeys(detailObject) as? [String: Any] ?? detailObject))
  }

  /// One decoded `shellIntegration.state` poll observed by `wait prompt` and
  /// `wait command-finished`.
  private struct ShellIntegrationPoll {
    var phase: String
    var lastExitCode: Int?
    var completedCommandCount: Int
  }

  private enum ShellIntegrationPollOutcome {
    case success(ShellIntegrationPoll)
    case timeout
    case failure(LabanCLIResult)
  }

  /// Bounded polling loop shared by `wait prompt` and `wait command-finished`:
  /// polls `shellIntegration.state` on the bound session every 200ms until
  /// `until` is satisfied or `timeoutSeconds` elapses. Broker-only; throws
  /// `.agentControlUnavailable` (exit 3) when `LABAN_AGENT_CONTROL_URL` is
  /// unset. No new wire primitive: each poll is an ordinary bounded request
  /// that interleaves with other proxy traffic, per the Milestone 2c decision
  /// to avoid holding the single C14 upstream connection open indefinitely.
  private static func pollShellIntegrationState(
    agentProxyRequest: AgentProxyRequest,
    agentProxyURL: String?,
    json: Bool,
    timeoutSeconds: Double,
    now: WaitClock,
    sleep: WaitSleep,
    until isSatisfied: (ShellIntegrationPoll) -> Bool
  ) throws -> ShellIntegrationPollOutcome {
    let proxyURL = try requireAgentControlURL(override: agentProxyURL)
    let pollInterval: TimeInterval = 0.2
    let deadline = now().addingTimeInterval(timeoutSeconds)

    while true {
      let (status, body) = try agentProxyRequest(
        proxyURL, AgentProxyClient.shellIntegrationStateRequest())
      guard (200..<300).contains(status) else {
        return .failure(formatProxyResponse(status: status, body: body, json: json))
      }
      guard let object = jsonObject(from: body),
        let phase = object["phase"] as? String,
        let completedCommandCount = object["completedCommandCount"] as? Int
      else {
        return .failure(
          LabanCLIResult(
            exitCode: 6, stdout: "", stderr: "laban: malformed shellIntegration.state response"))
      }
      let poll = ShellIntegrationPoll(
        phase: phase,
        lastExitCode: object["lastExitCode"] as? Int,
        completedCommandCount: completedCommandCount)
      if isSatisfied(poll) {
        return .success(poll)
      }
      if now() >= deadline {
        return .timeout
      }
      sleep(pollInterval)
    }
  }

  /// Broker-side bounded polling of `commandProposal.get` until the proposal
  /// reaches `targetState`, mirroring the shell-integration waits: each poll is
  /// a short request that interleaves with other proxy traffic rather than
  /// holding the single C14 upstream open.
  private static func waitForProposalState(
    agentProxyRequest: AgentProxyRequest,
    agentProxyURL: String?,
    proposalID: String,
    targetState: String,
    timeoutSeconds: Double,
    now: WaitClock,
    sleep: WaitSleep,
    json: Bool
  ) throws -> LabanCLIResult {
    let proxyURL = try requireAgentControlURL(override: agentProxyURL)
    let pollInterval: TimeInterval = 0.2
    let deadline = now().addingTimeInterval(timeoutSeconds)

    while true {
      let (status, body) = try agentProxyRequest(
        proxyURL, AgentProxyClient.proposalGetRequest(proposalID: proposalID))
      guard (200..<300).contains(status) else {
        return formatProxyResponse(status: status, body: body, json: json)
      }
      guard let object = jsonObject(from: body),
        let state = object["state"] as? String
      else {
        return LabanCLIResult(
          exitCode: 6, stdout: "", stderr: "laban: malformed commandProposal.get response")
      }
      if state == targetState {
        return formatJSONObject(["ok": true, "proposalID": proposalID, "state": state])
      }
      if now() >= deadline {
        return LabanCLIResult(
          exitCode: 4, stdout: "",
          stderr:
            "laban: timed out after \(timeoutSeconds)s waiting for proposal state \(targetState)")
      }
      sleep(pollInterval)
    }
  }

  private static func jsonObject(from text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// Recursively strips any key whose name contains "token" (case-insensitive)
  /// from a decoded JSON value. `session current` and `context` forward
  /// `session.detail` into their output verbatim; today's `SessionResponse`
  /// carries no credential field, but this is defense-in-depth so a future
  /// field addition on that response cannot silently start leaking a token
  /// through these broker-only commands.
  private static func redactingTokenLikeKeys(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
      var result: [String: Any] = [:]
      for (key, nested) in dict where !key.lowercased().contains("token") {
        result[key] = redactingTokenLikeKeys(nested)
      }
      return result
    }
    if let array = value as? [Any] {
      return array.map(redactingTokenLikeKeys)
    }
    return value
  }

  /// Serializes a composed (CLI-side) JSON object with sorted keys. Used by
  /// `session current` and `context`, whose output has no raw-passthrough
  /// form to fall back to (unlike `formatResponse`/`formatProxyResponse`,
  /// which forward a single server response body verbatim).
  private static func formatJSONObject(_ object: [String: Any]) -> LabanCLIResult {
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else {
      return LabanCLIResult(exitCode: 6, stdout: "", stderr: "laban: failed to encode response")
    }
    return LabanCLIResult(exitCode: 0, stdout: text, stderr: "")
  }

  private static func formatProxyResponse(
    status: Int,
    body: String,
    json: Bool
  ) -> LabanCLIResult {
    let bodyText: String
    if json {
      if let data = body.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data)
      {
        let data =
          (try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys])) ?? data
        bodyText = String(data: data, encoding: .utf8) ?? body
      } else {
        bodyText = body
      }
    } else {
      bodyText = body
    }

    let exitCode: Int32 = (200..<300).contains(status) ? 0 : 5
    let stderr = exitCode == 0 ? "" : "laban: server returned \(status)"
    return LabanCLIResult(exitCode: exitCode, stdout: bodyText, stderr: stderr)
  }

  private static func writeWindowScreenshot(
    _ data: Data,
    outputPath: String?
  ) throws -> URL {
    let outputURL: URL
    if let outputPath, !outputPath.isEmpty {
      let expanded = NSString(string: outputPath).expandingTildeInPath
      if expanded.hasPrefix("/") {
        outputURL = URL(fileURLWithPath: expanded).standardizedFileURL
      } else {
        outputURL =
          URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
          )
          .appendingPathComponent(expanded)
          .standardizedFileURL
      }
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } else {
      outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("laban-window-\(UUID().uuidString).png")
    }

    if (try? FileManager.default.destinationOfSymbolicLink(atPath: outputURL.path)) != nil {
      throw LabanCLIError.unsafeScreenshotOutput
    }
    try data.write(to: outputURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: outputURL.path)
    return outputURL
  }

  private static func liveAgentProxyRequest(
    proxyURL: String,
    envelope: AgentProxyEnvelope
  ) throws -> (status: Int, body: String) {
    let response = try AgentProxyClient.send(proxyURL: proxyURL, request: envelope)
    return (response.status, response.body)
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

    Agent launch:
      agent run -- COMMAND [ARG ...] Process-replace into the bundled laban-agent
                                     broker and run COMMAND with LABAN_AGENT_CONTROL_URL.
                                     Optional: an approval dialog now covers reads without
                                     it, so this is a dialogless path for CI and scripts,
                                     not a prerequisite for interactive use.

    Session-scoped commands:
      session state --json           GET /debug/state via agent proxy or lazy attach.
      session request METHOD PATH [--body JSON] [--json]
                                     Send a raw request via agent proxy or lazy attach.
      session scroll --rows N --json Scroll the bound session viewport via agent proxy or lazy attach.
      session proxy                  Forward JSONL stdin/stdout through the agent proxy (requires LABAN_AGENT_CONTROL_URL;
                                     an optional CI/no-dialog path, no lazy-attach equivalent).
      session current --json         Show the proxy-bound session identity (agent proxy or lazy attach).
      session get-text --screen|--scrollback [--start-line N] [--end-line N] [--max-lines N] [--json]
                                     Capture bounded plain text from the bound session (agent proxy or lazy attach).
      session screenshot [--output PATH] [--json]
                                     Capture the visible Laban window, including sheets and dialogs.
      propose --purpose TEXT -- COMMAND [ARG ...]
                                     Propose a command for user review via agent proxy or lazy attach.
      proposal list --json           List proposals for the bound session (requires LABAN_AGENT_CONTROL_URL).
      proposal status PROPOSAL_ID --json
                                     Show one proposal's state (requires LABAN_AGENT_CONTROL_URL).
      proposal cancel PROPOSAL_ID --json
                                     Cancel a pending proposal (requires LABAN_AGENT_CONTROL_URL).

    Agent context:
      context --json [--max-lines N] Print bound session identity, shell phase, and a
                                     recent-scrollback tail for prompt context (agent proxy or lazy attach).

    Waits:
      wait prompt [--timeout SECONDS]
                                     Block until the bound session's shell reaches atPrompt
                                     (default timeout 30s; requires LABAN_AGENT_CONTROL_URL).
      wait command-finished [--timeout SECONDS]
                                     Block until the bound session's completed-command count
                                     increments (default timeout 30s; requires LABAN_AGENT_CONTROL_URL).
      wait proposal --id PROPOSAL_ID --state STATE [--timeout SECONDS]
                                     Block until a proposal reaches STATE (default timeout 30s;
                                     requires LABAN_AGENT_CONTROL_URL).

    Lazy attach fallback:
      When LABAN_AGENT_CONTROL_URL is unset, session-scoped commands discover
      control.json and request a live, one-time user approval for the requested
      action. The agent proxy remains available when LABAN_AGENT_CONTROL_URL is set,
      and is now an optional CI/no-dialog path for reads rather than a prerequisite.
      session proxy, agent run, and wait are still broker-only: they require
      LABAN_AGENT_CONTROL_URL and do not fall back to lazy attach. session current,
      session get-text, and context now fall back to lazy attach, like session
      state/scroll/propose.

    Global options:
      --json                         Write machine-readable JSON to stdout.
      -h, --help                     Show this help.
  """

enum LabanCLIError: Error, Equatable {
  case unknownShell(String)
  case agentControlUnavailable
  case sessionProxyRequiresBroker
  case invalidWindowScreenshot
  case unsafeScreenshotOutput
}

extension LabanCLIError: CustomStringConvertible {
  var description: String {
    switch self {
    case .unknownShell(let shell):
      return "unknown shell: \(shell)"
    case .agentControlUnavailable:
      return "LABAN_AGENT_CONTROL_URL is not set; try `laban agent run -- <command>`"
    case .sessionProxyRequiresBroker:
      return
        "session proxy requires broker mode; restart the agent with `laban agent run -- <agent>` for long-lived session control."
    case .invalidWindowScreenshot:
      return "window screenshot response is invalid"
    case .unsafeScreenshotOutput:
      return "refusing to replace a screenshot output symlink"
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
