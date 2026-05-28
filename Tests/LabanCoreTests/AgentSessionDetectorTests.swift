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

  func testDefaultDetectorCadenceThrottlesIdleChildScans() {
    let detector = AgentSessionDetector(
      tabId: "t",
      shellPid: 1,
      introspector: MockIntrospector(children: [:], openVnodes: [:]))

    switch detector.tickInterval {
    case .seconds(2):
      break
    default:
      XCTFail("default detector cadence should keep idle proc_listpids scans coarse")
    }
    XCTAssertEqual(
      AgentSessionDetector.defaultSessionLogLookupCacheInterval,
      5.0,
      "default Claude log lookup cache should span multiple idle detector ticks")
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
    XCTAssertEqual(mock.argumentCalls[121] ?? 0, 1)
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
    XCTAssertEqual(mock.argumentCalls[301] ?? 0, 0)
    XCTAssertEqual(mock.environmentCalls[301] ?? 0, 0)
  }

  /// Claude Code closes its `.jsonl` while idle, so `openVnodePaths`
  /// only sees the file during writes. The detector must re-acquire
  /// the session id through `newestClaudeSessionLog` in the cwd
  /// while the fd is closed — but only after a prior observation has
  /// established that this shell's descendant actually owned the
  /// jsonl. The seen-jsonl gate (added to keep sibling tabs from
  /// stealing each other's sessions) preserves this in-session
  /// recovery path.
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

    // First sample: claude has the .jsonl open. Detector latches on
    // via openVnodes and records the path as ours.
    let mock = MockIntrospector(
      children: [350: [(351, "claude")]],
      openVnodes: [351: [resolvedNewPath]],
      arguments: [351: ["claude", "--chrome"]],
      cwds: [351: cwd])
    let detector = AgentSessionDetector(
      tabId: "t", shellPid: 350, introspector: mock)
    XCTAssertEqual(
      detector.findAgent(in: detector.collectDescendants(of: 350, depth: 0))?.sessionId,
      newId,
      "first sample must capture the session via the open .jsonl fd")

    // Second sample: claude has closed its .jsonl while idle. The
    // open-vnode path is empty, so findAgent falls back to the cwd's
    // newest log. The seen-jsonl gate lets the prior observation
    // through.
    mock.openVnodes = [351: []]
    let agent = detector.findAgent(in: detector.collectDescendants(of: 350, depth: 0))
    XCTAssertEqual(agent?.name, .claude)
    XCTAssertEqual(agent?.sessionId, newId)
    XCTAssertEqual(agent?.jsonlPath, resolvedNewPath)
    XCTAssertEqual(agent?.argv, ["claude", "--chrome"])
    XCTAssertEqual(agent?.cwd, cwd)
  }

  /// After a Claude descendant exits the detector still needs to
  /// surface its session id so the next launch can `--resume` it.
  /// The shell-cwd fallback recovers from the now-orphan jsonl, but
  /// only after a live observation has marked that jsonl as
  /// belonging to this detector's shell tree (so sibling tabs in the
  /// same repo cannot inherit it).
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
    let resolvedRecentPath = try XCTUnwrap(ClaudeSessionLogLocator.newestSessionLog(cwd: cwd))

    // First sample: claude is alive and holds the recent .jsonl. The
    // detector latches via openVnodes and learns this jsonl belongs
    // to this shell tree.
    let mock = MockIntrospector(
      children: [800: [(801, "claude")]],
      openVnodes: [801: [resolvedRecentPath]],
      environments: [800: ["TERM": "xterm-256color", "ANTHROPIC_API_KEY": "secret"]],
      cwds: [800: cwd, 801: cwd])
    let detector = AgentSessionDetector(
      tabId: "t",
      shellPid: 800,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      introspector: mock)
    XCTAssertEqual(
      detector.detect()?.sessionId,
      recentId,
      "first sample must capture the session via the open .jsonl fd")

    // Second sample: claude has exited. The shell-cwd fallback picks
    // the recent jsonl back up because the detector already knows it
    // belonged to this shell.
    mock.children = [800: []]
    mock.openVnodes = [:]
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

  func testShellCwdClaudeLogLookupIsCachedBriefly() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-claude-shell-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let projects = base.appendingPathComponent("projects", isDirectory: true)
    let cwd = "/Users/x/project"
    let project = projects.appendingPathComponent(
      ClaudeSessionLogLocator.encodedProjectName(for: cwd), isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let firstId = "0fa31a8c-1234-5678-9abc-deadbeef0020"
    let firstURL = project.appendingPathComponent("\(firstId).jsonl")
    try Data("first\n".utf8).write(to: firstURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 150)], ofItemAtPath: firstURL.path)

    setenv("CLAUDE_CONFIG_DIR", base.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    let resolvedFirstPath = try XCTUnwrap(ClaudeSessionLogLocator.newestSessionLog(cwd: cwd))

    // Seed the seen-jsonl set with a live observation so the shell-cwd
    // fallback is allowed to resolve this jsonl post-exit.
    let mock = MockIntrospector(
      children: [820: [(821, "claude")]],
      openVnodes: [821: [resolvedFirstPath]],
      cwds: [820: cwd, 821: cwd])
    let detector = AgentSessionDetector(
      tabId: "t",
      shellPid: 820,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      sessionLogLookupCacheInterval: 60,
      introspector: mock)
    XCTAssertEqual(detector.detect()?.sessionId, firstId)

    // Claude exits. Subsequent samples must rely on the shell-cwd
    // fallback. We exercise it directly to verify the lookup cache.
    mock.children = [820: []]
    mock.openVnodes = [:]
    let first = detector.findRecentClaudeSessionForShellCwd()
    XCTAssertEqual(first?.sessionId, firstId)

    let newerId = "0fa31a8c-1234-5678-9abc-deadbeef0021"
    let newerURL = project.appendingPathComponent("\(newerId).jsonl")
    try Data("newer\n".utf8).write(to: newerURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newerURL.path)

    let second = detector.findRecentClaudeSessionForShellCwd()
    XCTAssertEqual(
      second?.sessionId,
      firstId,
      "same detector should reuse the recent cwd log lookup during the cache interval")
  }

  func testObserveNowBypassesCachedClaudeLogMiss() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-claude-observe-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let cwd = "/Users/x/project"
    let project =
      base
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(
        ClaudeSessionLogLocator.encodedProjectName(for: cwd), isDirectory: true)
    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef0022"
    let logURL = project.appendingPathComponent("\(sessionId).jsonl")

    setenv("CLAUDE_CONFIG_DIR", base.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }

    // Seed the seen-jsonl set via an openVnodes observation. The
    // matcher is regex-only, so the file does not need to exist yet.
    let mock = MockIntrospector(
      children: [830: [(831, "claude")]],
      openVnodes: [831: [logURL.path]],
      cwds: [830: cwd, 831: cwd])
    let detector = AgentSessionDetector(
      tabId: "t",
      shellPid: 830,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      sessionLogLookupCacheInterval: 60,
      introspector: mock)
    XCTAssertEqual(detector.detect()?.sessionId, sessionId)

    // Claude exits before the project directory is created on disk.
    // The shell-cwd fallback fails (no file yet), caching the miss.
    mock.children = [830: []]
    mock.openVnodes = [:]
    XCTAssertNil(detector.detect(), "fallback should cache the missing project directory")

    // The user starts claude again and it materializes the file.
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("fresh\n".utf8).write(to: logURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: logURL.path)

    let recorder = Recorder()
    detector.observer = recorder
    detector.observeNow()

    XCTAssertEqual(recorder.observations.last??.sessionId, sessionId)
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
    XCTAssertEqual(mock.argumentCalls[401] ?? 0, 0)
    XCTAssertEqual(mock.openVnodeCalls[401] ?? 0, 0)
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

  /// Two tabs in the same repo had distinct Claude sessions. Tab A's
  /// claude is alive; tab B's claude has exited (or its jsonl fd is
  /// closed). The cwd-newest fallback used to pick whichever jsonl
  /// was most recently modified — invariably tab A's, because A is
  /// still writing — and would re-attribute tab A's session to tab B.
  /// At restore both tabs prefilled `claude --resume <A's id>` and
  /// collapsed into the same conversation. The detector must instead
  /// refuse to inherit a sibling's session: tab B's detector has no
  /// direct evidence it ever hosted that jsonl, so the fallback
  /// returns nil and tab B persists without a borrowed sessionId.
  func testDetectDoesNotInheritSiblingTabClaudeSessionViaCwdFallback() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "laban-claude-cross-tab-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let cwd = "/Users/x/shared-project"
    let project = base
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(
        ClaudeSessionLogLocator.encodedProjectName(for: cwd), isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let sessionA = "0fa31a8c-1234-5678-9abc-deadbeef00a0"
    let sessionAURL = project.appendingPathComponent("\(sessionA).jsonl")
    try Data("alive\n".utf8).write(to: sessionAURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)],
      ofItemAtPath: sessionAURL.path)

    setenv("CLAUDE_CONFIG_DIR", base.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }

    // Tab A: live claude descendant holding sessionA's jsonl open.
    let mockA = MockIntrospector(
      children: [800: [(801, "claude")]],
      openVnodes: [801: [sessionAURL.path]],
      cwds: [801: cwd])
    let detectorA = AgentSessionDetector(
      tabId: "A",
      shellPid: 800,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      introspector: mockA)
    XCTAssertEqual(detectorA.detect()?.sessionId, sessionA)

    // Tab B: same cwd, no live claude descendant, never observed any
    // jsonl as its own. Without the seen-jsonl gate, B's detector
    // returns sessionA via the cwd-newest fallback because A's jsonl
    // is the only — and therefore newest — log in that project.
    let mockB = MockIntrospector(
      children: [810: []],
      openVnodes: [:],
      cwds: [810: cwd])
    let detectorB = AgentSessionDetector(
      tabId: "B",
      shellPid: 810,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      introspector: mockB)

    XCTAssertNil(
      detectorB.detect(),
      "tab B's detector must not inherit tab A's sessionId via the shared cwd fallback")
  }

  /// Companion to the cross-tab test above: when a detector HAS
  /// previously observed a jsonl through its own descendant's open
  /// fd, the fallback still works after the descendant exits or
  /// closes the file — that's the legitimate "claude just closed its
  /// .jsonl while idle" recovery path. Without this, the seen-jsonl
  /// gate would over-correct and break in-session continuity.
  func testDetectRecoversOwnSessionAfterDescendantExitsViaSeenJsonlSet() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "laban-claude-own-recover-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let cwd = "/Users/x/own-project"
    let project = base
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(
        ClaudeSessionLogLocator.encodedProjectName(for: cwd), isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let sessionId = "0fa31a8c-1234-5678-9abc-deadbeef00b0"
    let logURL = project.appendingPathComponent("\(sessionId).jsonl")
    try Data("own\n".utf8).write(to: logURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)],
      ofItemAtPath: logURL.path)

    setenv("CLAUDE_CONFIG_DIR", base.path, 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }

    let mock = MockIntrospector(
      children: [820: [(821, "claude")]],
      openVnodes: [821: [logURL.path]],
      cwds: [821: cwd, 820: cwd])
    let detector = AgentSessionDetector(
      tabId: "owner",
      shellPid: 820,
      recentSessionCutoff: Date(timeIntervalSince1970: 100),
      introspector: mock)

    XCTAssertEqual(detector.detect()?.sessionId, sessionId)

    // Claude exits. The next sample has no descendant and no open
    // vnode — but the detector knows it previously saw this jsonl
    // owned by this shell, so the shell-cwd fallback may re-confirm
    // the session id.
    mock.children = [820: []]
    mock.openVnodes = [:]
    let recovered = detector.detect()
    XCTAssertEqual(recovered?.sessionId, sessionId)
    XCTAssertEqual(recovered?.wasRunningAtQuit, false)
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
  var childrenCalls: [pid_t: Int] = [:]
  var openVnodeCalls: [pid_t: Int] = [:]
  var argumentCalls: [pid_t: Int] = [:]
  var environmentCalls: [pid_t: Int] = [:]
  var cwdCalls: [pid_t: Int] = [:]

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
    childrenCalls[parent, default: 0] += 1
    return (children[parent] ?? []).map { (pid: $0.0, basename: $0.1) }
  }
  func openVnodePaths(of pid: pid_t) -> [String] {
    openVnodeCalls[pid, default: 0] += 1
    return openVnodes[pid] ?? []
  }
  func arguments(of pid: pid_t) -> [String] {
    argumentCalls[pid, default: 0] += 1
    return arguments[pid] ?? []
  }
  func environment(of pid: pid_t) -> [String: String] {
    environmentCalls[pid, default: 0] += 1
    return environments[pid] ?? [:]
  }
  func currentWorkingDirectory(of pid: pid_t) -> String? {
    cwdCalls[pid, default: 0] += 1
    return cwds[pid]
  }
}
