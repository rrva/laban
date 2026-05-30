import Darwin
import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// M-5: the laband multi-client tier can call `terminateSession` (→ `close()`,
/// which runs `laban_session_destroy`) on one connection thread while another
/// connection thread is mid-`write`/`snapshot`/`resize` on the same session.
/// `Session`'s `handle`/`isClosed` were plain unsynchronized vars, so this is a
/// data race and, when `close()` destroys the handle mid-C-call, a use-after-free.
///
/// Run under `swift test --sanitize=thread` (flags the unsynchronized access
/// regardless of timing) or `--sanitize=address` (catches the UAF when a
/// destroy lands inside a concurrent C call). With the in-flight guard the
/// sanitizer is clean and every post-close op is a no-op returning its fallback.
final class SessionConcurrencyTests: XCTestCase {
  func testConcurrentCloseDoesNotRaceHandleUse() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80

    for _ in 0..<40 {
      let session = try Session.fixture(size: size)
      let group = DispatchGroup()

      // Hammer the handle-using methods from one thread...
      group.enter()
      DispatchQueue.global().async {
        for _ in 0..<3000 {
          _ = session.write(Array("x".utf8))
          if let snap = session.snapshot() { laban_snapshot_destroy(snap) }
          _ = session.poll()
          _ = session.renderDirty()
          _ = session.resize(size)
        }
        group.leave()
      }

      // ...while another thread closes it out from under those calls.
      group.enter()
      DispatchQueue.global().async {
        for _ in 0..<200 {
          if let snap = session.snapshot() { laban_snapshot_destroy(snap) }
        }
        session.close()
        group.leave()
      }

      group.wait()
      session.close()  // idempotent
    }
  }
}
