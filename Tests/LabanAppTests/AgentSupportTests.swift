import Darwin
import LabanCore
import XCTest

@testable import LabanApp

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

  func testResumeCommandShape() {
    XCTAssertEqual(
      AgentSupport.claude().resumeCommand("abc"), "claude --resume abc")
    XCTAssertEqual(
      AgentSupport.codex().resumeCommand("xyz"), "codex resume xyz")
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
