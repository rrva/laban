import Darwin
import Foundation
import XCTest

@testable import LabanDebug

/// Regression for the mouse-forwarding path (and the live-app handlers it
/// mirrors): the view/debug mouse handlers called `sendMouseCapturingBytes` on
/// the local Session and stopped there. In in-process mode that writes the
/// encoded SGR mouse bytes to the local PTY master (the child receives them). On
/// the daemon-backed (labpty/laband) tier the local Session is fixture-mode, so
/// `sendMouseCapturingBytes` only ENCODES — and the bytes were then dropped,
/// never forwarded to the daemon's PTY. The user-visible symptom was "mouse
/// scroll doesn't work in Claude Code under Laban, but does under iTerm2"; the
/// capture showed encoded wheel events with `pty-input.bin` empty. Same shape as
/// the paste fix in `ecd12cc`. The fix forwards the encoded bytes to the daemon
/// via the terminal client, exactly like paste/keys.
///
/// This drives the laband backend with a `cat -v` child in raw mode (so each
/// forwarded byte is echoed back immediately with control chars made visible).
/// `feedOutput` enables SGR mouse tracking on the *local* session VT so the
/// `mouseWheel` action takes the forward path; the snapshot must then contain the
/// echoed wheel sequence (`[<64;`), proving the bytes reached the daemon's child.
/// Before the fix this times out (the encoded bytes are dropped); after it, it
/// passes.
final class HeadlessMouseRoutingTests: XCTestCase {

  func testHeadlessMouseWheelReachesChildOverLabandBackend() throws {
    let socketDir = ".tmp/mouse-routing-laband-\(UUID().uuidString)"
    let socketPath = "\(socketDir)/laband.sock"
    try withEnvironment([
      "LABAN_TERMINAL_BACKEND": "laband",
      "LABAN_LABAND_SOCKET": socketPath,
      "LABAN_LABAND_BIN": ".build/debug/laband",
      // Raw + no echo so `cat -v` emits each forwarded byte immediately (mouse
      // sequences carry no trailing newline, so canonical mode never flushes).
      "LABAN_LABAND_SESSION_COMMAND": "stty raw -echo; exec cat -v",
    ]) {
      let runtime = try makeRuntime(runId: "mouse-routing-laband")
      defer {
        runtime.shutdown(terminateRemoteSessions: true)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketDir))
      }

      // Enable SGR mouse tracking on the local session VT so the mouseWheel
      // action takes the forward (sendTrackedWheel) path and encodes as SGR.
      let feed = runtime.applyAction(
        try JSONSerialization.data(withJSONObject: [
          "action": "feedOutput",
          "text": "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h",
        ]))
      XCTAssertEqual(feed.status, 200, "feedOutput must succeed")

      let wheel = runtime.applyAction(
        try JSONSerialization.data(
          withJSONObject: ["action": "mouseWheel", "x": 400, "y": 200, "deltaY": 3]))
      XCTAssertEqual(wheel.status, 200, "mouseWheel action must succeed")

      // `cat -v` renders the forwarded wheel-up sequence ESC[<64;col;rowM as the
      // literal text ^[[<64;col;rowM. Seeing `[<64;` proves the encoded mouse
      // bytes traversed the daemon's PTY. If this times out, the encoded wheel
      // was dropped instead of forwarded — the bug this test guards.
      try waitForText(
        runtime, "[<64;",
        message: "child must receive the forwarded SGR wheel event over the daemon PTY")
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
