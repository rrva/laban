import Darwin
import LabanTerminalCore
import XCTest
import os

final class LabanSessionPollBlockingTests: XCTestCase {

  private func makeFixtureSession() -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    var session: OpaquePointer?
    return laban_session_create(&config, size, &session) == 0 ? session : nil
  }

  /// Wraps a real-shell session creation in the same retain/free
  /// dance the existing tests use (see `LabanSessionTests.swift`).
  /// Caller owns the returned session and must `laban_session_destroy`.
  private func makeRealShellSession(argv: [String]) -> OpaquePointer? {
    let exe = strdup("/bin/sh")!
    var mptrs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    mptrs.append(nil)
    defer {
      free(exe)
      for p in mptrs { if let p { free(p) } }
    }
    let count = mptrs.count
    var session: OpaquePointer?
    let rc = mptrs.withUnsafeMutableBufferPointer { mbuf -> Int32 in
      mbuf.baseAddress!.withMemoryRebound(
        to: UnsafePointer<CChar>?.self, capacity: count
      ) { rebound -> Int32 in
        var config = LabanLaunchConfig()
        config.executable = UnsafePointer(exe)
        config.argv = UnsafePointer(rebound)
        config.fixture_mode = 0
        var size = LabanTerminalSize()
        size.rows = 24
        size.cols = 80
        return laban_session_create(&config, size, &session)
      }
    }
    return rc == 0 ? session : nil
  }

  func testPollBlockingShortCircuitsForFixtureSessions() {
    guard let s = makeFixtureSession() else { XCTFail("create"); return }
    defer { laban_session_destroy(s) }
    let start = Date()
    let n = laban_session_poll_blocking(s, 200)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(n, 0, "fixture session has no PTY; must return 0")
    XCTAssertLessThan(
      elapsed, 0.05,
      "fixture path must short-circuit before select; observed \(elapsed)s")
  }

  func testPollBlockingReturnsZeroOnTimeoutForRealShell() {
    guard let s = makeRealShellSession(argv: ["/bin/sh", "-c", "sleep 1"]) else {
      XCTFail("create")
      return
    }
    defer { laban_session_destroy(s) }
    /* Drain any startup output the shell may have emitted (typically
     * nothing for /bin/sh -c, but the kernel may surface the PTY's
     * winsize ack as readable). */
    while laban_session_poll_blocking(s, 50) > 0 {}
    let start = Date()
    let n = laban_session_poll_blocking(s, 80)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(n, 0)
    XCTAssertGreaterThan(
      elapsed, 0.04,
      "must actually wait roughly the requested timeout; observed \(elapsed)s")
    XCTAssertLessThan(
      elapsed, 0.5,
      "must return promptly after the timeout; observed \(elapsed)s")
  }

  func testPollBlockingDrainsAvailableBytesFromRealShell() {
    /* Print 11 bytes, hold the PTY open briefly so the read survives
     * the SIGHUP-on-close dance. */
    let argv = ["/bin/sh", "-c", "printf hello-readme; sleep 0.5"]
    guard let s = makeRealShellSession(argv: argv) else {
      XCTFail("create")
      return
    }
    defer { laban_session_destroy(s) }

    var totalDrained = 0
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline && totalDrained < 11 {
      let n = laban_session_poll_blocking(s, 200)
      if n > 0 { totalDrained += Int(n) }
      if n < 0 { break }
    }
    XCTAssertGreaterThanOrEqual(
      totalDrained, 11,
      "must observe the 11-byte 'hello-readme' written by the shell")
  }

  func testConcurrentSnapshotAndPollBlockingDoNotRace() {
    /* Generate a steady byte stream so both the poller and the
     * snapper are exercising real code paths under contention. The
     * `yes` builtin emits ~100 KB/s into the PTY, with the per-poll
     * cap kicking in. */
    let argv = ["/bin/sh", "-c", "i=0; while [ $i -lt 800 ]; do echo line-$i; i=$((i+1)); done; sleep 0.2"]
    guard let s = makeRealShellSession(argv: argv) else {
      XCTFail("create")
      return
    }

    let stop = OSAllocatedUnfairLock(initialState: false)
    let pollerDone = expectation(description: "poller exits")
    let snapperDone = expectation(description: "snapper exits")
    let writerDone = expectation(description: "writer exits")

    let poller = Thread {
      while !stop.withLock({ $0 }) {
        let n = laban_session_poll_blocking(s, 25)
        if n < 0 { break }
      }
      pollerDone.fulfill()
    }
    let snapper = Thread {
      while !stop.withLock({ $0 }) {
        var snap: UnsafeMutablePointer<LabanSnapshot>?
        if laban_session_snapshot(s, &snap) == 0, let snap {
          laban_snapshot_destroy(snap)
        }
      }
      snapperDone.fulfill()
    }
    /* A third thread that mutates: feed_output writes through the
     * VT parser, which exercises a different path than poll's read. */
    let writer = Thread {
      let probe = Array("\u{1B}]2;probe\u{07}".utf8)
      var i = 0
      while !stop.withLock({ $0 }) {
        _ = probe.withUnsafeBufferPointer { buf in
          laban_session_feed_output(s, buf.baseAddress, buf.count)
        }
        i += 1
        if i % 100 == 0 { Thread.sleep(forTimeInterval: 0.001) }
      }
      writerDone.fulfill()
    }

    poller.start()
    snapper.start()
    writer.start()
    Thread.sleep(forTimeInterval: 0.5)
    stop.withLock { $0 = true }
    wait(for: [pollerDone, snapperDone, writerDone], timeout: 3.0)

    laban_session_destroy(s)
  }
}
