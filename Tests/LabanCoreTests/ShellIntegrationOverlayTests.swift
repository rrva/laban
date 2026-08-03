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
    // rcfile falls back to ~/.bashrc when no profile file exists.
    XCTAssertTrue(rc.contains(".bashrc"))
    let hook = try String(
      contentsOf: base.appendingPathComponent("bash/laban-integration.bash"), encoding: .utf8)
    // bash uses PROMPT_COMMAND for A + D; it deliberately has no DEBUG trap
    // and no `C` marker (see bashHookScript docs).
    XCTAssertTrue(hook.contains("133;A"))
    XCTAssertTrue(hook.contains("133;D"))
    XCTAssertFalse(hook.contains("133;C"), "bash must not emit C (no DEBUG trap)")
    XCTAssertFalse(hook.contains("trap "), "bash must not install a DEBUG trap")
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
    // A parent Laban shell exports this marker. The overlay must still install
    // hooks in child shells instead of treating inherited state as already
    // installed in the new process.
    env["LABAN_SHELL_INTEGRATION"] = "1"

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

  // MARK: - Self-healing provider

  /// The overlay lives in a per-process temp dir that external cleanup can
  /// delete while the app keeps running. A spawn carrying the stale ZDOTDIR
  /// then makes zsh skip the user's .zshrc entirely. The provider must
  /// reinstall the overlay at spawn time.
  func testProviderReinstallsAfterOverlayDeletion() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let provider = ShellIntegrationOverlayProvider(
      shellPath: "/bin/zsh", baseDirectory: base, environment: [:])
    let launch = provider.currentLaunch()
    let overlayDir = base.appendingPathComponent("zsh", isDirectory: true)
    XCTAssertEqual(launch.environmentOverrides["ZDOTDIR"], overlayDir.path)

    try FileManager.default.removeItem(at: overlayDir)

    let healed = provider.currentLaunch()
    XCTAssertEqual(healed.environmentOverrides["ZDOTDIR"], overlayDir.path)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: overlayDir.appendingPathComponent(".zshenv").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: overlayDir.appendingPathComponent("laban-integration.zsh").path))
  }

  /// Partial cleanup (hook file gone, .zshenv present) also heals: the
  /// surviving .zshenv would source a missing hook and silently drop
  /// integration.
  func testProviderReinstallsAfterPartialDeletion() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let provider = ShellIntegrationOverlayProvider(
      shellPath: "/bin/bash", baseDirectory: base, environment: [:])
    _ = provider.currentLaunch()
    let hook = base.appendingPathComponent("bash/laban-integration.bash")
    try FileManager.default.removeItem(at: hook)

    _ = provider.currentLaunch()
    XCTAssertTrue(FileManager.default.fileExists(atPath: hook.path))
  }

  /// A shell without an overlay never gains one, and deleting the base dir
  /// is a no-op.
  func testProviderPassthroughForNonShell() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }

    let provider = ShellIntegrationOverlayProvider(
      shellPath: "/bin/sh", baseDirectory: base, environment: [:])
    try FileManager.default.removeItem(at: base)
    XCTAssertEqual(provider.currentLaunch(), .passthrough)
  }

  /// End-to-end regression for the reported bug: the overlay dir is deleted
  /// *after* install but *before* the spawn (the long-running-app case).
  /// The next spawn must heal the overlay, so the real zsh still sources
  /// the user's .zshrc (observed via a sentinel file the .zshrc creates)
  /// and still emits OSC 133 markers.
  func testRealZshSourcesUserConfigAfterOverlayDeletion() throws {
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: "/bin/zsh"), "/bin/zsh not available")

    let base = try makeTempDir()
    let home = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: base)
      try? FileManager.default.removeItem(at: home)
    }
    let sentinel = home.appendingPathComponent("laban-rc-sentinel")
    try "touch \"$HOME/laban-rc-sentinel\"\n".write(
      to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    let provider = ShellIntegrationOverlayProvider(
      shellPath: "/bin/zsh", baseDirectory: base, environment: [:])
    _ = provider.currentLaunch()
    // The failure window: overlay gone, app still running.
    try FileManager.default.removeItem(at: base.appendingPathComponent("zsh", isDirectory: true))

    var env = provider.currentLaunch().environmentOverrides
    env["HOME"] = home.path
    env["TERM"] = "xterm-256color"

    let session = try Session.realShell(
      size: size24x80, environment: env, launchArgv: ["/bin/zsh", "-i", "-l"])
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
      "zsh never reached a prompt phase — overlay did not heal")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: sentinel.path),
      "zsh did not source the user's .zshrc after the overlay dir was deleted")
  }

  // MARK: - Self-hosting leaks (laban launched from a laban shell)

  /// A ZDOTDIR that is itself a Laban overlay (Laban launched from inside a
  /// Laban tab) is not the user's config dir; the chain is dropped so the
  /// overlay .zshenv falls back to $HOME.
  func testInstallZshIgnoresLabanOverlayZdotdir() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/bin/zsh", baseDirectory: base,
      environment: ["ZDOTDIR": "/var/folders/x/T/laban-shell-integration-DEAD/zsh"])
    XCTAssertNil(launch.environmentOverrides["LABAN_REAL_ZDOTDIR"])
  }

  /// The inner LABAN_REAL_ZDOTDIR of an inherited overlay chain *is* the
  /// user's config dir; keep it.
  func testInstallZshUnwrapsLabanOverlayChain() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let launch = try ShellIntegrationOverlay.install(
      shellPath: "/bin/zsh", baseDirectory: base,
      environment: [
        "ZDOTDIR": "/var/folders/x/T/laban-shell-integration-DEAD/zsh",
        "LABAN_REAL_ZDOTDIR": "/Users/u/.config/zsh",
      ])
    XCTAssertEqual(
      launch.environmentOverrides["LABAN_REAL_ZDOTDIR"], "/Users/u/.config/zsh")
  }

  /// The spawn-env builder scrubs Laban's own integration state from the
  /// inherited environment (field report: a labpty daemon spawned from an
  /// instrumented shell carried a stale overlay ZDOTDIR that leaked into
  /// every child launched without an explicit override). User-set values
  /// pass through.
  func testSpawnEnvScrubsInheritedLabanIntegrationState() throws {
    setenv("ZDOTDIR", "/var/folders/x/T/laban-shell-integration-DEAD/zsh", 1)
    setenv("LABAN_REAL_ZDOTDIR", "/var/folders/x/T/laban-shell-integration-DEAD/zsh", 1)
    setenv("LABAN_SHELL_INTEGRATION", "1", 1)
    defer {
      unsetenv("ZDOTDIR")
      unsetenv("LABAN_REAL_ZDOTDIR")
      unsetenv("LABAN_SHELL_INTEGRATION")
    }
    let childEnv = try spawnEnvDump()
    XCTAssertFalse(childEnv.contains("ZDOTDIR="), "stale overlay ZDOTDIR leaked: \(childEnv)")
    XCTAssertFalse(childEnv.contains("LABAN_REAL_ZDOTDIR="))
    XCTAssertFalse(childEnv.contains("LABAN_SHELL_INTEGRATION="))
  }

  func testSpawnEnvKeepsUserZdotdir() throws {
    setenv("ZDOTDIR", "/tmp/laban-test-user-zdotdir", 1)
    defer { unsetenv("ZDOTDIR") }
    let childEnv = try spawnEnvDump()
    XCTAssertTrue(
      childEnv.contains("ZDOTDIR=/tmp/laban-test-user-zdotdir"),
      "user-set ZDOTDIR must survive: \(childEnv)")
  }

  /// Spawn `/bin/zsh -c 'env > <file>'` through the real PTY spawn path and
  /// return the captured child environment.
  private func spawnEnvDump() throws -> String {
    let out = try makeTempDir().appendingPathComponent("env.txt")
    defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }

    let session = try Session.realShell(
      size: size24x80,
      environment: ["HOME": home.path, "TERM": "xterm-256color"],
      launchArgv: ["/bin/zsh", "-c", "env > '\(out.path)'"])
    let dirty = OSAllocatedUnfairLock(initialState: 0)
    guard let runner = session.makeRunner(onDirty: { dirty.withLock { $0 += 1 } }) else {
      XCTFail("makeRunner returned nil")
      return ""
    }
    runner.start()
    defer {
      runner.stop()
      session.close()
    }
    XCTAssertTrue(
      waitUntil(3.0) {
        (try? String(contentsOf: out, encoding: .utf8))?.contains("HOME=") == true
      },
      "child never wrote its env dump")
    return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
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
