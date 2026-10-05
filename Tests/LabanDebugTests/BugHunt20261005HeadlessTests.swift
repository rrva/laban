import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

/// Reproductions for findings in docs/quality/bug-hunt-handoff-2026-10-05.md.
/// Each `testBug<N>_` test asserts the correct behavior inside
/// `XCTExpectFailure`, so the suite stays green while the defect exists and
/// turns red ("expected failure but none occurred") once it is fixed — at which
/// point drop the XCTExpectFailure wrapper and keep the test as a regression.
final class BugHunt20261005HeadlessTests: XCTestCase {

  // MARK: - #5 headless reattach never acquires the laband lease

  func testBug5_reattachedLabandSessionAcceptsTypedInput() throws {
    let runId = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: ".artifacts/bughunt-5-\(runId)")
    let socketDir = ".tmp/bh5-\(runId)"
    let socket = "\(socketDir)/s.sock"
    let values = [
      "LABAN_TERMINAL_BACKEND": "laband",
      "LABAN_LABAND_SOCKET": socket,
      "LABAN_LABAND_BIN": ".build/debug/laband",
      "LABAN_LABAND_SESSION_COMMAND": "stty raw -echo; exec cat -v",
    ]
    let old = ProcessInfo.processInfo.environment
    for (key, value) in values { setenv(key, value, 1) }
    var daemonPid: pid_t = 0
    defer {
      for key in values.keys { if let v = old[key] { setenv(key, v, 1) } else { unsetenv(key) } }
      if daemonPid > 0 { kill(daemonPid, SIGTERM) }
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketDir))
      try? FileManager.default.removeItem(at: root)
    }
    let persist = root.appendingPathComponent("persist")

    // First runtime creates the session (and so holds its lease), proves input
    // lands, then detaches without terminating the daemon session.
    let first = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: root.appendingPathComponent("a"), tempURL: nil,
      deterministic: true, runId: "bh5-a", sessionMode: .realShell,
      persistenceBaseURL: persist, restorePersistedState: true)
    daemonPid = first.labandProcess?.processIdentifier ?? 0
    let sessionId = try XCTUnwrap(first.model.activeTab?.focusedSessionId)
    let typedFirst = first.applyAction(Data(#"{"action":"typeText","text":"ONE"}"#.utf8))
    XCTAssertEqual(typedFirst.status, 200, "precondition: creator can type")
    XCTAssertTrue(waitText(first, "ONE"), "precondition: creator input reaches the child")
    first.persistenceCoordinator?.flushSync()
    first.shutdown(terminateRemoteSessions: false)

    // Second runtime restores the same tab and reattaches to the live session.
    let second = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: root.appendingPathComponent("b"), tempURL: nil,
      deterministic: true, runId: "bh5-b", sessionMode: .realShell,
      persistenceBaseURL: persist, restorePersistedState: true)
    defer { second.shutdown(terminateRemoteSessions: true) }
    XCTAssertEqual(
      second.model.activeTab?.focusedSessionId, sessionId,
      "precondition: second runtime restored the same logical session")
    XCTAssertTrue(waitText(second, "ONE"), "precondition: reattach shows the live session")

    let typed = second.applyAction(Data(#"{"action":"typeText","text":"TWO"}"#.utf8))
    XCTExpectFailure("Bug #5: headless attach never transfers the lease -> leaseRequired") {
      XCTAssertEqual(
        typed.status, 200,
        "typeText on a reattached session must succeed; body: "
          + String(decoding: typed.body, as: UTF8.self))
    }
  }

  // MARK: - Helpers

  private func makeRuntime(_ name: String) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-\(name)-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: artifacts, tempURL: nil,
      deterministic: true, runId: name)
    return (runtime, artifacts)
  }

  private func feed(_ runtime: HeadlessDebugRuntime, _ text: String) {
    let data = try! JSONSerialization.data(withJSONObject: ["action": "feedOutput", "text": text])
    XCTAssertEqual(runtime.applyAction(data).status, 200)
  }

  private func select(_ runtime: HeadlessDebugRuntime) {
    let body = #"{"action":"setSelection","anchor":{"row":0,"col":0},"focus":{"row":0,"col":4}}"#
    XCTAssertEqual(runtime.applyAction(Data(body.utf8)).status, 200)
  }

  private func waitText(_ runtime: HeadlessDebugRuntime, _ text: String) -> Bool {
    let response = runtime.wait(
      try! JSONSerialization.data(withJSONObject: [
        "timeoutMs": 5_000, "condition": ["kind": "textVisible", "text": text],
      ]))
    return (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["ok"]
      as? Bool == true
  }
}
