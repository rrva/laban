import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanAgent

/// Covers the signal handling used by `laban-agent --control-attach-run`: which
/// signal maps to which action (`childSignalAction`), and that the real
/// dispatch-source wiring (`installChildSignalSources`) forwards SIGINT and
/// escalates SIGTERM/SIGHUP to a bounded-grace SIGKILL against a real spawned
/// child.
final class ChildSignalHandlingTests: XCTestCase {
  // Keeps each test's dispatch sources alive for the duration of that test
  // only; `installChildSignalSources` returns its sources rather than
  // retaining them globally so tests cannot leak sources into one another
  // (a source armed against one test's already-reaped child pid could
  // otherwise fire during an unrelated later test).
  private var retainedSources: [DispatchSourceSignal] = []

  override func setUp() {
    super.setUp()
    // `Darwin.signal` mutates process-global disposition, and a prior test's
    // `installChildSignalSources` call sets SIGINT/SIGTERM/SIGHUP to SIG_IGN
    // for every signal it wires up, even ones that test never actually sends.
    // SIG_IGN is inherited across exec/posix_spawn, and POSIX shells refuse
    // to honor `trap` for a signal that was already ignored at shell startup,
    // so a child spawned by a later test would silently never see its own
    // `trap ... INT` fire. Reset to default before each test so a freshly
    // spawned child starts with the same disposition a real broker's first
    // (and only) child would see.
    for sig in [SIGINT, SIGTERM, SIGHUP] {
      Darwin.signal(sig, SIG_DFL)
    }
  }

  override func tearDown() {
    // Cancel explicitly rather than just dropping references: an
    // uncancelled DispatchSourceSignal can remain registered with the
    // kernel's EVFILT_SIGNAL past deallocation, so a later test's identical
    // signal could still reach this test's (now-stale) event handler.
    for source in retainedSources { source.cancel() }
    retainedSources.removeAll()
    super.tearDown()
  }

  // MARK: - Pure decision logic

  func testSIGINTMapsToForward() {
    XCTAssertEqual(childSignalAction(for: SIGINT), .forward(SIGINT))
  }

  func testSIGTERMMapsToGracefulTerminate() {
    XCTAssertEqual(childSignalAction(for: SIGTERM), .gracefulTerminate)
  }

  func testSIGHUPMapsToGracefulTerminate() {
    XCTAssertEqual(childSignalAction(for: SIGHUP), .gracefulTerminate)
  }

  func testUnhandledSignalMapsToNoAction() {
    XCTAssertNil(childSignalAction(for: SIGUSR1))
  }

  // MARK: - Integration: real child, real signal, real dispatch source

  func testSIGINTIsForwardedToRealChild() throws {
    // The child traps SIGINT and exits cleanly only if it actually received
    // that specific signal; a default-disposition death (e.g. from SIGTERM)
    // would show up as a signal death, not a clean exit(0).
    let childPID = try spawnShellChild(
      script: "trap 'exit 0' INT; sleep 5")

    retainedSources = installChildSignalSources(childPID: childPID)
    // The dispatch signal source registers with the kernel asynchronously;
    // raising immediately after resume() can race the registration and be
    // silently swallowed by the SIG_IGN disposition set underneath it.
    Thread.sleep(forTimeInterval: 0.1)
    // kqueue's EVFILT_SIGNAL (which DispatchSourceSignal is built on) only
    // fires for process-directed signals; raise(3) on Darwin is
    // thread-directed (pthread_kill(pthread_self(), _)) and would not wake
    // the dispatch source at all, so send the signal to the process instead.
    XCTAssertEqual(Darwin.kill(getpid(), SIGINT), 0)

    guard let outcome = waitForChildExit(pid: childPID, timeout: 3) else {
      XCTFail("child did not exit after SIGINT was raised on the broker seam")
      return
    }
    XCTAssertEqual(
      ChildLauncher.exitStatus(waitResult: outcome.result, status: outcome.status), 0,
      "child should have exited cleanly from its SIGINT trap")
  }

  func testSIGTERMEscalatesToSIGKILLAfterGracePeriod() throws {
    // The child ignores SIGTERM outright, forcing the broker to escalate to
    // SIGKILL once the (shortened, test-only) grace period elapses.
    let childPID = try spawnShellChild(
      script: "trap '' TERM; sleep 5")

    retainedSources = installChildSignalSources(childPID: childPID, graceSeconds: 0.3)
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertEqual(Darwin.kill(getpid(), SIGTERM), 0)

    guard let outcome = waitForChildExit(pid: childPID, timeout: 3) else {
      XCTFail("child did not exit after SIGTERM/grace/SIGKILL sequence")
      return
    }
    XCTAssertEqual(
      ChildLauncher.exitStatus(waitResult: outcome.result, status: outcome.status), 128 + SIGKILL,
      "a TERM-ignoring child should die by SIGKILL once the grace period elapses")
  }

  func testSIGHUPTriggersGracefulTerminationOfChild() throws {
    // The child does not special-case SIGTERM, so the broker's first
    // (graceful) signal is enough; this proves SIGHUP reaches
    // terminateChildOrGroup at all, distinct from SIGINT's forward-only path.
    let childPID = try spawnShellChild(script: "sleep 5")

    retainedSources = installChildSignalSources(childPID: childPID, graceSeconds: 2)
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertEqual(Darwin.kill(getpid(), SIGHUP), 0)

    guard let outcome = waitForChildExit(pid: childPID, timeout: 3) else {
      XCTFail("child did not exit after SIGHUP was raised on the broker seam")
      return
    }
    XCTAssertEqual(
      ChildLauncher.exitStatus(waitResult: outcome.result, status: outcome.status), 128 + SIGTERM,
      "SIGHUP should trigger the graceful SIGTERM step without waiting out the grace period")
  }

  // MARK: - Helpers

  /// Spawns `/bin/sh -c script` as a real, independently-signalable process
  /// group leader via the same launcher the broker uses in production.
  private func spawnShellChild(script: String) throws -> pid_t {
    let configuration = try ChildLauncher.prepareConfiguration(
      command: ["/bin/sh", "-c", script],
      inheritedEnvironment: ["PATH": "/bin:/usr/bin"],
      agentControlURL: "unix:///proxy.sock")
    return try ChildLauncher.launch(configuration)
  }

  /// Polls for the child's exit with `WNOHANG`, pumping the main run loop
  /// between polls so `DispatchSourceSignal` handlers scheduled on
  /// `queue: .main` by `installChildSignalSources` get a chance to run.
  private func waitForChildExit(pid: pid_t, timeout: TimeInterval) -> (
    result: pid_t, status: Int32
  )? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        return (result, status)
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return nil
  }
}
