import Darwin
import Foundation
import XCTest

@testable import LabanDebug

/// Regression for the headless paste path:
/// `DebugClipboardActions.paste()` was calling
/// `writePasteCapturingBytes` on the local Session unconditionally.
/// In headless+in-process mode that path writes to the local PTY
/// master (correct — the shell child receives the input). In
/// headless+laband mode the local Session is fixture-mode, so the
/// same call fed the encoded paste into the fixture VT, making it
/// visible in the local grid while the daemon's child never
/// received it. Scripted tests that pasted into a laband session
/// would see the paste content in snapshots but the shell was
/// otherwise idle — a silent dead end for automated paste
/// reproduction over the laband backend, and the same shape of bug
/// as the live-app `12cc18d` fix.
///
/// This test exercises the headless paste action against both
/// backends with `/bin/cat`. After setClipboardText + paste, the
/// snapshot must contain the pasted text via the daemon's echo,
/// proving the bytes actually reached the child.
final class HeadlessPasteRoutingTests: XCTestCase {

  func testHeadlessPasteReachesChildOverInProcessBackend() throws {
    try withEnvironment([
      "LABAN_TERMINAL_BACKEND": "in-process",
      "LABAN_SESSION_COMMAND": "/bin/cat",
    ]) {
      let runtime = try makeRuntime(runId: "paste-routing-in-process")
      defer { runtime.shutdown() }
      try setClipboard(runtime, "headless-paste-inproc\n")
      try pasteAndWait(runtime, "headless-paste-inproc")
    }
  }

  func testHeadlessPasteReachesChildOverLabandBackend() throws {
    let socketPath = ".tmp/paste-routing-laband-\(UUID().uuidString)/laband.sock"
    try withEnvironment([
      "LABAN_TERMINAL_BACKEND": "laband",
      "LABAN_LABAND_SOCKET": socketPath,
      "LABAN_LABAND_BIN": ".build/debug/laband",
      "LABAN_LABAND_SESSION_COMMAND": "/bin/cat",
    ]) {
      let runtime = try makeRuntime(runId: "paste-routing-laband")
      defer {
        runtime.shutdown(terminateRemoteSessions: true)
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
      }
      try setClipboard(runtime, "headless-paste-laband\n")
      try pasteAndWait(runtime, "headless-paste-laband")
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

  private func setClipboard(_ runtime: HeadlessDebugRuntime, _ text: String) throws {
    let response = runtime.applyAction(
      try JSONSerialization.data(
        withJSONObject: ["action": "setClipboardText", "text": text]))
    XCTAssertEqual(response.status, 200, "setClipboardText must succeed")
  }

  private func pasteAndWait(_ runtime: HeadlessDebugRuntime, _ expected: String) throws {
    let pasteResponse = runtime.applyAction(
      try JSONSerialization.data(withJSONObject: ["action": "paste"]))
    XCTAssertEqual(pasteResponse.status, 200, "paste action must succeed")

    // /bin/cat echoes the input back. Wait for the echoed text to
    // appear in the snapshot — that's proof the bytes traversed the
    // child's stdin → stdout, not just landed in a local VT buffer.
    let waitResponse = runtime.wait(
      try JSONSerialization.data(
        withJSONObject: [
          "timeoutMs": 5_000,
          "condition": [
            "kind": "textVisible",
            "text": expected,
          ],
        ]))
    let waited =
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: waitResponse.body) as? [String: Any])
    XCTAssertEqual(
      waited["ok"] as? Bool, true,
      "child must echo the paste back; if this times out the paste never reached the daemon's PTY")
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
