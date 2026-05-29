import Darwin
import Foundation
import XCTest

@testable import LabanDebug

/// Regression for focus reporting (DEC private mode 1004) over the daemon tier.
/// The app's `reportFocus` (and the headless `windowFocus` action) called
/// `sendFocus` on the local Session, which in fixture mode — the labpty/laband
/// tier — only encodes and then drops the bytes. So a focus-aware app like Claude
/// Code running over the daemon never received CSI I / CSI O on window focus
/// changes. Same shape as the paste (`ecd12cc`) and mouse-forwarding fixes: the
/// fix forwards the encoded focus bytes to the daemon's PTY via the terminal
/// client.
///
/// Drives the laband backend with a raw `cat -v` child that echoes its input with
/// control chars made visible. `feedOutput` enables mode 1004 on the local session
/// VT (so focus reporting is active); a `windowFocus` action must then deliver
/// CSI I to the daemon — the snapshot shows the echoed `^[[I`. Before the fix this
/// times out (the encoded focus bytes are dropped); after it, it passes.
final class HeadlessFocusRoutingTests: XCTestCase {

  func testHeadlessFocusInReachesChildOverLabandBackend() throws {
    let socketDir = ".tmp/focus-routing-laband-\(UUID().uuidString)"
    let socketPath = "\(socketDir)/laband.sock"
    try withEnvironment([
      "LABAN_TERMINAL_BACKEND": "laband",
      "LABAN_LABAND_SOCKET": socketPath,
      "LABAN_LABAND_BIN": ".build/debug/laband",
      "LABAN_LABAND_SESSION_COMMAND": "stty raw -echo; exec cat -v",
    ]) {
      let runtime = try makeRuntime(runId: "focus-routing-laband")
      defer {
        runtime.shutdown(terminateRemoteSessions: true)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketDir))
      }

      // Enable focus reporting (mode 1004) on the local session VT so the
      // windowFocus action actually emits CSI I.
      let feed = runtime.applyAction(
        try JSONSerialization.data(withJSONObject: [
          "action": "feedOutput", "text": "\u{1b}[?1004h",
        ]))
      XCTAssertEqual(feed.status, 200, "feedOutput must succeed")

      let focus = runtime.applyAction(
        try JSONSerialization.data(withJSONObject: [
          "action": "windowFocus", "focused": true,
        ]))
      XCTAssertEqual(focus.status, 200, "windowFocus action must succeed")

      // `cat -v` renders the forwarded CSI I (focus-in) as the literal text ^[[I.
      // Seeing `[I` proves the encoded focus bytes traversed the daemon's PTY; a
      // timeout means they were dropped — the bug this test guards.
      try waitForText(
        runtime, "[I",
        message: "child must receive the forwarded focus-in (CSI I) over the daemon PTY")
    }
  }

  // MARK: - Harness

  private func makeRuntime(runId: String) throws -> HeadlessDebugRuntime {
    let artifacts = URL(fileURLWithPath: ".artifacts/runs/\(runId)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    return try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: runId,
      sessionMode: .realShell
    )
  }

  private func waitForText(
    _ runtime: HeadlessDebugRuntime, _ text: String, message: String
  ) throws {
    let response = runtime.wait(
      try JSONSerialization.data(
        withJSONObject: [
          "timeoutMs": 5_000,
          "condition": ["kind": "textVisible", "text": text],
        ]))
    let waited = try XCTUnwrap(
      JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertEqual(waited["ok"] as? Bool, true, message)
  }

  private func withEnvironment<T>(
    _ values: [String: String],
    _ body: () throws -> T
  ) throws -> T {
    var previous: [String: String?] = [:]
    for key in values.keys {
      previous[key] = ProcessInfo.processInfo.environment[key]
    }
    for (key, value) in values {
      setenv(key, value, 1)
    }
    defer {
      for (key, value) in previous {
        if let value {
          setenv(key, value, 1)
        } else {
          unsetenv(key)
        }
      }
    }
    return try body()
  }
}
