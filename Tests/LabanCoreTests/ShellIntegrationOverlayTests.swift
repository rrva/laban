import LabanTerminalCore
import XCTest
import os

@testable import LabanCore

/// Milestone 2 of the OSC 133 ExecPlan: the zsh rc-overlay makes a *real*
/// zsh emit the markers, and `ShellIntegrationState` reflects real
/// prompt/command/exit transitions. Pure-content checks plus an end-to-end
/// test that spawns `/bin/zsh` under the overlay.
final class ShellIntegrationOverlayTests: XCTestCase {

  // MARK: - Pure overlay generation

  func testClassifyHandlesLoginDashAndPath() {
    XCTAssertEqual(ShellIntegrationOverlay.Shell.classify(path: "/bin/zsh"), .zsh)
    XCTAssertEqual(ShellIntegrationOverlay.Shell.classify(path: "-zsh"), .zsh)
    XCTAssertEqual(ShellIntegrationOverlay.Shell.classify(path: "/usr/bin/bash"), .bash)
    XCTAssertEqual(ShellIntegrationOverlay.Shell.classify(path: "/opt/fish"), .fish)
    XCTAssertEqual(ShellIntegrationOverlay.Shell.classify(path: "/bin/sh"), .other)
  }

  func testInstallZshWritesFilesAndReturnsZdotdir() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let overrides = try ShellIntegrationOverlay.install(
      shellPath: "/bin/zsh",
      baseDirectory: base,
      environment: ["ZDOTDIR": "/home/u/.config/zsh"])

    let overlayDir = base.appendingPathComponent("zsh")
    XCTAssertEqual(overrides["ZDOTDIR"], overlayDir.path)
    XCTAssertEqual(overrides["LABAN_REAL_ZDOTDIR"], "/home/u/.config/zsh")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: overlayDir.appendingPathComponent(".zshenv").path))
    let hook = try String(
      contentsOf: overlayDir.appendingPathComponent("laban-integration.zsh"), encoding: .utf8)
    XCTAssertTrue(hook.contains("133;A"))
    XCTAssertTrue(hook.contains("133;C"))
    XCTAssertTrue(hook.contains("133;D"))
  }

  func testInstallNonZshReturnsNoOverrides() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let overrides = try ShellIntegrationOverlay.install(
      shellPath: "/bin/bash", baseDirectory: base, environment: [:])
    XCTAssertTrue(overrides.isEmpty)
  }

  func testInstallOmitsRealZdotdirWhenAbsent() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let overrides = try ShellIntegrationOverlay.install(
      shellPath: "/bin/zsh", baseDirectory: base, environment: [:])
    XCTAssertNil(overrides["LABAN_REAL_ZDOTDIR"])
  }

  // MARK: - End-to-end: real zsh emits markers through the overlay

  func testRealZshEmitsExitCodeThroughOverlay() throws {
    let zsh = "/bin/zsh"
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: zsh), "zsh not available")

    let base = try makeTempDir()
    let home = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: home)
    }

    // Hermetic: empty real config (no ZDOTDIR override -> overlay falls back
    // to $HOME, which we point at an empty temp dir).
    var overrides = try ShellIntegrationOverlay.install(
      shellPath: zsh, baseDirectory: base, environment: [:])
    overrides["HOME"] = home.path
    overrides["TERM"] = "xterm-256color"

    let session = try makeZshSession(executable: zsh, environment: overrides)
    let dirty = OSAllocatedUnfairLock(initialState: 0)
    guard let runner = session.makeRunner(onDirty: { dirty.withLock { $0 += 1 } }) else {
      XCTFail("makeRunner returned nil")
      return
    }
    runner.start()
    defer {
      _ = session.write(Array("exit\n".utf8))
      runner.stop()
      session.close()
    }

    // Wait for the first prompt: precmd fires A -> atPrompt.
    XCTAssertTrue(
      waitUntil(2.0) { session.shellIntegrationState().phase != .idle },
      "shell never reached a prompt phase (phase stayed idle)")

    // Run a command that exits non-zero. The next precmd emits D;1 then A.
    _ = session.write(Array("false\n".utf8))

    XCTAssertTrue(
      waitUntil(5.0) { session.shellIntegrationState().lastExitCode == 1 },
      "shell never reported exit code 1 (state=\(session.shellIntegrationState()))")
  }

  // MARK: - Helpers

  private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-overlay-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Build an interactive+login real zsh session via the C API (the public
  /// factory does not take an explicit executable/argv).
  private func makeZshSession(executable: String, environment: [String: String]) throws -> Session {
    var cfg = LabanLaunchConfig()
    cfg.fixture_mode = 0
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80

    let exe = strdup(executable)!
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup("zsh"), strdup("-i"), strdup("-l"), nil]
    var envEntries = environment.map { strdup("\($0.key)=\($0.value)") }
    envEntries.append(nil)
    let argvCount = argv.count
    let envCount = envEntries.count
    defer {
      free(exe)
      for p in argv where p != nil { free(p) }
      for p in envEntries where p != nil { free(p) }
    }

    return try argv.withUnsafeMutableBufferPointer { argvBuf -> Session in
      try argvBuf.baseAddress!.withMemoryRebound(
        to: UnsafePointer<CChar>?.self, capacity: argvCount
      ) { argvRebound in
        try envEntries.withUnsafeMutableBufferPointer { envBuf -> Session in
          try envBuf.baseAddress!.withMemoryRebound(
            to: UnsafePointer<CChar>?.self, capacity: envCount
          ) { envRebound in
            cfg.executable = UnsafePointer(exe)
            cfg.argv = UnsafePointer(argvRebound)
            cfg.envp = UnsafePointer(envRebound)
            return try Session(config: &cfg, size: size)
          }
        }
      }
    }
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
  }
}
