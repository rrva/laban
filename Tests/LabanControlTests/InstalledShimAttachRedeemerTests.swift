import Darwin
import Foundation
import LabanControl
import LabanCore
import XCTest

/// Covers the "installed-shim satisfies the C14 direct-child verifier" gate
/// item at the level `LabanControlServer.isAllowedAttachRedeemer` actually
/// checks: parent/child PID identity plus (when not skipped for tests)
/// executable-path identity of the redeeming peer.
///
/// `InstallCLI.installShim` writes a `#!/bin/sh` wrapper whose only statement
/// is `exec <target> "$@"`. `exec` in a POSIX shell replaces the shell's
/// process image in place, so the resulting process keeps the shim's PID and
/// therefore the shim's parent (the interactive shell that launched it). This
/// suite proves that chain end to end with real spawned processes rather than
/// asserting on the shim's file contents: a shim whose real target is reached
/// only via `exec` preserves the PID relationship C14 requires, while any
/// chain that inserts a fork (subshell backgrounding, `&` without a matching
/// `exec`) produces a peer whose direct parent is not the registered shell,
/// which `isAllowedAttachRedeemer` must reject.
final class InstalledShimAttachRedeemerTests: XCTestCase {
  override func tearDown() {
    LabanControlServer.skipExecutableVerificationForTests = false
    super.tearDown()
  }

  /// A shim chain that only ever `exec`s (the shape `InstallCLI.installShim`
  /// produces) keeps the final process a direct child of the launching shell,
  /// and its resolved executable path matches the real target the shim
  /// pointed at. Both facts must hold for `isAllowedAttachRedeemer` to accept
  /// the redemption.
  func testExecOnlyShimChainIsAcceptedAsDirectChild() throws {
    let fixture = try ShimChainFixture.make(chain: .execOnly)
    defer { fixture.cleanUp() }

    let peerPID = try fixture.spawnAndWaitForPeerPID()

    LabanControlServer.skipExecutableVerificationForTests = false
    XCTAssertTrue(
      LabanControlServer.isAllowedAttachRedeemer(
        peerPID: peerPID,
        shellPID: fixture.shellPID,
        expectedAgentExecutablePath: fixture.agentExecutablePath,
        allowDevAgentExecutablePath: false),
      "an exec-only shim chain must satisfy the C14 direct-child verifier")
  }

  /// A native symlink to the shim resolves and execs identically to the
  /// plain-file shim: `exec` still replaces the process image in place, so
  /// the symlink hop leaves no extra PID in the chain.
  func testSymlinkedShimChainIsAcceptedAsDirectChild() throws {
    let fixture = try ShimChainFixture.make(chain: .symlinkToExecOnlyShim)
    defer { fixture.cleanUp() }

    let peerPID = try fixture.spawnAndWaitForPeerPID()

    LabanControlServer.skipExecutableVerificationForTests = false
    XCTAssertTrue(
      LabanControlServer.isAllowedAttachRedeemer(
        peerPID: peerPID,
        shellPID: fixture.shellPID,
        expectedAgentExecutablePath: fixture.agentExecutablePath,
        allowDevAgentExecutablePath: false),
      "a symlinked exec-only shim chain must satisfy the C14 direct-child verifier")
  }

  /// A chain that backgrounds the real target in a nested subshell (`(... &
  /// wait) &`) instead of `exec`-ing into it inserts an extra fork hop: the
  /// reported peer's direct parent is that subshell, not the registered
  /// shell. `isAllowedAttachRedeemer`'s parent-PID check must reject this
  /// even though the peer's executable path still matches the agent binary.
  func testForkInsertedExtraHopIsRejected() throws {
    let fixture = try ShimChainFixture.make(chain: .forkInsertedExtraHop)
    defer { fixture.cleanUp() }

    let peerPID = try fixture.spawnAndWaitForPeerPID()

    LabanControlServer.skipExecutableVerificationForTests = false
    XCTAssertFalse(
      LabanControlServer.isAllowedAttachRedeemer(
        peerPID: peerPID,
        shellPID: fixture.shellPID,
        expectedAgentExecutablePath: fixture.agentExecutablePath,
        allowDevAgentExecutablePath: false),
      "a fork-inserted extra hop must be rejected by the C14 direct-child verifier")
  }

  /// Sanity check on the executable-path half of the verifier in isolation:
  /// a genuine direct child of the shell (the parent-PID check passes)
  /// whose executable is not the expected agent binary must still be
  /// rejected, and the rejection must come specifically from the
  /// executable-path branch, not the parent-PID branch. The first
  /// assertion proves the parent-PID check alone would pass (by skipping
  /// executable verification); the second proves that with executable
  /// verification enabled, that same peer is rejected.
  func testDirectChildWithWrongExecutableIsRejected() throws {
    let fixture = try ShimChainFixture.make(chain: .directChildNonAgentExecutable)
    defer { fixture.cleanUp() }

    let impostorPeerPID = try fixture.spawnAndWaitForPeerPID()

    LabanControlServer.skipExecutableVerificationForTests = true
    XCTAssertTrue(
      LabanControlServer.isAllowedAttachRedeemer(
        peerPID: impostorPeerPID,
        shellPID: fixture.shellPID,
        expectedAgentExecutablePath: fixture.agentExecutablePath,
        allowDevAgentExecutablePath: false),
      "with executable verification skipped, a genuine direct child of the "
        + "registered shell must pass on the parent-PID check alone")

    LabanControlServer.skipExecutableVerificationForTests = false
    XCTAssertFalse(
      LabanControlServer.isAllowedAttachRedeemer(
        peerPID: impostorPeerPID,
        shellPID: fixture.shellPID,
        expectedAgentExecutablePath: fixture.agentExecutablePath,
        allowDevAgentExecutablePath: false),
      "a direct child running a non-agent executable must be rejected once "
        + "executable verification runs")
  }
}

/// A hard failure for a shim chain fixture that never reached the expected
/// state (for example, never reported its peer pid within the timeout).
/// Thrown instead of `XCTSkip` where the timeout itself is the regression a
/// test exists to catch, so the failure surfaces as a test failure rather
/// than a silently green skip.
private struct ShimChainError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Builds a small, real `.app`-shaped bundle containing a compiled stub
/// binary named `laban-agent` (so `ControlProcessInfo.isBundledAgentPath` and
/// `isLabanAgentExecutable` accept it), plus a `laban`-shim-shaped launcher
/// that reaches it through one of a few real process chains, and spawns that
/// chain as a direct child of a freshly spawned shell.
///
/// A compiled stub is used instead of copying a system binary (e.g.
/// `/bin/sh`) to a new path: macOS's trust-cache path pinning SIGKILLs a
/// relocated copy of a system binary the moment it runs, which would make
/// every "accept" case in this suite fail for a reason unrelated to C14.
private struct ShimChainFixture {
  enum ChainShape {
    /// Mirrors `InstallCLI.installShim`'s generated template exactly: a
    /// `#!/bin/sh` wrapper whose only statement is `exec <target> "$@"`.
    case execOnly
    /// A symlink pointing at an exec-only shim (covers the "shim is a
    /// symlink" shape named in the gate item).
    case symlinkToExecOnlyShim
    /// Backgrounds the real target inside a nested subshell instead of
    /// `exec`-ing into it, inserting an extra fork hop between the launching
    /// shell and the final process.
    case forkInsertedExtraHop
    /// Backgrounds a second, independent child directly under the launching
    /// shell (no extra fork hop) that reports its own pid and then `exec`s a
    /// real non-agent system binary at its real path. The reported peer is
    /// therefore a genuine direct child of the registered shell whose
    /// executable is not the agent binary, isolating the executable-path
    /// half of the verifier.
    case directChildNonAgentExecutable
  }

  let workDirectory: URL
  let agentExecutablePath: String
  let shellPID: pid_t
  private let launchScript: String
  private let peerPIDFilePath: String

  static func make(chain: ChainShape) throws -> ShimChainFixture {
    let workDirectory = URL(
      fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
    ).appendingPathComponent("laban-shim-chain-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let bundleDirectory = workDirectory.appendingPathComponent(
      "Laban.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(
      at: bundleDirectory, withIntermediateDirectories: true)

    let agentExecutablePath = bundleDirectory.appendingPathComponent("laban-agent").path
    let peerPIDFilePath = workDirectory.appendingPathComponent("peer.pid").path
    try compileAgentStub(outputPath: agentExecutablePath, pidFilePath: peerPIDFilePath)

    let shimPath = workDirectory.appendingPathComponent("laban").path
    let shimContent = """
      #!/bin/sh
      exec \(shellQuote(agentExecutablePath)) "$@"
      """
    try shimContent.write(toFile: shimPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: shimPath)

    let launchScript: String
    switch chain {
    case .execOnly:
      launchScript = "\(shellQuote(shimPath)) & wait"
    case .symlinkToExecOnlyShim:
      let symlinkPath = workDirectory.appendingPathComponent("laban-symlink").path
      try FileManager.default.createSymbolicLink(
        atPath: symlinkPath, withDestinationPath: shimPath)
      launchScript = "\(shellQuote(symlinkPath)) & wait"
    case .forkInsertedExtraHop:
      launchScript = "( \(shellQuote(shimPath)) & wait ) & wait"
    case .directChildNonAgentExecutable:
      // A direct child of the launching shell (single fork, no extra hop,
      // same as .execOnly) that reports its own pid and then `exec`s a real
      // system binary at its real path instead of the agent stub. Written
      // as its own `#!/bin/sh` script (rather than inlined via `sh -c`) so
      // that `$$` inside it names the script interpreter's own pid, not the
      // launching shell's, exactly mirroring how the real shim's `exec`
      // preserves pid identity.
      let nonAgentScriptPath = workDirectory.appendingPathComponent(
        "non-agent-direct-child"
      ).path
      let nonAgentScriptContent = """
        #!/bin/sh
        echo $$ > \(shellQuote(peerPIDFilePath))
        exec /bin/sleep 30
        """
      try nonAgentScriptContent.write(
        toFile: nonAgentScriptPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: nonAgentScriptPath)
      launchScript = "\(shellQuote(nonAgentScriptPath)) & wait"
    }

    let shellPID = try Self.spawnShellChild(script: launchScript)

    return ShimChainFixture(
      workDirectory: workDirectory,
      agentExecutablePath: agentExecutablePath,
      shellPID: shellPID,
      launchScript: launchScript,
      peerPIDFilePath: peerPIDFilePath)
  }

  /// Waits for the spawned chain's final process to report its own pid, then
  /// returns it as the "peer" a redemption request would present. A timeout
  /// here means the chain never reached the point of `exec`-ing into a
  /// process that reports its pid, i.e. exactly the regression this suite
  /// exists to catch (a shim that fails to exec or report its pid), so it
  /// must fail the test rather than skip it.
  func spawnAndWaitForPeerPID() throws -> pid_t {
    guard let peerPID = Self.waitForPID(atPath: peerPIDFilePath, timeout: 3) else {
      throw ShimChainError("shim chain never reported a peer pid")
    }
    return peerPID
  }

  func killAndReap(_ pid: pid_t) {
    _ = Darwin.kill(-pid, SIGKILL)
    _ = Darwin.kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
  }

  func cleanUp() {
    killAndReap(shellPID)
    try? FileManager.default.removeItem(at: workDirectory)
  }

  // MARK: - Helpers

  private static func spawnShellChild(script: String) throws -> pid_t {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sh"), strdup("-c"), strdup(script), nil,
    ]
    defer { for arg in argv { free(arg) } }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    let flags: Int16 = Int16(POSIX_SPAWN_SETPGROUP)
    posix_spawnattr_setflags(&attr, flags)
    posix_spawnattr_setpgroup(&attr, 0)
    var envp: [UnsafeMutablePointer<CChar>?] = [nil]
    defer { for e in envp { free(e) } }
    let result = posix_spawnp(&pid, "/bin/sh", nil, &attr, argv, &envp)
    guard result == 0 else {
      throw NSError(domain: "ShimChainFixture", code: Int(result))
    }
    return pid
  }

  static func waitForPID(atPath path: String, timeout: TimeInterval) -> pid_t? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let data = FileManager.default.contents(atPath: path),
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        let pid = pid_t(text)
      {
        return pid
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
  }

  /// Compiles a tiny C program that writes its own pid to `pidFilePath` and
  /// then sleeps, standing in for the real `laban-agent` binary. Requires
  /// `/usr/bin/clang`, which ships with the Xcode command line tools this
  /// package already needs to build.
  private static func compileAgentStub(outputPath: String, pidFilePath: String) throws {
    let source = """
      #include <stdio.h>
      #include <unistd.h>
      int main(void) {
          FILE *f = fopen("\(pidFilePath)", "w");
          if (f) { fprintf(f, "%d", getpid()); fclose(f); }
          sleep(30);
          return 0;
      }
      """
    let sourcePath = outputPath + ".c"
    try source.write(toFile: sourcePath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O0", "-o", outputPath, sourcePath]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
      throw NSError(domain: "ShimChainFixture", code: Int(compile.terminationStatus))
    }
  }

  private static func shellQuote(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
