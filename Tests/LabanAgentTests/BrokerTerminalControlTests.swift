import Darwin
import Foundation
import XCTest

@testable import LabanAgent

/// Unit coverage for the broker's terminal-foreground handoff. The handoff
/// itself (`tcsetpgrp`) only works on the caller's *controlling* terminal,
/// which a unit test process does not have and cannot fabricate without a
/// fork (unavailable in the Swift Darwin overlay). The end-to-end behavior,
/// an interactive child under `laban agent run` staying in the foreground
/// instead of stopping on SIGTTIN, is proven by the live pty repro in
/// `scripts/test-broker-interactive-pty`. Here we lock in the guard that keeps
/// the non-tty launch path (CI, pipes, serve mode) a strict no-op, which is
/// the invariant that must never regress.
final class BrokerTerminalControlTests: XCTestCase {
  func testTakeForegroundIsNoOpAndDeclinesWhenNotATTY() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    defer {
      close(fds[0])
      close(fds[1])
    }
    // Off a tty the handoff must decline (return false) and touch nothing, so
    // a non-interactive `laban agent run` (piped stdin, CI) is unaffected.
    XCTAssertFalse(
      BrokerTerminalControl.takeForeground(pgid: getpgrp(), ttyFD: fds[0]),
      "takeForeground must be a no-op that returns false when the fd is not a terminal")
  }

  func testReclaimForegroundIsNoOpWhenNotATTY() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    defer {
      close(fds[0])
      close(fds[1])
    }
    // Must not crash, block, or send signals when there is no controlling tty.
    BrokerTerminalControl.reclaimForeground(ttyFD: fds[0])
  }
}
