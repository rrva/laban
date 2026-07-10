import Foundation
import LabanControl
import XCTest

@testable import LabanCLI

final class LabanCLITests: XCTestCase {
  private let sentinel = "SECRET_SENTINEL_DO_NOT_PRINT"

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  private func writeControlFile(
    at dir: URL,
    url: String? = nil,
    token: String = "SECRET_SENTINEL_DO_NOT_PRINT",
    pid: Int = 1234,
    runId: String = "run-1"
  ) throws {
    let file = dir.appendingPathComponent("control.json")
    let socketPath = url ?? dir.appendingPathComponent("control.sock").path
    let payload: [String: Any] = [
      "url": socketPath,
      "token": token,
      "pid": pid,
      "runId": runId,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileManager.default.createFile(atPath: file.path, contents: data, attributes: nil)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: file.path)
  }

  // MARK: - Argument parsing

  func testParseDiscover() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["discover"]).success,
      .discover(json: false))
  }

  func testParseDiscoverJSON() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["discover", "--json"]).success,
      .discover(json: true))
  }

  func testParseStatusJSON() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["status", "--json"]).success,
      .status(json: true))
  }

  func testParseRequestWithBodyEquals() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["request", "POST", "/debug/actions", "--body={\"x\":1}"]).success,
      .request(method: "POST", path: "/debug/actions", body: "{\"x\":1}", json: false))
  }

  func testParseRequestWithBodySpace() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["request", "POST", "/debug/actions", "--body", "{\"x\":1}"])
        .success,
      .request(method: "POST", path: "/debug/actions", body: "{\"x\":1}", json: false))
  }

  func testParseRequestJSON() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["request", "GET", "/debug/health", "--json"]).success,
      .request(method: "GET", path: "/debug/health", body: nil, json: true))
  }

  func testParseCompletions() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["completions", "zsh"]).success,
      .completions(shell: "zsh"))
  }

  func testParseInstallCLI() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["install-cli", "--prefix", "/tmp/bin", "--dry-run"]).success,
      .installCLI(prefix: "/tmp/bin", dryRun: true))
  }

  func testParseUnknownCommand() {
    guard case .failure(let error) = LabanArgumentParser.parse(["serve"]) else {
      XCTFail("expected failure")
      return
    }
    XCTAssertEqual(error, .unknownCommand("serve"))
  }

  func testParseRequestMissingArguments() {
    guard case .failure(let error) = LabanArgumentParser.parse(["request", "GET"]) else {
      XCTFail("expected failure")
      return
    }
    XCTAssertEqual(error, .missingArgument("METHOD PATH"))
  }

  // MARK: - Command behavior

  func testDiscoverJSONRedactsToken() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeControlFile(at: dir)

    let result = LabanCLI.run(command: .discover(json: true), controlDirectory: dir)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains(sentinel))
    XCTAssertFalse(result.stdout.contains("\"token\""))
    XCTAssertTrue(result.stdout.contains("\"hasAppObserveToken\":true"))
    XCTAssertTrue(result.stdout.contains("\"path\""))
    XCTAssertTrue(result.stdout.contains("\"url\""))
    XCTAssertTrue(result.stdout.contains("\"pid\":1234"))
    XCTAssertTrue(result.stdout.contains("\"runId\":\"run-1\""))
  }

  func testCompletionsZshDoesNotReadControlJSON() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-cli-missing-\(UUID().uuidString)", isDirectory: true)
    // Deliberately do not create the directory.

    let result = LabanCLI.run(
      command: .completions(shell: "zsh"),
      controlDirectory: dir)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("#compdef laban"))
    XCTAssertTrue(result.stderr.isEmpty)
  }

  func testRequestNon2xxExitsNonzero() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeControlFile(at: dir)

    let result = LabanCLI.run(
      command: .request(method: "GET", path: "/debug/state", body: nil, json: true),
      controlDirectory: dir,
      request: { _, _, _, _, _ in
        (403, Data(#"{"error":"forbidden"}"#.utf8))
      })
    XCTAssertEqual(result.exitCode, 5)
    XCTAssertTrue(result.stdout.contains("forbidden"))
    XCTAssertTrue(result.stderr.contains("server returned 403"))
  }

  func testRequest2xxExitsZero() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeControlFile(at: dir)

    let result = LabanCLI.run(
      command: .request(method: "GET", path: "/debug/health", body: nil, json: true),
      controlDirectory: dir,
      request: { _, _, _, _, _ in
        (200, Data(#"{"ok":true}"#.utf8))
      })
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("\"ok\":true"))
    XCTAssertTrue(result.stderr.isEmpty)
  }

  func testInstallCLIDryRun() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let prefix = dir.appendingPathComponent("bin").path

    let result = LabanCLI.run(
      command: .installCLI(prefix: prefix, dryRun: true),
      executablePath: { "/Applications/Laban.app/Contents/MacOS/laban" })
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Would install shim"))
    XCTAssertTrue(result.stdout.contains(prefix))
    XCTAssertTrue(result.stdout.contains("/Applications/Laban.app/Contents/MacOS/laban"))

    let shimURL = URL(fileURLWithPath: prefix).appendingPathComponent("laban")
    XCTAssertFalse(FileManager.default.fileExists(atPath: shimURL.path))
  }

  func testInstallCLIWritesShim() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let prefix = dir.appendingPathComponent("bin").path

    let result = LabanCLI.run(
      command: .installCLI(prefix: prefix, dryRun: false),
      executablePath: { "/Applications/Laban.app/Contents/MacOS/laban" })
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Installed shim"))

    let shimURL = URL(fileURLWithPath: prefix).appendingPathComponent("laban")
    XCTAssertTrue(FileManager.default.fileExists(atPath: shimURL.path))
    let content = try String(contentsOf: shimURL, encoding: .utf8)
    XCTAssertTrue(content.contains("exec '/Applications/Laban.app/Contents/MacOS/laban' \"$@\""))

    let attributes = try FileManager.default.attributesOfItem(atPath: shimURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
    XCTAssertEqual(permissions, 0o755)
  }

  func testInstallCLIQuotesPathWithSingleQuoteAndSpaces() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let prefix = dir.appendingPathComponent("bin").path
    let executable = "/tmp/Laban dir/with'quote/laban"

    let result = LabanCLI.run(
      command: .installCLI(prefix: prefix, dryRun: true),
      executablePath: { executable })
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Would install shim"))

    // Dry-run output still shows the raw resolved path; the actual shim content
    // is what matters for safety.
    let writeResult = LabanCLI.run(
      command: .installCLI(prefix: prefix, dryRun: false),
      executablePath: { executable })
    XCTAssertEqual(writeResult.exitCode, 0)

    let shimURL = URL(fileURLWithPath: prefix).appendingPathComponent("laban")
    let content = try String(contentsOf: shimURL, encoding: .utf8)
    XCTAssertTrue(content.contains("exec '/tmp/Laban dir/with'\\''quote/laban' \"$@\""))
  }

  func testFormattedOutputDoesNotAddBlankLineForEmptyStdout() {
    let outcome = LabanCLIResult(exitCode: 3, stdout: "", stderr: "error")
    let formatted = LabanCLI.formattedOutput(outcome)
    XCTAssertEqual(formatted.stdout, "")
    XCTAssertEqual(formatted.stderr, "error\n")
  }

  func testFormattedOutputAddsNewlineForNonEmptyStdout() {
    let outcome = LabanCLIResult(exitCode: 0, stdout: "ok", stderr: "")
    let formatted = LabanCLI.formattedOutput(outcome)
    XCTAssertEqual(formatted.stdout, "ok\n")
    XCTAssertEqual(formatted.stderr, "")
  }

  // MARK: - Agent command parsing

  func testParseAgentRun() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["agent", "run", "--", "git", "status"]).success,
      .agentRun(command: ["git", "status"]))
  }

  func testParseAgentRunRequiresSeparator() {
    guard case .failure(let error) = LabanArgumentParser.parse(["agent", "run", "git"]) else {
      XCTFail("expected failure")
      return
    }
    XCTAssertEqual(error, .missingArgument("-- COMMAND"))
  }

  func testParseSessionStateJSON() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["session", "state", "--json"]).success,
      .sessionState(json: true))
  }

  func testParseSessionRequest() {
    XCTAssertEqual(
      LabanArgumentParser.parse([
        "session", "request", "POST", "/debug/actions",
        "--body", "{\"action\":\"scrollViewport\"}",
        "--json",
      ]).success,
      .sessionRequest(
        method: "POST",
        path: "/debug/actions",
        body: "{\"action\":\"scrollViewport\"}",
        json: true))
  }

  func testParseSessionScroll() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["session", "scroll", "--rows", "-40", "--json"]).success,
      .sessionScroll(rows: -40, json: true))
  }

  func testParseSessionProxy() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["session", "proxy"]).success,
      .sessionProxy)
  }

  func testParseSessionCurrentJSON() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["session", "current", "--json"]).success,
      .sessionCurrent(json: true))
  }

  func testParseSessionGetTextDefaultsToScreen() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["session", "get-text", "--json"]).success,
      .sessionGetText(
        source: "screen", startLine: nil, endLine: nil, maxLines: nil, json: true))
  }

  func testParseSessionGetTextScrollbackWithBounds() {
    XCTAssertEqual(
      LabanArgumentParser.parse([
        "session", "get-text", "--scrollback",
        "--start-line", "5", "--end-line", "20", "--max-lines", "100", "--json",
      ]).success,
      .sessionGetText(
        source: "scrollback", startLine: 5, endLine: 20, maxLines: 100, json: true))
  }

  func testParseSessionGetTextRejectsBothScreenAndScrollback() {
    guard
      case .failure(let error) = LabanArgumentParser.parse([
        "session", "get-text", "--screen", "--scrollback",
      ])
    else {
      XCTFail("expected failure")
      return
    }
    XCTAssertEqual(error, .unknownCommand("session get-text --screen --scrollback"))
  }

  func testParseContextDefaultsToFortyMaxLines() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["context", "--json"]).success,
      .context(json: true, maxLines: 40))
  }

  func testParseContextWithMaxLines() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["context", "--json", "--max-lines", "10"]).success,
      .context(json: true, maxLines: 10))
  }

  func testParsePropose() {
    XCTAssertEqual(
      LabanArgumentParser.parse([
        "propose", "--purpose", "Inspect repo", "--", "git", "status",
      ]).success,
      .propose(purpose: "Inspect repo", command: ["git", "status"]))
  }

  func testParseProposePurposeEquals() {
    XCTAssertEqual(
      LabanArgumentParser.parse([
        "propose", "--purpose=Inspect repo", "--", "git", "status",
      ]).success,
      .propose(purpose: "Inspect repo", command: ["git", "status"]))
  }

  func testParseAgentRunPreservesFlagsAfterSeparator() {
    XCTAssertEqual(
      LabanArgumentParser.parse([
        "agent", "run", "--", "tool", "--json", "--body", "x",
      ]).success,
      .agentRun(command: ["tool", "--json", "--body", "x"]))
  }

  func testParseProposePreservesFlagsAfterSeparator() {
    XCTAssertEqual(
      LabanArgumentParser.parse([
        "propose", "--purpose", "P", "--", "echo", "--json", "--body", "x",
      ]).success,
      .propose(purpose: "P", command: ["echo", "--json", "--body", "x"]))
  }

  // MARK: - Session command behavior

  func testSessionStateUsesAgentControlURLAndNotC14() {
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      controlDirectory: URL(fileURLWithPath: "/nonexistent/control/dir"),
      agentProxyRequest: { proxyURL, envelope in
        XCTAssertEqual(proxyURL, "unix:///proxy.sock")
        XCTAssertEqual(envelope.method, "GET")
        XCTAssertEqual(envelope.path, "/debug/state")
        return (200, "{\"ok\":true}")
      },
      agentProxyURL: "unix:///proxy.sock",
      executablePath: { "/tmp/laban" })

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("\"ok\":true"))
    XCTAssertTrue(result.stderr.isEmpty)
  }

  func testSessionStateMissingProxyEnvUsesLazyAttach() {
    let result = LabanCLI.run(
      command: .sessionState(json: true),
      controlDirectory: URL(fileURLWithPath: "/nonexistent/control/dir"),
      agentProxyRequest: { _, _ in fatalError("should not be called") },
      lazyAttachRequest: { _, _, _, _, _ in throw LazyAttachClientError.controlPlaneUnavailable },
      executablePath: { "/tmp/laban" })

    XCTAssertEqual(result.exitCode, 3)
    XCTAssertTrue(result.stderr.contains("control plane unavailable"))
    XCTAssertFalse(result.stderr.contains("LABAN_AGENT_CONTROL_URL"))
    XCTAssertFalse(result.stdout.contains("SECRET"))
  }

  func testSessionScrollPostsScrollViewportAction() {
    let result = LabanCLI.run(
      command: .sessionScroll(rows: -40, json: true),
      agentProxyRequest: { proxyURL, envelope in
        XCTAssertEqual(proxyURL, "unix:///proxy.sock")
        XCTAssertEqual(envelope.path, "/debug/actions")
        XCTAssertEqual(envelope.body, "{\"action\":\"scrollViewport\",\"deltaRows\":-40}")
        return (200, "{\"ok\":true}")
      },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("\"ok\":true"))
  }

  func testProposePostsProposeAction() {
    let result = LabanCLI.run(
      command: .propose(purpose: "Inspect", command: ["git", "status"]),
      agentProxyRequest: { proxyURL, envelope in
        XCTAssertEqual(proxyURL, "unix:///proxy.sock")
        XCTAssertEqual(envelope.path, "/debug/actions")
        XCTAssertTrue(envelope.body?.contains("\"action\":\"propose\"") ?? false)
        XCTAssertTrue(envelope.body?.contains("\"command\":\"git status\"") ?? false)
        XCTAssertTrue(envelope.body?.contains("\"purpose\":\"Inspect\"") ?? false)
        return (200, "{\"proposalID\":\"p1\",\"writtenToPTY\":false}")
      },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("\"proposalID\":\"p1\""))
    XCTAssertTrue(result.stdout.contains("\"writtenToPTY\":false"))
  }

  // MARK: - session current / session get-text / context behavior

  func testSessionCurrentComposesShellIntegrationAndSessionDetail() {
    let result = LabanCLI.run(
      command: .sessionCurrent(json: true),
      agentProxyRequest: { proxyURL, envelope in
        XCTAssertEqual(proxyURL, "unix:///proxy.sock")
        switch envelope.path {
        case "/debug/shell-integration/state":
          return (200, "{\"sessionId\":\"session-a\",\"phase\":\"atPrompt\",\"lastExitCode\":0}")
        case "/debug/sessions/session-a":
          return (200, "{\"id\":\"session-a\",\"tabId\":\"tab-a\"}")
        default:
          XCTFail("unexpected path \(envelope.path)")
          return (500, "{}")
        }
      },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("\"id\":\"session-a\""))
    XCTAssertTrue(result.stdout.contains("\"tabId\":\"tab-a\""))
    XCTAssertTrue(result.stderr.isEmpty)
  }

  func testSessionCurrentMissingProxyEnvExitsThreeWithoutLazyAttach() {
    let result = LabanCLI.run(
      command: .sessionCurrent(json: true),
      agentProxyRequest: { _, _ in fatalError("should not be called") },
      lazyAttachRequest: { _, _, _, _, _ in fatalError("must not fall back to lazy attach") })

    XCTAssertEqual(result.exitCode, 3)
    XCTAssertTrue(result.stderr.contains("LABAN_AGENT_CONTROL_URL"))
    XCTAssertFalse(result.stdout.contains(sentinel))
  }

  func testSessionGetTextSendsQueryParametersAndReturnsBody() {
    let result = LabanCLI.run(
      command: .sessionGetText(
        source: "scrollback", startLine: 0, endLine: 9, maxLines: 50, json: true),
      agentProxyRequest: { proxyURL, envelope in
        XCTAssertEqual(proxyURL, "unix:///proxy.sock")
        XCTAssertEqual(
          envelope.path,
          "/debug/text?source=scrollback&startLine=0&endLine=9&maxLines=50")
        return (200, "{\"ok\":true,\"lines\":[\"a\",\"b\"]}")
      },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("\"lines\":[\"a\",\"b\"]"))
  }

  func testSessionGetTextMissingProxyEnvExitsThreeWithoutLazyAttach() {
    let result = LabanCLI.run(
      command: .sessionGetText(
        source: "screen", startLine: nil, endLine: nil, maxLines: nil, json: true),
      agentProxyRequest: { _, _ in fatalError("should not be called") },
      lazyAttachRequest: { _, _, _, _, _ in fatalError("must not fall back to lazy attach") })

    XCTAssertEqual(result.exitCode, 3)
    XCTAssertTrue(result.stderr.contains("LABAN_AGENT_CONTROL_URL"))
    XCTAssertFalse(result.stdout.contains(sentinel))
  }

  func testSessionGetTextNon2xxExitsFive() {
    let result = LabanCLI.run(
      command: .sessionGetText(
        source: "screen", startLine: nil, endLine: nil, maxLines: nil, json: true),
      agentProxyRequest: { _, _ in (403, "{\"error\":\"forbidden\"}") },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 5)
    XCTAssertTrue(result.stdout.contains("forbidden"))
    XCTAssertTrue(result.stderr.contains("server returned 403"))
  }

  func testContextComposesBundleAndNeverLeaksSentinel() {
    let result = LabanCLI.run(
      command: .context(json: true, maxLines: 40),
      agentProxyRequest: { proxyURL, envelope in
        XCTAssertEqual(proxyURL, "unix:///proxy.sock")
        switch envelope.path {
        case "/debug/shell-integration/state":
          return (200, "{\"sessionId\":\"session-a\",\"phase\":\"atPrompt\",\"lastExitCode\":0}")
        case "/debug/sessions/session-a":
          return (200, "{\"id\":\"session-a\",\"tabId\":\"tab-a\",\"token\":\"\(self.sentinel)\"}")
        case "/debug/text?source=scrollback&maxLines=40":
          return (200, "{\"ok\":true,\"lines\":[\"hello\",\"world\"]}")
        default:
          XCTFail("unexpected path \(envelope.path)")
          return (500, "{}")
        }
      },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("\"sessionId\":\"session-a\""))
    XCTAssertTrue(result.stdout.contains("\"phase\":\"atPrompt\""))
    XCTAssertTrue(result.stdout.contains("\"hello\""))
    // session.detail is forwarded into the bundle after stripping any
    // token-like key; assert a sentinel value never leaks into context
    // output even when an upstream response body happens to carry one, so a
    // future field addition cannot silently start forwarding tokens through
    // `context`.
    XCTAssertFalse(result.stdout.contains(sentinel))
    XCTAssertFalse(result.stderr.contains(sentinel))
  }

  func testContextMissingProxyEnvExitsThreeWithoutLazyAttach() {
    let result = LabanCLI.run(
      command: .context(json: true, maxLines: 40),
      agentProxyRequest: { _, _ in fatalError("should not be called") },
      lazyAttachRequest: { _, _, _, _, _ in fatalError("must not fall back to lazy attach") })

    XCTAssertEqual(result.exitCode, 3)
    XCTAssertTrue(result.stderr.contains("LABAN_AGENT_CONTROL_URL"))
    XCTAssertFalse(result.stdout.contains(sentinel))
  }

  func testContextPropagatesNon2xxFromGetTextLeg() {
    let result = LabanCLI.run(
      command: .context(json: true, maxLines: 40),
      agentProxyRequest: { _, envelope in
        switch envelope.path {
        case "/debug/shell-integration/state":
          return (200, "{\"sessionId\":\"session-a\",\"phase\":\"atPrompt\",\"lastExitCode\":0}")
        case "/debug/sessions/session-a":
          return (200, "{\"id\":\"session-a\"}")
        default:
          return (403, "{\"error\":\"forbidden\"}")
        }
      },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 5)
    XCTAssertTrue(result.stdout.contains("forbidden"))
  }

  func testSessionRequestNon2xxExitsNonzero() {
    let result = LabanCLI.run(
      command: .sessionRequest(
        method: "POST",
        path: "/debug/actions",
        body: "{\"action\":\"typeText\"}",
        json: true),
      agentProxyRequest: { _, _ in
        return (403, "{\"error\":\"forbidden\"}")
      },
      agentProxyURL: "unix:///proxy.sock")

    XCTAssertEqual(result.exitCode, 5)
    XCTAssertTrue(result.stdout.contains("forbidden"))
    XCTAssertTrue(result.stderr.contains("server returned 403"))
  }
}

extension Result {
  var success: Success? {
    if case .success(let value) = self { return value }
    return nil
  }
}
