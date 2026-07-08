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

  func testPIDReuseByStartTimeMismatchIsRejected() {
    let shellStart = Date(timeIntervalSince1970: 1000)
    let reusedStart = Date(timeIntervalSince1970: 2000)
    let inspector = FakeProcessTreeInspector(tree: [
      100: (parent: 50, identity: identity(100, path: "/bin/zsh", startTime: reusedStart)),
      50: (parent: 1, identity: identity(50, path: "/bin/zsh", startTime: shellStart)),
    ])
    let server = makeServer(inspector: inspector)
    server.registerAttachShellPID(sessionID: "s1", shellPID: 50)

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
    let server = LabanControlServer(router: SpyAttachRouter(), surface: .headless)
    server.setProcessTreeInspector(inspector)
    return server
  }

  private func identity(
    _ pid: pid_t,
    path: String,
    startTime: Date? = Date()
  ) -> ControlProcessIdentity {
    ControlProcessIdentity(
      pid: pid,
      parentPID: nil,
      startTime: startTime,
      uid: getuid(),
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

  func identity(for pid: pid_t) -> ControlProcessIdentity {
    tree[pid]?.identity ?? ControlProcessIdentity(pid: pid, uid: getuid())
  }
}

private final class SpyAttachRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .error(501, "not expected") }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}
