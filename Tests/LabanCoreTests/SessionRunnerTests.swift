import LabanCore
import LabanTerminalCore
import XCTest
import os

final class SessionRunnerTests: XCTestCase {

  private func makeFixtureSession() throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return try Session(config: &config, size: size)
  }

  private func makeSleepingRealSession() throws -> Session {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return try Session.realShell(size: size, launchArgv: ["/bin/sleep", "0.2"])
  }

  func testFixtureSessionDoesNotCreateRunner() throws {
    let session = try makeFixtureSession()
    defer { session.close() }
    XCTAssertNil(session.makeRunner(onDirty: {}))
  }

  func testRunnerStopIsIdempotent() throws {
    let session = try makeSleepingRealSession()
    defer { session.close() }
    guard let runner = session.makeRunner(onDirty: {}) else {
      XCTFail("makeRunner returned nil")
      return
    }
    runner.start()
    Thread.sleep(forTimeInterval: 0.05)
    // Three back-to-back stop() calls must not deadlock. The idempotence latch
    // matters because AppModel.deinit calls stop() explicitly and the dictionary
    // tear-down then triggers SessionRunner.deinit which calls stop() again.
    runner.stop()
    runner.stop()
    runner.stop()
  }

  func testRunnerStopBeforeStartIsSafe() throws {
    let session = try makeSleepingRealSession()
    defer { session.close() }
    guard let runner = session.makeRunner(onDirty: {}) else {
      XCTFail("makeRunner returned nil")
      return
    }
    // Never started: stop() must short-circuit, not block forever waiting for a
    // thread that does not exist.
    runner.stop()
  }

  func testExitWakesOnDirtyWithNoOutput() throws {
    // A child that exits with zero output must fire onDirty WHILE the runner
    // loop is still running: pty_io.c bumps dirty_generation on the
    // status 0→nonzero transition, and the runner fires on any generation
    // advance, not only when drained > 0. This is the wake Milestone 3's
    // full park relies on for the "process exited" UI.
    //
    // The wait result MUST be captured before stop(): the reader thread
    // fires one final unconditional onDirty during teardown, so any
    // post-stop assertion is vacuous (it passes even with the exit bump
    // removed). Capturing the XCTWaiter result first makes this test fail
    // when the pty_io.c exit bump is disabled — verified by mutation.
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.realShell(
      size: size, launchArgv: ["/bin/sh", "-c", "exit 0"])
    defer { session.close() }

    let exitWake = expectation(description: "onDirty fires for zero-output child exit")
    // The teardown fire after stop() may fulfill a second time; that is
    // expected and must not crash the test.
    exitWake.assertForOverFulfill = false
    guard let runner = session.makeRunner(onDirty: { exitWake.fulfill() }) else {
      XCTFail("makeRunner returned nil for real session")
      return
    }
    runner.start()
    let result = XCTWaiter.wait(for: [exitWake], timeout: 3.0)
    runner.stop()
    XCTAssertEqual(
      result, .completed,
      "onDirty must fire for a zero-output child exit before stop()/teardown; "
        + "the pty_io.c exit-transition generation bump is the only wake source here")
  }

  func testRunnerOnDirtyFiresWhenRealShellOutputs() throws {
    // Build a real-shell session that prints something. Using the C API
    // directly because Session.realShell takes no argv.
    let exe = strdup("/bin/sh")!
    var ptrs: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sh"), strdup("-c"), strdup("printf hi; sleep 0.3"),
    ]
    ptrs.append(nil)
    defer {
      free(exe)
      for p in ptrs { if let p { free(p) } }
    }
    let count = ptrs.count
    var config = LabanLaunchConfig()
    config.executable = UnsafePointer(exe)
    config.fixture_mode = 0
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try ptrs.withUnsafeMutableBufferPointer { mbuf -> Session in
      try mbuf.baseAddress!.withMemoryRebound(
        to: UnsafePointer<CChar>?.self, capacity: count
      ) { rebound -> Session in
        config.argv = UnsafePointer(rebound)
        return try Session(config: &config, size: size)
      }
    }

    let calls = OSAllocatedUnfairLock(initialState: 0)
    guard
      let runner = session.makeRunner(onDirty: {
        calls.withLock { $0 += 1 }
      })
    else {
      XCTFail("makeRunner returned nil")
      return
    }
    runner.start()

    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
      if calls.withLock({ $0 }) > 0 { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
    runner.stop()
    XCTAssertGreaterThan(
      calls.withLock { $0 }, 0,
      "reader thread should have observed the shell's output and fired onDirty")
  }
}
