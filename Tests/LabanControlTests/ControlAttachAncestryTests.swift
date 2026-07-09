import Foundation
import LabanControl
import LabanCore
import XCTest

final class ControlAttachAncestryTests: XCTestCase {

  func testDirectDescendantIsEligible() {
    let inspector = FakeProcessTreeInspector(tree: [
      100: (parent: 50, identity: identity(100, path: "/bin/zsh")),
      50: (parent: 1, identity: identity(50, path: "/bin/zsh")),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 100)
    XCTAssertTrue(result)
  }

  func testGrandchildAndToolRunnerChainIsEligible() {
    let inspector = FakeProcessTreeInspector(tree: [
      400: (parent: 300, identity: identity(400, path: "/usr/local/bin/laban")),
      300: (parent: 200, identity: identity(300, path: "/usr/local/bin/node")),
      200: (
        parent: 100, identity: identity(200, path: "/Applications/Codex.app/Contents/MacOS/Codex")
      ),
      100: (parent: 50, identity: identity(100, path: "/bin/zsh")),
      50: (parent: 1, identity: identity(50, path: "/bin/zsh")),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 400)
    XCTAssertTrue(result)
  }

  func testNonDescendantIsRejected() {
    let inspector = FakeProcessTreeInspector(tree: [
      1000: (parent: 1, identity: identity(1000, path: "/usr/local/bin/laban"))
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 1000)
    XCTAssertFalse(result)
  }

  func testAmbiguousDescendantOfTwoSessionsIsRejected() {
    let inspector = FakeProcessTreeInspector(tree: [
      100: (parent: 50, identity: identity(100, path: "/bin/zsh"))
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)
    server.registerAttachShellPID(sessionID: "s2", shellPID: 50)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 100)
    XCTAssertFalse(result)
  }

  func testMissingShellStartTimeFailsClosed() {
    let inspector = FakeProcessTreeInspector(tree: [
      100: (parent: 50, identity: identity(100, path: "/bin/zsh")),
      50: (parent: 1, identity: identity(50, path: "/bin/zsh", startTime: nil)),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 100)
    XCTAssertFalse(result)
  }

  func testMissingPeerStartTimeFailsClosed() {
    let inspector = FakeProcessTreeInspector(tree: [
      100: (parent: 50, identity: identity(100, path: "/bin/zsh", startTime: nil)),
      50: (parent: 1, identity: identity(50, path: "/bin/zsh")),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 100)
    XCTAssertFalse(result)
  }

  func testPrivilegeBoundaryAboveMatchedShellStillResolves() {
    // peer -> tool -> shell(registered) -> app -> login(root) -> pid1
    let inspector = FakeProcessTreeInspector(tree: [
      500: (parent: 400, identity: identity(500, path: "/usr/local/bin/laban")),
      400: (parent: 300, identity: identity(400, path: "/usr/bin/tool")),
      300: (parent: 200, identity: identity(300, path: "/bin/zsh")),
      200: (parent: 100, identity: identity(200, path: "/usr/local/bin/app")),
      100: (parent: 1, identity: identity(100, path: "/usr/bin/login", uid: 0)),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 300)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 500)
    XCTAssertTrue(result)
  }

  func testPrivilegeBoundaryBeforeAnyMatchFailsClosed() {
    // peer -> sudoHelper(root) -> shell(registered, never reached)
    let inspector = FakeProcessTreeInspector(tree: [
      600: (parent: 700, identity: identity(600, path: "/usr/local/bin/laban")),
      700: (parent: 800, identity: identity(700, path: "/usr/bin/sudo", uid: 0)),
      800: (parent: 1, identity: identity(800, path: "/bin/zsh")),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 800)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 600)
    XCTAssertFalse(result)
  }

  func testNearerShellWinsAtPrivilegeBoundaryWithoutAmbiguityFailure() {
    // peer -> shellB(registered s2) -> middle(root) -> shellA(registered s1)
    let inspector = FakeProcessTreeInspector(tree: [
      900: (parent: 850, identity: identity(900, path: "/usr/local/bin/laban")),
      850: (parent: 800, identity: identity(850, path: "/bin/zsh")),
      800: (parent: 750, identity: identity(800, path: "/usr/bin/login", uid: 0)),
      750: (parent: 1, identity: identity(750, path: "/bin/zsh")),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 750)
    server.registerAttachShellPID(sessionID: "s2", shellPID: 850)

    let result = server.canLazyAttachDescendant(sessionID: "s2", peerPID: 900)
    XCTAssertTrue(result)
  }

  func testUnresolvableIdentityAboveMatchedShellStillResolves() {
    // peer -> tool -> shell(registered) -> (parent pid has no identity at all)
    let inspector = FakeProcessTreeInspector(tree: [
      1500: (parent: 1400, identity: identity(1500, path: "/usr/local/bin/laban")),
      1400: (parent: 1300, identity: identity(1400, path: "/usr/bin/tool")),
      1300: (parent: 1200, identity: identity(1300, path: "/bin/zsh")),
      // 1200 intentionally absent from the tree: identity(for: 1200) resolves to nil.
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 1300)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 1500)
    XCTAssertTrue(result)
  }

  func testUnresolvableIdentityBelowMatchedShellFailsClosed() {
    // peer -> (parent pid has no identity at all) -> shell(registered, never reached)
    let inspector = FakeProcessTreeInspector(tree: [
      1600: (parent: 1550, identity: identity(1600, path: "/usr/local/bin/laban")),
      // 1550 intentionally absent from the tree: identity(for: 1550) resolves to nil.
      1500: (parent: 1, identity: identity(1500, path: "/bin/zsh")),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 1500)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 1600)
    XCTAssertFalse(result)
  }

  func testSwappedShellIdentityAfterRegistrationFailsEligibility() {
    // PID reuse at the ancestry layer: the shell PID is registered against
    // one process identity, then a different process (same PID, different
    // start time) takes over that PID before the eligibility check runs.
    let inspector = MutableFakeProcessTreeInspector(tree: [
      100: (parent: 50, identity: identity(100, path: "/bin/zsh")),
      50: (
        parent: 1,
        identity: identity(50, path: "/bin/zsh", startTime: Date(timeIntervalSince1970: 1000))
      ),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

    XCTAssertTrue(server.canLazyAttachDescendant(sessionID: "s1", peerPID: 100))

    // A new process now occupies PID 50 (different start time == PID reuse).
    inspector.setIdentity(
      identity(50, path: "/bin/zsh", startTime: Date(timeIntervalSince1970: 2000)),
      parent: 1,
      for: 50)

    let result = server.canLazyAttachDescendant(sessionID: "s1", peerPID: 100)
    XCTAssertFalse(result)
  }

  func testStaleShellRegistrationRemovedOnSessionClose() {
    let inspector = FakeProcessTreeInspector(tree: [
      100: (parent: 50, identity: identity(100, path: "/bin/zsh")),
      50: (parent: 1, identity: identity(50, path: "/bin/zsh")),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)
    XCTAssertTrue(server.hasRegisteredShell(sessionID: "s1"))

    server.unregisterAttachShellIdentity(sessionID: "s1")
    XCTAssertFalse(server.hasRegisteredShell(sessionID: "s1"))
  }

  // MARK: - Helpers

  private func makeServer(inspector: ControlProcessTreeInspecting) -> LabanControlServer {
    LabanControlServer(
      router: SpyAttachRouter(),
      surface: .headless,
      processTreeInspector: inspector)
  }

  private func identity(
    _ pid: pid_t,
    path: String,
    startTime: Date? = Date(),
    uid: uid_t = getuid()
  ) -> ControlProcessIdentity {
    ControlProcessIdentity(
      pid: pid,
      parentPID: nil,
      startTime: startTime,
      uid: uid,
      executablePath: path,
      arguments: [],
      signing: nil)
  }
}

private struct FakeProcessTreeInspector: ControlProcessTreeInspecting {
  let tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]

  func parentPID(of pid: pid_t) -> pid_t? {
    tree[pid]?.parent
  }

  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}

/// A `ControlProcessTreeInspecting` whose backing tree can be mutated after
/// construction, so a test can register a shell PID against one identity and
/// then swap in a different identity behind the same PID (simulating PID
/// reuse) before the eligibility or revalidation check runs.
private final class MutableFakeProcessTreeInspector: ControlProcessTreeInspecting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]

  init(tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]) {
    self.tree = tree
  }

  func setIdentity(
    _ identity: ControlProcessIdentity, parent: pid_t?, for pid: pid_t
  ) {
    lock.lock()
    tree[pid] = (parent: parent, identity: identity)
    lock.unlock()
  }

  func parentPID(of pid: pid_t) -> pid_t? {
    lock.lock()
    defer { lock.unlock() }
    return tree[pid]?.parent
  }

  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    lock.lock()
    defer { lock.unlock() }
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}

private final class SpyAttachRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .error(501, "not expected") }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
