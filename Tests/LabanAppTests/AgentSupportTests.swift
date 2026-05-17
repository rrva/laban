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
}
