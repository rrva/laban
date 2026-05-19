import Darwin
import LabanCore
import XCTest

@testable import LabanCore

final class AgentSupportTests: XCTestCase {

  func testClaudeExtractorAcceptsCanonicalPath() {
    let path =
      "/Users/x/.claude/projects/-Users-x-wrk-foo/0fa31a8c-1234-5678-9abc-deadbeef0000.jsonl"
    let id = AgentSupport.claude().extractSessionId(path)
    XCTAssertEqual(id, "0fa31a8c-1234-5678-9abc-deadbeef0000")
  }

  func testClaudeExtractorRejectsRandomJSONL() {
    let path = "/tmp/scratch.jsonl"
    XCTAssertNil(AgentSupport.claude().extractSessionId(path))
  }

  func testClaudeExtractorRejectsNonUUIDStem() {
    let path = "/Users/x/.claude/projects/proj/not-a-uuid.jsonl"
    XCTAssertNil(AgentSupport.claude().extractSessionId(path))
  }

  func testUUIDShapeCheckAcceptsOnlyASCIICanonicalUUIDs() {
    XCTAssertTrue(AgentSupport.isUUID("0fa31a8c-1234-5678-9abc-deadbeef0000"))
    XCTAssertTrue(AgentSupport.isUUID("0FA31A8C-1234-5678-9ABC-DEADBEEF0000"))

    XCTAssertFalse(AgentSupport.isUUID("0fa31a8c1234-5678-9abc-deadbeef0000"))
    XCTAssertFalse(AgentSupport.isUUID("0fa31a8c-1234-5678-9abc-deadbeef000"))
    XCTAssertFalse(AgentSupport.isUUID("0fa31a8c-1234-5678-9abc-deadbeef00000"))
    XCTAssertFalse(AgentSupport.isUUID("0fa31a8c-1234-5678-9abc-deadbeef000g"))
    XCTAssertFalse(AgentSupport.isUUID("0fa31a8c-1234-5678-9abc-deadbeef000\u{00E9}"))
  }

  func testCodexExtractorAcceptsRolloutPath() {
    let path =
      "/Users/x/.codex/sessions/2026/05/17/rollout-2026-05-17T14-23-11-0fa31a8c-1234-5678-9abc-deadbeef0000.jsonl"
    let id = AgentSupport.codex().extractSessionId(path)
    XCTAssertEqual(id, "0fa31a8c-1234-5678-9abc-deadbeef0000")
  }

  func testCodexExtractorRejectsClaudePath() {
    let path = "/Users/x/.claude/projects/p/0fa31a8c-1234-5678-9abc-deadbeef0000.jsonl"
    XCTAssertNil(AgentSupport.codex().extractSessionId(path))
  }

  func testRegistryEnumeratesBothAgents() {
    let names = AgentRegistry.supported.map { $0.name }
    XCTAssertTrue(names.contains(.claude))
    XCTAssertTrue(names.contains(.codex))
  }

  func testRegistryMapsBinaryBasename() {
    XCTAssertEqual(AgentRegistry.agent(forBinaryBasename: "claude")?.name, .claude)
    XCTAssertEqual(AgentRegistry.agent(forBinaryBasename: "codex")?.name, .codex)
    XCTAssertNil(AgentRegistry.agent(forBinaryBasename: "vim"))
  }

  func testRegistryFallsBackToInvocationNameForVersionedClaudeExecutable() {
    XCTAssertEqual(
      AgentRegistry.agent(forBinaryBasename: "2.1.143", arguments: ["claude", "--chrome"])?.name,
      .claude)
    XCTAssertEqual(
      AgentRegistry.agent(
        forBinaryBasename: "2.1.143",
        arguments: ["/Users/x/.local/bin/claude", "--chrome"])?.name,
      .claude)
    XCTAssertNil(
      AgentRegistry.agent(forBinaryBasename: "2.1.143", arguments: ["vim"]))
  }

  func testResumeCommandShape() {
    XCTAssertEqual(
      AgentSupport.claude().resumeCommand("abc"), "command claude --resume abc")
    XCTAssertEqual(
      AgentSupport.codex().resumeCommand("xyz"), "codex resume xyz")
  }

  func testShellCommandQuotesUnsafeArguments() {
    XCTAssertEqual(ShellCommand.quote("a b"), "'a b'")
    XCTAssertEqual(ShellCommand.quote("a'b"), "'a'\\''b'")
    XCTAssertEqual(
      ShellCommand.render(["cmd", "plain", "a b"]),
      "cmd plain 'a b'")
  }

  func testClaudeAdapterPreservesResumeSafeOptionsAndDropsReplayingFlags() {
    let command = ClaudeResumeAdapter().resumeCommand(
      sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
      context: AgentLaunchContext(
        cwd: "/tmp",
        argv: [
          "claude",
          "--worktree",
          "throwaway",
          "--model",
          "sonnet",
          "--chrome",
          "--effort=high",
          "--permission-mode",
          "plan",
          "--fork-session",
          "--dangerously-skip-permissions",
          "--add-dir",
          "/Users/x/extra dir",
          "--permission-mode",
          "bypassPermissions",
          "prompt text",
        ],
        env: [:]))

    XCTAssertTrue(command.hasPrefix("command claude --resume 0fa31a8c-1234-5678-9abc-deadbeef0000"))
    XCTAssertTrue(command.contains("--model sonnet"))
    XCTAssertTrue(command.contains("--chrome"))
    XCTAssertTrue(command.contains("--effort high"))
    XCTAssertFalse(command.contains("--permission-mode plan"))
    XCTAssertTrue(command.contains("--dangerously-skip-permissions"))
    XCTAssertTrue(command.contains("--add-dir '/Users/x/extra dir'"))
    XCTAssertTrue(command.contains("--permission-mode bypassPermissions"))
    XCTAssertFalse(command.contains("worktree"))
    XCTAssertFalse(command.contains("throwaway"))
    XCTAssertFalse(command.contains("fork-session"))
    XCTAssertFalse(command.contains("prompt text"))
  }

  func testClaudeAdapterDropsOriginalResumeAndSessionOptions() {
    let command = ClaudeResumeAdapter().resumeCommand(
      sessionId: "fresh",
      context: AgentLaunchContext(
        cwd: "/tmp",
        argv: [
          "claude", "--resume", "old", "--session-id", "old-session", "-c", "--model", "opus",
        ],
        env: [:]))

    XCTAssertEqual(command, "command claude --resume fresh --model opus")
    XCTAssertFalse(command.contains("old"))
  }

  func testClaudeAdapterBypassesShellFunctionAndDeduplicatesWrapperFlags() {
    let command = ClaudeResumeAdapter().resumeCommand(
      sessionId: "fresh",
      context: AgentLaunchContext(
        cwd: "/tmp",
        argv: [
          "claude",
          "--chrome",
          "--resume",
          "old",
          "--chrome",
          "--chrome",
          "--dangerously-skip-permissions",
          "--dangerously-skip-permissions",
          "--model",
          "haiku",
          "--model",
          "sonnet",
        ],
        env: [:]))

    XCTAssertEqual(
      command,
      "command claude --resume fresh --chrome --dangerously-skip-permissions --model sonnet")
  }

  func testCodexAdapterPreservesResumeSafeOptionsAndDropsReplayingFlags() {
    let command = CodexResumeAdapter().resumeCommand(
      sessionId: "0fa31a8c-1234-5678-9abc-deadbeef0000",
      context: AgentLaunchContext(
        cwd: "/Users/x/project dir",
        argv: [
          "codex",
          "resume",
          "--last",
          "--model",
          "gpt-5.2",
          "--profile=work",
          "--sandbox",
          "workspace-write",
          "--ask-for-approval",
          "on-request",
          "--search",
          "--no-alt-screen",
          "--dangerously-bypass-approvals-and-sandbox",
          "--sandbox",
          "danger-full-access",
          "--ask-for-approval",
          "never",
          "prompt text",
        ],
        env: [:]))

    XCTAssertTrue(
      command.hasPrefix(
        "codex resume 0fa31a8c-1234-5678-9abc-deadbeef0000 -C '/Users/x/project dir'"))
    XCTAssertTrue(command.contains("--model gpt-5.2"))
    XCTAssertTrue(command.contains("--profile work"))
    XCTAssertTrue(command.contains("--sandbox workspace-write"))
    XCTAssertTrue(command.contains("--ask-for-approval on-request"))
    XCTAssertTrue(command.contains("--search"))
    XCTAssertTrue(command.contains("--no-alt-screen"))
    XCTAssertTrue(command.contains("--dangerously-bypass-approvals-and-sandbox"))
    XCTAssertTrue(command.contains("--sandbox danger-full-access"))
    XCTAssertTrue(command.contains("--ask-for-approval never"))
    XCTAssertFalse(command.contains("--last"))
    XCTAssertFalse(command.contains("prompt text"))
  }

  func testCodexAdapterDropsRemoteAndOriginalCwdOptions() {
    let command = CodexResumeAdapter().resumeCommand(
      sessionId: "fresh",
      context: AgentLaunchContext(
        cwd: "/safe/cwd",
        argv: [
          "codex",
          "-C",
          "/old/cwd",
          "--remote",
          "ws://host:1",
          "--remote-auth-token-env",
          "TOKEN_ENV",
          "--local-provider",
          "ollama",
          "--model",
          "gpt-5.2",
        ],
        env: [:]))

    XCTAssertEqual(command, "codex resume fresh -C /safe/cwd --model gpt-5.2")
    XCTAssertFalse(command.contains("/old/cwd"))
    XCTAssertFalse(command.contains("TOKEN_ENV"))
    XCTAssertFalse(command.contains("ollama"))
  }

  func testAgentEnvironmentSanitizerOnlyKeepsSafeNonSecretNames() {
    let sanitized = AgentEnvironmentSanitizer.sanitize([
      "TERM": "xterm-256color",
      "LANG": "en_US.UTF-8",
      "PATH": "/bin",
      "OPENAI_API_KEY": "secret",
      "CLAUDE_CONFIG_DIR": "/tmp/claude",
      "CODEX_HOME": "TOKEN=secret",
    ])

    XCTAssertEqual(sanitized["TERM"], "xterm-256color")
    XCTAssertEqual(sanitized["LANG"], "en_US.UTF-8")
    XCTAssertEqual(sanitized["CLAUDE_CONFIG_DIR"], "/tmp/claude")
    XCTAssertNil(sanitized["PATH"])
    XCTAssertNil(sanitized["OPENAI_API_KEY"])
    XCTAssertNil(sanitized["CODEX_HOME"])
  }

  func testClaudeExtractorHonorsClaudeConfigDirOverride() {
    let override = "/var/tmp/laban-claude-test-\(UUID().uuidString)"
    setenv("CLAUDE_CONFIG_DIR", override, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef1234"
    let path = "\(override)/projects/some-encoded/\(sessionId).jsonl"
    XCTAssertEqual(
      AgentSupport.claude().extractSessionId(path),
      sessionId,
      "CLAUDE_CONFIG_DIR-rooted paths must match")
    // Sanity: the default-layout matcher still works alongside it.
    let canonical =
      "/Users/x/.claude/projects/p/0fa31a8c-1234-5678-9abc-deadbeef5678.jsonl"
    XCTAssertEqual(
      AgentSupport.claude().extractSessionId(canonical),
      "0fa31a8c-1234-5678-9abc-deadbeef5678")
  }

  func testCodexExtractorHonorsCodexHomeOverride() {
    let override = "/var/tmp/laban-codex-test-\(UUID().uuidString)"
    setenv("CODEX_HOME", override, 1)
    defer { unsetenv("CODEX_HOME") }
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef4321"
    let path =
      "\(override)/sessions/2026/05/17/rollout-2026-05-17T14-23-11-\(sessionId).jsonl"
    XCTAssertEqual(
      AgentSupport.codex().extractSessionId(path),
      sessionId,
      "CODEX_HOME-rooted paths must match")
  }

  func testExtractorsRejectMismatchedOverrides() {
    setenv("CLAUDE_CONFIG_DIR", "/other/place", 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    // A path that doesn't sit under the override prefix and doesn't
    // contain the default `.claude/projects/` directory must be
    // rejected — no false positives.
    XCTAssertNil(
      AgentSupport.claude().extractSessionId(
        "/random/tmp/0fa31a8c-1234-5678-9abc-deadbeef9999.jsonl"))
  }
}
