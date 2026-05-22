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

    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/bin/zsh",
      baseDirectory: base,
      environment: ["ZDOTDIR": "/home/u/.config/zsh"])

    let overlayDir = base.appendingPathComponent("zsh")
    XCTAssertEqual(launch.environmentOverrides["ZDOTDIR"], overlayDir.path)
    XCTAssertEqual(launch.environmentOverrides["LABAN_REAL_ZDOTDIR"], "/home/u/.config/zsh")
    XCTAssertNil(launch.argv)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: overlayDir.appendingPathComponent(".zshenv").path))
    let hook = try String(
      contentsOf: overlayDir.appendingPathComponent("laban-integration.zsh"), encoding: .utf8)
    XCTAssertTrue(hook.contains("133;A"))
    XCTAssertTrue(hook.contains("133;C"))
    XCTAssertTrue(hook.contains("133;D"))
  }

  func testInstallNonShellReturnsPassthrough() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/bin/sh", baseDirectory: base, environment: [:])
    XCTAssertEqual(launch, .passthrough)
  }

  func testInstallOmitsRealZdotdirWhenAbsent() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/bin/zsh", baseDirectory: base, environment: [:])
    XCTAssertNil(launch.environmentOverrides["LABAN_REAL_ZDOTDIR"])
  }

  func testInstallBashReturnsRcfileArgv() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/bin/bash", baseDirectory: base, environment: [:])
    XCTAssertTrue(launch.environmentOverrides.isEmpty)
    let argv = try XCTUnwrap(launch.argv)
    XCTAssertEqual(argv.first, "/bin/bash")
    XCTAssertTrue(argv.contains("--rcfile"))
    XCTAssertTrue(argv.contains("-i"))
    let rcPath = argv[2]
    let rc = try String(contentsOfFile: rcPath, encoding: .utf8)
    XCTAssertTrue(rc.contains(".bash_profile"))
    let hook = try String(
      contentsOf: base.appendingPathComponent("bash/laban-integration.bash"), encoding: .utf8)
    XCTAssertTrue(hook.contains("133;C"))
    XCTAssertTrue(hook.contains("PROMPT_COMMAND"))
  }

  func testInstallFishPrependsXdgDataDirs() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/opt/homebrew/bin/fish", baseDirectory: base,
      environment: ["XDG_DATA_DIRS": "/existing/share"])
    XCTAssertNil(launch.argv)
    let dataDirs = try XCTUnwrap(launch.environmentOverrides["XDG_DATA_DIRS"])
    XCTAssertTrue(dataDirs.hasSuffix(":/existing/share"))
    XCTAssertTrue(dataDirs.hasPrefix(base.appendingPathComponent("fish-data").path))
    let hook = try String(
      contentsOf: base.appendingPathComponent(
        "fish-data/fish/vendor_conf.d/laban-integration.fish"),
      encoding: .utf8)
    XCTAssertTrue(hook.contains("fish_postexec"))
    XCTAssertTrue(hook.contains("133;D"))
  }

  func testInstallFishDefaultsXdgDataDirsWhenAbsent() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/usr/bin/fish", baseDirectory: base, environment: [:])
    let dataDirs = try XCTUnwrap(launch.environmentOverrides["XDG_DATA_DIRS"])
    XCTAssertTrue(dataDirs.hasSuffix(":/usr/local/share:/usr/share"))
  }

  // MARK: - End-to-end: real shells emit markers through the overlay

  func testRealZshEmitsExitCodeThroughOverlay() throws {
    // zsh production launch uses login+tty interactivity; force -i -l here so
    // the test executable is zsh regardless of the test runner's $SHELL.
    // argv[0] must be the executable path (the C layer execs it directly).
    try runExitCodeTest(shellPath: "/bin/zsh", interactiveArgv: ["/bin/zsh", "-i", "-l"])
  }

  func testRealBashEmitsExitCodeThroughOverlay() throws {
    // bash uses the overlay's own --rcfile argv (interactive, non-login).
    try runExitCodeTest(shellPath: "/bin/bash", interactiveArgv: nil)
  }

  func testRealFishEmitsExitCodeThroughOverlay() throws {
    let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
    try XCTSkipUnless(fish != nil, "fish not installed")
    try runExitCodeTest(shellPath: fish!, interactiveArgv: [fish!, "-i"])
  }

  /// Install the overlay for `shellPath`, spawn the real shell with a
  /// hermetic HOME, run `false`, and assert the shell reports exit code 1
  /// through OSC 133. `interactiveArgv` forces a specific executable +
  /// interactivity for shells whose overlay does not set argv (zsh, fish);
  /// pass `nil` to use the overlay's own argv (bash).
  private func runExitCodeTest(shellPath: String, interactiveArgv: [String]?) throws {
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: shellPath), "\(shellPath) not available")

    let base = try makeTempDir()
    let home = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: home)
    }

    // Hermetic: empty real config under a temp HOME.
    let launch = try ShellIntegrationOverlay.install(
      shellPath: shellPath, baseDirectory: base, environment: [:])
    var env = launch.environmentOverrides
    env["HOME"] = home.path
    env["TERM"] = "xterm-256color"

    let session = try Session.realShell(
      size: size24x80, environment: env, launchArgv: interactiveArgv ?? launch.argv)
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

    XCTAssertTrue(
      waitUntil(3.0) { session.shellIntegrationState().phase != .idle },
      "\(shellPath) never reached a prompt phase (phase stayed idle)")

    _ = session.write(Array("false\n".utf8))

    XCTAssertTrue(
      waitUntil(5.0) { session.shellIntegrationState().lastExitCode == 1 },
      "\(shellPath) never reported exit code 1 (state=\(session.shellIntegrationState()))")
  }

  // MARK: - Helpers

  private var size24x80: LabanTerminalSize {
    var s = LabanTerminalSize()
    s.rows = 24
    s.cols = 80
    return s
  }

  private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-overlay-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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
