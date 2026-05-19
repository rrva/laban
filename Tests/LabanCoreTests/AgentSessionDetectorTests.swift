import Foundation
import LabanCore
import XCTest

@testable import LabanCore

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
      openVnodes: [101: [jsonlPath, "/tmp/scratch.txt"]],
      arguments: [101: ["claude", "--model", "sonnet"]],
      environments: [101: ["TERM": "xterm-256color", "OPENAI_API_KEY": "secret"]],
      cwds: [101: "/Users/x/project"])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 100, introspector: mock)

    let descendants = detector.collectDescendants(of: 100, depth: 0)
    XCTAssertEqual(descendants.count, 1)
    let agent = detector.findAgent(in: descendants)
    XCTAssertEqual(agent?.name, .claude)
    XCTAssertEqual(agent?.sessionId, sessionId)
    XCTAssertEqual(agent?.jsonlPath, jsonlPath)
    XCTAssertEqual(agent?.wasRunningAtQuit, true)
    XCTAssertEqual(agent?.argv, ["claude", "--model", "sonnet"])
    XCTAssertEqual(agent?.env, ["TERM": "xterm-256color"])
    XCTAssertEqual(agent?.cwd, "/Users/x/project")
  }

  func testFindAgentMatchesVersionedClaudeExecutableByInvocationArgv() {
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0013"
    let jsonlPath =
      "/Users/x/.claude/projects/proj/\(sessionId).jsonl"
    let mock = MockIntrospector(
      children: [120: [(121, "2.1.143")]],
      openVnodes: [121: [jsonlPath]],
      arguments: [121: ["claude", "--chrome", "--dangerously-skip-permissions"]],
      cwds: [121: "/Users/x/project"])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 120, introspector: mock)

    let agent = detector.findAgent(in: detector.collectDescendants(of: 120, depth: 0))
    XCTAssertEqual(agent?.name, .claude)
    XCTAssertEqual(agent?.sessionId, sessionId)
    XCTAssertEqual(agent?.argv, ["claude", "--chrome", "--dangerously-skip-permissions"])
    XCTAssertEqual(agent?.cwd, "/Users/x/project")
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

  func testFindAgentFallsBackToNewestClaudeJSONLForProcessCwd() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-claude-detect-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let projects = base.appendingPathComponent("projects", isDirectory: true)
    let cwd = "/Users/x/project.with.dot"
    let project = projects.appendingPathComponent(
      ClaudeSessionLogLocator.encodedProjectName(for: cwd), isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let oldId = "0fa31a8c-1234-5678-9abc-deadbeef0007"
    let newId = "0fa31a8c-1234-5678-9abc-deadbeef0008"
    let oldURL = project.appendingPathComponent("\(oldId).jsonl")
    let newURL = project.appendingPathComponent("\(newId).jsonl")
    try Data("old\n".utf8).write(to: oldURL)
    try Data("new\n".utf8).write(to: newURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: oldURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newURL.path)

    setenv("CLAUDE_CONFIG_DIR", base.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    let resolvedNewPath = try XCTUnwrap(ClaudeSessionLogLocator.newestSessionLog(cwd: cwd))

    let mock = MockIntrospector(
      children: [350: [(351, "claude")]],
      openVnodes: [351: []],
      arguments: [351: ["claude", "--chrome"]],
      cwds: [351: cwd])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 350, introspector: mock)

    let agent = detector.findAgent(in: detector.collectDescendants(of: 350, depth: 0))
    XCTAssertEqual(agent?.name, .claude)
    XCTAssertEqual(agent?.sessionId, newId)
    XCTAssertEqual(agent?.jsonlPath, resolvedNewPath)
    XCTAssertEqual(agent?.argv, ["claude", "--chrome"])
    XCTAssertEqual(agent?.cwd, cwd)
  }

  func testDetectFallsBackToRecentClaudeJSONLForShellCwdWithoutLiveAgent() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-claude-shell-fallback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let projects = base.appendingPathComponent("projects", isDirectory: true)
    let cwd = "/Users/x/project"
    let project = projects.appendingPathComponent(
      ClaudeSessionLogLocator.encodedProjectName(for: cwd), isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let staleId = "0fa31a8c-1234-5678-9abc-deadbeef0010"
    let recentId = "0fa31a8c-1234-5678-9abc-deadbeef0011"
    let staleURL = project.appendingPathComponent("\(staleId).jsonl")
    let recentURL = project.appendingPathComponent("\(recentId).jsonl")
    try Data("stale\n".utf8).write(to: staleURL)
    try Data(
      """
      {"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"\(recentId)"}
      {"type":"assistant","advisorModel":"claude-opus-4-7","cwd":"\(cwd)","sessionId":"\(recentId)"}

      """.utf8
    ).write(to: recentURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: staleURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 150)], ofItemAtPath: recentURL.path)

    setenv("CLAUDE_CONFIG_DIR", base.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }

    let mock = MockIntrospector(
      children: [800: []],
      openVnodes: [:],
      environments: [800: ["TERM": "xterm-256color", "ANTHROPIC_API_KEY": "secret"]],
      cwds: [800: cwd])
    let detector = AgentSessionDetector(
      tabId: "t",
      shellPid: 800,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      introspector: mock)

    let agent = detector.detect()
    XCTAssertEqual(agent?.name, .claude)
    XCTAssertEqual(agent?.sessionId, recentId)
    XCTAssertTrue(
      agent?.jsonlPath.hasSuffix("/projects/-Users-x-project/\(recentId).jsonl") ?? false)
    XCTAssertEqual(agent?.wasRunningAtQuit, false)
    XCTAssertEqual(
      agent?.argv, ["claude", "--model", "claude-opus-4-7", "--dangerously-skip-permissions"])
    XCTAssertEqual(agent?.env, ["TERM": "xterm-256color"])
    XCTAssertEqual(agent?.cwd, cwd)
  }

  func testDetectIgnoresStaleClaudeJSONLForShellCwdWithoutLiveAgent() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "laban-claude-stale-shell-fallback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let projects = base.appendingPathComponent("projects", isDirectory: true)
    let cwd = "/Users/x/project"
    let project = projects.appendingPathComponent(
      ClaudeSessionLogLocator.encodedProjectName(for: cwd), isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let staleId = "0fa31a8c-1234-5678-9abc-deadbeef0012"
    let staleURL = project.appendingPathComponent("\(staleId).jsonl")
    try Data("stale\n".utf8).write(to: staleURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: staleURL.path)

    setenv("CLAUDE_CONFIG_DIR", base.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }

    let mock = MockIntrospector(
      children: [810: []],
      openVnodes: [:],
      cwds: [810: cwd])
    let detector = AgentSessionDetector(
      tabId: "t",
      shellPid: 810,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      introspector: mock)

    XCTAssertNil(detector.detect())
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
    XCTAssertEqual(recorder.observations.last??.jsonlPath, jsonlPath)
  }

  func testFinalObserveDoesNotDemoteKnownLiveAgentOnSingleMiss() {
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0014"
    let jsonlPath = "/Users/x/.claude/projects/p/\(sessionId).jsonl"

    let mock = MockIntrospector(
      children: [900: [(901, "claude")]],
      openVnodes: [901: [jsonlPath]])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 900, introspector: mock)
    let recorder = Recorder()
    detector.observer = recorder

    detector.handleObservation(detector.detect())
    XCTAssertEqual(recorder.observations.count, 1)
    XCTAssertEqual(recorder.observations.last??.wasRunningAtQuit, true)

    // Final app-termination sampling is allowed to miss a live
    // process transiently while libproc walks a changing process tree.
    // That miss must not turn an auto-executed resume into a
    // no-newline prompt prefill on the next launch.
    mock.children = [900: []]
    detector.observeNowPreservingLiveAgentOnMiss()

    XCTAssertEqual(recorder.observations.count, 1)
    XCTAssertEqual(detector.lastObservedAgent?.sessionId, sessionId)
    XCTAssertEqual(detector.lastObservedAgent?.wasRunningAtQuit, true)
  }
}

/// Mock implementation that returns canned descendant trees and
/// per-pid open-fd path lists.
private final class MockIntrospector: ProcessIntrospector {
  var children: [pid_t: [(pid_t, String)]]
  var openVnodes: [pid_t: [String]]
  var arguments: [pid_t: [String]]
  var environments: [pid_t: [String: String]]
  var cwds: [pid_t: String]

  init(
    children: [pid_t: [(pid_t, String)]],
    openVnodes: [pid_t: [String]],
    arguments: [pid_t: [String]] = [:],
    environments: [pid_t: [String: String]] = [:],
    cwds: [pid_t: String] = [:]
  ) {
    self.children = children
    self.openVnodes = openVnodes
    self.arguments = arguments
    self.environments = environments
    self.cwds = cwds
  }

  func children(of parent: pid_t) -> [(pid: pid_t, basename: String)] {
    (children[parent] ?? []).map { (pid: $0.0, basename: $0.1) }
  }
  func openVnodePaths(of pid: pid_t) -> [String] {
    openVnodes[pid] ?? []
  }
  func arguments(of pid: pid_t) -> [String] {
    arguments[pid] ?? []
  }
  func environment(of pid: pid_t) -> [String: String] {
    environments[pid] ?? [:]
  }
  func currentWorkingDirectory(of pid: pid_t) -> String? {
    cwds[pid]
  }
}
