import Darwin
import Foundation
import XCTest

@testable import LabanDebug

final class LabandHeadlessBackendTests: XCTestCase {
  func testHeadlessBackendsExposeSelectedTransportAndDaemonIdentity() throws {
    try withEnvironment(["LABAN_TERMINAL_BACKEND": "in-process"]) {
      let runtime = try makeRuntime(runId: "laband-headless-in-process")
      defer { runtime.shutdown() }

      let sessions = try jsonObject(runtime.sessions())["sessions"] as? [[String: Any]]
      XCTAssertEqual(sessions?.first?["transportMode"] as? String, "in-process")
      XCTAssertFalse((sessions?.first?["logicalSessionId"] as? String ?? "").isEmpty)
    }

    let socketPath = ".tmp/laband-headless-\(UUID().uuidString)/laband.sock"
    try withEnvironment([
      "LABAN_TERMINAL_BACKEND": "laband",
      "LABAN_LABAND_SOCKET": socketPath,
      "LABAN_LABAND_BIN": ".build/debug/laband",
    ]) {
      let runtime = try makeRuntime(runId: "laband-headless-laband")
      defer {
        runtime.shutdown()
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
      }

      try type(runtime, "laband-headless-ok\n")
      let waited = try jsonObject(
        runtime.wait(
          try JSONSerialization.data(
            withJSONObject: [
              "timeoutMs": 5_000,
              "condition": [
                "kind": "textVisible",
                "text": "laband-headless-ok",
              ],
            ])))
      XCTAssertEqual(waited["ok"] as? Bool, true)

      let sessions = try XCTUnwrap(jsonObject(runtime.sessions())["sessions"] as? [[String: Any]])
      let first = try XCTUnwrap(sessions.first)
      XCTAssertEqual(first["transportMode"] as? String, "laband")
      XCTAssertGreaterThan(first["daemonProcessPid"] as? Int ?? 0, 0)
      XCTAssertFalse((first["logicalSessionId"] as? String ?? "").isEmpty)
      XCTAssertFalse((first["incarnationId"] as? String ?? "").isEmpty)
    }
  }

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

  private func type(_ runtime: HeadlessDebugRuntime, _ text: String) throws {
    let response = runtime.applyAction(
      try JSONSerialization.data(withJSONObject: ["action": "typeText", "text": text]))
    XCTAssertEqual(response.status, 200)
  }

  private func jsonObject(_ response: DebugResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
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
