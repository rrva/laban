import Darwin
import Foundation
import LabanControl
import LabanCore

// MARK: - Stub router used only by the installed lazy-attach smoke test

private final class LazyAttachTestRouter: IntentRouter {
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

private final class LazyAttachAlwaysApproveDelegate: ControlAttachApprovalDelegate,
  @unchecked Sendable
{
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    completion(request.canPersist ? .alwaysAllowSignedIdentity : .allowOnce)
  }
}

private final class LazyAttachDenyDelegate: ControlAttachApprovalDelegate,
  @unchecked Sendable
{
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    completion(.deny)
  }
}

// MARK: - Smoke test harness

public func runLazyAttachInstalledSmoke() -> Int32 {
  let fm = FileManager.default
  let testDir = makeShortTemporaryDirectory()

  // Point control discovery at the temp directory for this test.
  setenv("LABAN_CONTROL_DIR", testDir.path, 1)

  let labanPath = labanHelperPath()
  let codexPath = testDir.appendingPathComponent("codex").path
  do {
    try fm.copyItem(atPath: labanPath, toPath: codexPath)
  } catch {
    lazyAttachTestFail("failed to copy laban helper to test codex: \(error)")
  }

  let signer = ControlAttachApprovalRecordHMACSigner(
    key: Data(repeating: 0, count: 32))
  let testDefaults =
    UserDefaults(suiteName: "com.ragnar.laban.test-lazy-attach")
    ?? .standard
  let approvalStore = ControlAttachApprovalStore(
    defaults: testDefaults,
    signer: signer)

  let server = LabanControlServer(
    router: LazyAttachTestRouter(),
    surface: .headless,
    readinessRunID: "lazy-attach-test")
  server.approvalStore = approvalStore

  let start: GUIControlStartResult
  do {
    start = try server.start()
  } catch {
    lazyAttachTestFail("failed to start control server: \(error)")
  }

  do {
    try ControlAdvertisement.write(
      url: start.socketPath,
      token: start.appObserveToken,
      pid: Int32(ProcessInfo.processInfo.processIdentifier),
      runId: "lazy-attach-test")
  } catch {
    lazyAttachTestFail("failed to write control.json: \(error)")
  }

  let shell = Process()
  shell.executableURL = URL(fileURLWithPath: "/bin/sh")
  shell.arguments = []
  var env = ProcessInfo.processInfo.environment
  env["LABAN_CONTROL_DIR"] = testDir.path
  env["TEST_DIR"] = testDir.path
  shell.environment = env

  let inputPipe = Pipe()
  shell.standardInput = inputPipe
  shell.standardOutput = FileHandle.nullDevice
  shell.standardError = FileHandle.nullDevice

  do {
    try shell.run()
  } catch {
    lazyAttachTestFail("failed to run shell: \(error)")
  }

  let shellPID = shell.processIdentifier
  server.registerAttachShellPID(sessionID: "test", shellPID: pid_t(shellPID))

  var approvalDelegate: ControlAttachApprovalDelegate? = LazyAttachAlwaysApproveDelegate()
  server.setApprovalDelegate(approvalDelegate)

  let result1 = runCodex(
    codexPath: codexPath,
    testDir: testDir,
    inputPipe: inputPipe,
    label: "1")
  guard result1 == .passed else {
    lazyAttachTestFail("first direct-agent lazy attach request failed: \(result1)")
  }

  // Persisted approvals require a stable signed identity. If the helper is ad-hoc
  // or unsigned, only direct-agent approval is verifiable; skip the persistence
  // and revocation checks instead of failing them.
  let persistable = !approvalStore.loadAll().isEmpty
  if persistable {
    // Persistence: a new helper PID should still be approved without prompting.
    approvalDelegate = nil
    server.setApprovalDelegate(nil)

    let result2 = runCodex(
      codexPath: codexPath,
      testDir: testDir,
      inputPipe: inputPipe,
      label: "2")
    guard result2 == .passed else {
      lazyAttachTestFail("persisted lazy attach approval did not match new helper PID: \(result2)")
    }

    // Revoke the stored approval and verify the next request is rejected.
    revokeAllApprovals(in: approvalStore)
    approvalDelegate = LazyAttachDenyDelegate()
    server.setApprovalDelegate(approvalDelegate)

    let result3 = runCodex(
      codexPath: codexPath,
      testDir: testDir,
      inputPipe: inputPipe,
      label: "3")
    guard result3 == .rejected else {
      lazyAttachTestFail("revoked approval still allowed lazy attach: \(result3)")
    }
  } else {
    // Approval without persistence still proves the helper/principal chain is
    // correctly identified and approved by the delegate.
    let result2 = runCodex(
      codexPath: codexPath,
      testDir: testDir,
      inputPipe: inputPipe,
      label: "2")
    guard result2 == .passed else {
      lazyAttachTestFail("second direct-agent lazy attach request failed: \(result2)")
    }
  }

  // Clean up the isolated defaults suite used for this test.
  testDefaults.removePersistentDomain(forName: "com.ragnar.laban.test-lazy-attach")
  testDefaults.synchronize()

  inputPipe.fileHandleForWriting.write(Data("exit\n".utf8))
  inputPipe.fileHandleForWriting.closeFile()

  return 0
}

// MARK: - Helpers

private enum SmokeResult: CustomStringConvertible, Equatable {
  case passed
  case rejected
  case failed(String)

  var description: String {
    switch self {
    case .passed: return "passed"
    case .rejected: return "rejected"
    case .failed(let message): return "failed: \(message)"
    }
  }
}

private func makeShortTemporaryDirectory() -> URL {
  var template = Array("/tmp/lbn-la.XXXXXX".utf8CString)
  let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
    guard let baseAddress = buffer.baseAddress, let createdPath = Darwin.mkdtemp(baseAddress)
    else {
      return nil
    }
    return String(cString: createdPath)
  }
  guard let path else {
    lazyAttachTestFail("failed to create short temporary directory")
  }
  return URL(fileURLWithPath: path, isDirectory: true)
}

private func runCodex(
  codexPath: String,
  testDir: URL,
  inputPipe: Pipe,
  label: String
) -> SmokeResult {
  let resultFile = testDir.appendingPathComponent("result\(label).json").path
  let exitFile = testDir.appendingPathComponent("exit\(label).txt").path
  let command = """
    "\(codexPath)" session state --json > "\(resultFile)" 2>&1; echo $? > "\(exitFile)"
    """ + "\n"
  inputPipe.fileHandleForWriting.write(Data(command.utf8))

  let timeout = Date().addingTimeInterval(60)
  while !FileManager.default.fileExists(atPath: exitFile) {
    if Date() > timeout {
      return .failed("timeout waiting for codex result \(label)")
    }
    Thread.sleep(forTimeInterval: 0.05)
  }

  guard
    let data = FileManager.default.contents(atPath: exitFile),
    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines),
    let exitCode = Int32(text)
  else {
    return .failed("could not read exit code for result \(label)")
  }

  if exitCode == 0 {
    return .passed
  } else if exitCode == 5 {
    return .rejected
  } else {
    let stderr =
      FileManager.default.contents(atPath: resultFile)
      .flatMap { String(data: $0, encoding: .utf8) }
      ?? ""
    return .failed("codex exit \(exitCode): \(stderr)")
  }
}

private func revokeAllApprovals(in store: ControlAttachApprovalStore) {
  for record in store.loadAll() where !record.isRevoked {
    store.revoke(id: record.id)
  }
}

private func labanHelperPath() -> String {
  let bundleURL = Bundle.main.bundleURL
  guard bundleURL.pathExtension == "app" else {
    lazyAttachTestFail("could not locate the laban helper inside a signed app bundle")
  }
  return
    bundleURL
    .appendingPathComponent("Contents/MacOS/laban")
    .path
}

private func lazyAttachTestFail(_ message: String) -> Never {
  print("LAZY_ATTACH_INSTALLED_SMOKE_FAIL: \(message)")
  exit(1)
}
