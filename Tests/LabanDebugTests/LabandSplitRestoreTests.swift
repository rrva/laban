import CoreGraphics
import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

final class LabandSplitRestoreTests: XCTestCase {
  func testSplitWorkspaceRestoresFocusedPaneUnderLaband() throws {
    let root = URL(fileURLWithPath: ".artifacts/split-panes/laband-\(UUID().uuidString)")
    let socket = ".tmp/split-\(UUID().uuidString.prefix(8))/s.sock"
    let values = [
      "LABAN_TERMINAL_BACKEND": "laband", "LABAN_LABAND_SOCKET": socket,
      "LABAN_LABAND_BIN": ".build/debug/laband",
    ]
    let old = ProcessInfo.processInfo.environment
    for (key, value) in values { setenv(key, value, 1) }
    defer {
      for key in values.keys { if let v = old[key] { setenv(key, v, 1) } else { unsetenv(key) } }
      try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: socket).deletingLastPathComponent())
    }
    let store = PersistenceStore(baseURL: root.appendingPathComponent("persist"))
    let tree = PaneTree.split(
      axis: .vertical, fraction: 0.5, first: .leaf(sessionId: "left"),
      second: .leaf(sessionId: "right"))
    try store.save(
      WorkspaceState(windows: [
        WindowState(
          id: "headless-window", selectedTabId: "left",
          tabs: [
            TabState(
              id: "left", cwd: NSHomeDirectory(), launchCommand: "/bin/sh", lastActiveAt: Date(),
              panes: tree, focusedSessionId: "right",
              paneStates: ["left", "right"].map {
                PaneState(sessionId: $0, cwd: NSHomeDirectory(), launchCommand: "/bin/sh")
              })
          ])
      ]))
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil, artifactsURL: root, tempURL: nil,
      deterministic: true, runId: "split-laband", sessionMode: .realShell,
      persistenceBaseURL: store.baseURL, restorePersistedState: true)
    defer { runtime.shutdown(terminateRemoteSessions: true) }
    XCTAssertEqual(runtime.model.activeTab?.panes, tree)
    XCTAssertEqual(runtime.model.activeTab?.focusedSessionId, "right")
    _ = runtime.applyAction(Data(#"{"action":"typeText","text":"printf 'FOCUSED\\n'\n"}"#.utf8))
    _ = runtime.wait(
      Data(#"{"timeoutMs":5000,"condition":{"kind":"textVisible","text":"FOCUSED"}}"#.utf8))
    runtime.renderFrameUnlocked()
    XCTAssertTrue(
      runtime.lastFrameCommands.contains { command in
        if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _, _, _) = command {
          return text.contains("Split view is not available on the laband backend")
        }
        return false
      })
    let noticeOrigin = runtime.lastFrameCommands.compactMap { command -> CGFloat? in
      if case .glyphRun(let origin, let text, _, _, _, _, _, _, _, _, _, _, _) = command,
        text.contains("Split view is not available")
      {
        return origin.y
      }
      return nil
    }.first
    XCTAssertGreaterThan(try XCTUnwrap(noticeOrigin), CGFloat(runtime.windowHeight / 2))
    XCTAssertEqual(runtime.model.session(forSessionID: "right")?.id, "right")
    let split = runtime.applyAction(Data(#"{"action":"pane.split"}"#.utf8))
    XCTAssertEqual(split.status, 400)
    XCTAssertTrue(String(decoding: split.body, as: UTF8.self).contains("unsupportedBackend"))
  }
}
