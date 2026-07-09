import Darwin
import Foundation
import LabanControl
import LabanCore

// MARK: - Stub router used only by the installed agent-run-shim smoke test

private final class AgentRunShimTestRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse {
    json(["ok": true])
  }

  func query(_ query: Query) -> ControlResponse {
    json(["ok": true])
  }

  func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    json(["ok": true])
  }

  func control(_ input: LegacyDebugControlInput) -> ControlResponse {
    .error(501, "not yet ported")
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    nil
  }

  private func json(_ value: [String: Any]) -> ControlResponse {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys])
    else {
      return .error(500, "internal error")
    }
    return ControlResponse(status: 200, contentType: "application/json", body: data)
  }
}

// MARK: - Smoke test harness
//
// Proves the installed-shim gate item (execplans/active/agent-control-production-broker-and-cli.md,
// "Review findings (MVP gate)" finding 1) end to end against the real, signed,
// installed app bundle: installs the real `laban install-cli` shim into a
// scratch prefix, drives a real interactive shell to run `laban agent run --
// <command>` through that shim (mirroring how a terminal tab actually invokes
// it), and confirms the resulting `laban-agent` broker process (reached only
// through `exec` hops: shim -> bundled `laban` -> `laban-agent`) satisfies the
// real running `LabanControlServer`'s C14 direct-child + executable-path
// verifier and successfully launches its child command.

public func runAgentRunShimInstalledSmoke() -> Int32 {
  let fm = FileManager.default
  let testDir = makeShortAgentRunShimTemporaryDirectory()

  // Point control discovery at the temp directory for this test so it never
  // binds over (or reads) a real running Laban.app's control socket.
  setenv("LABAN_CONTROL_DIR", testDir.path, 1)

  let labanPath = agentRunShimBundledLabanPath()
  let agentHelperPath = agentRunShimBundledAgentPath()

  // Install the real shim via the real installed `laban install-cli`, so the
  // shim content, permissions, and target-path resolution are exactly what a
  // user's `~/.local/bin/laban` would contain.
  let prefixDir = testDir.appendingPathComponent("prefix", isDirectory: true)
  let installProcess = Process()
  installProcess.executableURL = URL(fileURLWithPath: labanPath)
  installProcess.arguments = ["install-cli", "--prefix", prefixDir.path]
  installProcess.standardOutput = FileHandle.nullDevice
  installProcess.standardError = FileHandle.nullDevice
  do {
    try installProcess.run()
  } catch {
    agentRunShimTestFail("failed to run install-cli: \(error)")
  }
  installProcess.waitUntilExit()
  guard installProcess.terminationStatus == 0 else {
    agentRunShimTestFail("install-cli exited \(installProcess.terminationStatus)")
  }

  let shimPath = prefixDir.appendingPathComponent("laban").path
  guard fm.isExecutableFile(atPath: shimPath) else {
    agentRunShimTestFail("install-cli did not produce an executable shim at \(shimPath)")
  }

  // Verify the shim is final-exec before driving it through a real shell: a
  // shim that forked into its target instead of exec'ing into it would insert
  // an extra pid hop and make every C14 direct-child check below fail for a
  // reason unrelated to the redeemer logic this test exists to prove.
  let shimIsSymlink =
    (try? fm.destinationOfSymbolicLink(atPath: shimPath)) != nil
  if !shimIsSymlink {
    guard
      let shimContent = try? String(contentsOfFile: shimPath, encoding: .utf8),
      let lastNonEmptyLine = shimContent.split(separator: "\n").last(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
      }),
      lastNonEmptyLine.trimmingCharacters(in: .whitespaces).hasPrefix("exec ")
    else {
      agentRunShimTestFail(
        "installed shim at \(shimPath) is not final-exec (last statement is not `exec \"`)")
    }
  }

  let server = LabanControlServer(
    router: AgentRunShimTestRouter(),
    surface: .headless,
    readinessRunID: "agent-run-shim-test",
    expectedAgentExecutablePath: agentHelperPath,
    allowDevAgentExecutablePath: false)

  let start: GUIControlStartResult
  do {
    start = try server.start()
  } catch {
    agentRunShimTestFail("failed to start control server: \(error)")
  }
  defer { server.stop() }

  // Spawn a real shell and feed it commands over a pipe, exactly as an
  // interactive terminal tab would host the session's login shell; the shell
  // is the process C14 registers as the session's shell PID.
  let shell = Process()
  shell.executableURL = URL(fileURLWithPath: "/bin/sh")
  shell.arguments = []
  var env = ProcessInfo.processInfo.environment
  env["LABAN_CONTROL_DIR"] = testDir.path
  env[ControlEnvironmentKeys.controlURL] = start.socketPath
  shell.environment = env

  let inputPipe = Pipe()
  shell.standardInput = inputPipe
  shell.standardOutput = FileHandle.nullDevice
  shell.standardError = FileHandle.nullDevice

  do {
    try shell.run()
  } catch {
    agentRunShimTestFail("failed to run shell: \(error)")
  }
  defer {
    if shell.isRunning {
      Darwin.kill(-shell.processIdentifier, SIGKILL)
      shell.waitUntilExit()
    }
  }

  // Mints the single-use C14 bootstrap before the shell PID is registered,
  // matching production ordering: `ControlSessionLaunchCoordinator.prepareLaunch`
  // mints the bootstrap and hands it to the launched process immediately, and
  // only later, once the real shell PID is known, does
  // `noteSessionShellStarted` call `registerAttachShellPID`.
  // `registerAttachShellPID` only back-fills `shellPID` onto bootstraps that
  // already exist for the session, so minting after registering would leave
  // the bootstrap's `shellPID` permanently nil and every redemption `.pending`.
  let shellPID = pid_t(shell.processIdentifier)
  let bootstrap = server.mintSessionAttachBootstrap(sessionID: "agent-run-shim-test")
  server.registerAttachShellPID(sessionID: "agent-run-shim-test", shellPID: shellPID)

  let markerFile = testDir.appendingPathComponent("marker.txt").path
  let childStdout = testDir.appendingPathComponent("child-stdout.txt").path
  let exitFile = testDir.appendingPathComponent("exit.txt").path

  // Runs `laban agent run` as a real backgrounded job of the shell (forcing
  // an actual fork from the shell, not a tail-call that would leave the shim
  // chain running as the shell's own pid) through the freshly installed
  // shim, then records its exit code once the job completes.
  let childCommand =
    "/bin/sh -c \(agentRunShimQuote("echo shim-smoke-child-ok > " + agentRunShimQuote(markerFile)))"
  let command = """
    LABAN_SESSION_ATTACH=\(agentRunShimQuote(bootstrap)) \(agentRunShimQuote(shimPath)) agent run -- \(childCommand) > \(agentRunShimQuote(childStdout)) 2>&1 &
    child_job=$!
    wait "$child_job"
    echo $? > \(agentRunShimQuote(exitFile))

    """
  inputPipe.fileHandleForWriting.write(Data(command.utf8))

  let deadline = Date().addingTimeInterval(20)
  while !fm.fileExists(atPath: exitFile) {
    if Date() > deadline {
      let stdout =
        fm.contents(atPath: childStdout).flatMap { String(data: $0, encoding: .utf8) } ?? ""
      agentRunShimTestFail(
        "timed out waiting for `laban agent run` through the shim to exit; stdout so far: \(stdout)"
      )
    }
    Thread.sleep(forTimeInterval: 0.05)
  }

  guard
    let exitData = fm.contents(atPath: exitFile),
    let exitText = String(data: exitData, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines),
    let exitCode = Int32(exitText)
  else {
    agentRunShimTestFail("could not read exit code for the shimmed agent run")
  }

  let stdout = fm.contents(atPath: childStdout).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  guard exitCode == 0 else {
    agentRunShimTestFail(
      "`laban agent run` through the shim exited \(exitCode) (C14 redemption likely rejected the shim chain); stdout: \(stdout)"
    )
  }
  guard fm.fileExists(atPath: markerFile) else {
    agentRunShimTestFail(
      "`laban agent run` exited 0 through the shim but its child never ran; stdout: \(stdout)")
  }

  inputPipe.fileHandleForWriting.write(Data("exit\n".utf8))
  inputPipe.fileHandleForWriting.closeFile()

  return 0
}

// MARK: - Helpers

private func makeShortAgentRunShimTemporaryDirectory() -> URL {
  var template = Array("/tmp/lbn-ars.XXXXXX".utf8CString)
  let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
    guard let baseAddress = buffer.baseAddress, let createdPath = Darwin.mkdtemp(baseAddress)
    else {
      return nil
    }
    return String(cString: createdPath)
  }
  guard let path else {
    agentRunShimTestFail("failed to create short temporary directory")
  }
  return URL(fileURLWithPath: path, isDirectory: true)
}

/// Resolves the bundled `laban` CLI helper from the enclosing signed `.app`,
/// the same way a real terminal session's `laban install-cli` would.
private func agentRunShimBundledLabanPath() -> String {
  let bundleURL = Bundle.main.bundleURL
  guard bundleURL.pathExtension == "app" else {
    agentRunShimTestFail("could not locate the laban helper inside a signed app bundle")
  }
  return bundleURL.appendingPathComponent("Contents/MacOS/laban").path
}

/// Resolves the bundled `laban-agent` helper the same way
/// `ControlProcessInfo.defaultExpectedAgentExecutablePath()` would for this
/// running bundle, so the C14 executable-path check is exercised against the
/// real value rather than a test-only override.
private func agentRunShimBundledAgentPath() -> String {
  let bundleURL = Bundle.main.bundleURL
  guard bundleURL.pathExtension == "app" else {
    agentRunShimTestFail("could not locate the laban-agent helper inside a signed app bundle")
  }
  return bundleURL.appendingPathComponent("Contents/MacOS/laban-agent").path
}

private func agentRunShimQuote(_ string: String) -> String {
  "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func agentRunShimTestFail(_ message: String) -> Never {
  print("AGENT_RUN_SHIM_SMOKE_FAIL: \(message)")
  exit(1)
}
