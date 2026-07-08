import Foundation
import LabanControl
@testable import LabanCLI
import XCTest

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
      LabanArgumentParser.parse(["request", "POST", "/debug/actions", "--body", "{\"x\":1}"]).success,
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
}

extension Result {
  var success: Success? {
    if case .success(let value) = self { return value }
    return nil
  }
}
