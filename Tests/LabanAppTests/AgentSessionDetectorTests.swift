import Foundation
import LabanCore
import XCTest

@testable import LabanApp

/// Unit tests for `AgentSessionDetector` driven by a mock
/// `ProcessIntrospector`. The production detector still uses
/// `LibprocIntrospector` against the real kernel; these tests
/// exercise the surrounding logic — descendant walk, agent matching,
/// liveness transitions — without depending on xctest's flaky
/// process visibility (the prior integration tests failed because the
/// xctest harness hides spawned children from proc_listpids).
final class AgentSessionDetectorTests: XCTestCase {

  /// Capture every observation the detector emits.
  private final class Recorder: AgentSessionDetectorObserver {
    var observations: [AgentInfo?] = []
    func agentSessionDetector(
      _ detector: AgentSessionDetector, didObserve agent: AgentInfo?
    ) {
      observations.append(agent)
    }
  }

  func testFindAgentMatchesClaudeBasenameAndJSONL() {
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0001"
    let jsonlPath =
      "/Users/x/.claude/projects/proj/\(sessionId).jsonl"
    let mock = MockIntrospector(
      children: [100: [(101, "claude")]],
      openVnodes: [101: [jsonlPath, "/tmp/scratch.txt"]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 100, introspector: mock)

    let descendants = detector.collectDescendants(of: 100, depth: 0)
    XCTAssertEqual(descendants.count, 1)
    let agent = detector.findAgent(in: descendants)
    XCTAssertEqual(agent?.name, .claude)
    XCTAssertEqual(agent?.sessionId, sessionId)
    XCTAssertEqual(agent?.jsonlPath, jsonlPath)
    XCTAssertEqual(agent?.wasRunningAtQuit, true)
  }

  func testFindAgentMatchesCodexBasenameAndRolloutJSONL() {
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0002"
    let jsonlPath =
      "/Users/x/.codex/sessions/2026/05/17/rollout-2026-05-17T14-23-11-\(sessionId).jsonl"
    let mock = MockIntrospector(
      children: [200: [(201, "codex")]],
      openVnodes: [201: [jsonlPath]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 200, introspector: mock)
    let agent = detector.findAgent(in: detector.collectDescendants(of: 200, depth: 0))
    XCTAssertEqual(agent?.name, .codex)
    XCTAssertEqual(agent?.sessionId, sessionId)
  }

  func testFindAgentIgnoresUnrelatedJSONL() {
    // claude has /tmp/foo.jsonl open — that's not the session log.
    // The extractor must reject it; detector returns nil.
    let mock = MockIntrospector(
      children: [300: [(301, "claude")]],
      openVnodes: [301: ["/tmp/foo.jsonl", "/private/var/cache/something.jsonl"]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 300, introspector: mock)
    XCTAssertNil(detector.findAgent(in: detector.collectDescendants(of: 300, depth: 0)))
  }

  func testFindAgentIgnoresNonAgentBasenames() {
    let mock = MockIntrospector(
      children: [400: [(401, "vim")]],
      openVnodes: [401: ["/Users/x/.claude/projects/p/0fa31a8c-1234-5678-9abc-deadbeef0003.jsonl"]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 400, introspector: mock)
    XCTAssertNil(detector.findAgent(in: detector.collectDescendants(of: 400, depth: 0)))
  }

  func testDescendantWalkRecursesThroughWrappers() {
    // shell (500) -> npx (501) -> node (502) -> claude (503)
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0004"
    let jsonlPath = "/Users/x/.claude/projects/p/\(sessionId).jsonl"
    let mock = MockIntrospector(
      children: [
        500: [(501, "npx")],
        501: [(502, "node")],
        502: [(503, "claude")],
      ],
      openVnodes: [503: [jsonlPath]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 500, introspector: mock)
    let agent = detector.findAgent(in: detector.collectDescendants(of: 500, depth: 0))
    XCTAssertEqual(agent?.sessionId, sessionId)
  }

  func testDescendantWalkRespectsDepthCap() {
    // Build a chain deeper than the cap (4) and put claude at the
    // bottom — detector should NOT find it.
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0005"
    var children: [pid_t: [(pid_t, String)]] = [:]
    let pids: [pid_t] = [600, 601, 602, 603, 604, 605]
    for i in 0..<pids.count - 1 {
      children[pids[i]] = [(pids[i + 1], "wrapper")]
    }
    children[pids[pids.count - 2]] = [(pids[pids.count - 1], "claude")]
    let mock = MockIntrospector(
      children: children,
      openVnodes: [pids.last!: ["/Users/x/.claude/projects/p/\(sessionId).jsonl"]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 600, introspector: mock)
    let agent = detector.findAgent(in: detector.collectDescendants(of: 600, depth: 0))
    XCTAssertNil(
      agent,
      "depth cap (\(AgentSessionDetector.maxDescendantDepth)) must hide agents deeper than the cap")
  }

  func testHandleObservationFiresLifenessTransition() {
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0006"
    let jsonlPath = "/Users/x/.claude/projects/p/\(sessionId).jsonl"

    let mock = MockIntrospector(
      children: [700: [(701, "claude")]],
      openVnodes: [701: [jsonlPath]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 700,
      tickInterval: .milliseconds(50),
      introspector: mock)
    let recorder = Recorder()
    detector.observer = recorder

    // Step 1: alive.
    let detected = detector.findAgent(in: detector.collectDescendants(of: 700, depth: 0))
    XCTAssertNotNil(detected)
    detector.handleObservation(detected)
    XCTAssertEqual(recorder.observations.last??.wasRunningAtQuit, true)
    XCTAssertEqual(recorder.observations.count, 1)

    // Step 2: agent disappears. The detector's identity-preserving
    // transition flips wasRunningAtQuit to false while keeping the
    // captured session id/path — exactly the signal the launch
    // planner reads on next launch.
    mock.children = [700: []]
    let absent = detector.findAgent(in: detector.collectDescendants(of: 700, depth: 0))
    XCTAssertNil(absent)
    detector.handleObservation(absent)
    XCTAssertEqual(recorder.observations.count, 2)
    XCTAssertEqual(recorder.observations.last??.sessionId, sessionId)
    XCTAssertEqual(recorder.observations.last??.wasRunningAtQuit, false)
  }
}

/// Mock implementation that returns canned descendant trees and
/// per-pid open-fd path lists.
private final class MockIntrospector: ProcessIntrospector {
  var children: [pid_t: [(pid_t, String)]]
  var openVnodes: [pid_t: [String]]

  init(children: [pid_t: [(pid_t, String)]], openVnodes: [pid_t: [String]]) {
    self.children = children
    self.openVnodes = openVnodes
  }

  func children(of parent: pid_t) -> [(pid: pid_t, basename: String)] {
    (children[parent] ?? []).map { (pid: $0.0, basename: $0.1) }
  }
  func openVnodePaths(of pid: pid_t) -> [String] {
    openVnodes[pid] ?? []
  }
}

