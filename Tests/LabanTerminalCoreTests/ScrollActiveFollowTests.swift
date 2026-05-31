import LabanTerminalCore
import XCTest

/// Guards the libghostty viewport invariant Laban's scroll-to-bottom relies on:
/// scrolling down by exactly the live delta-to-active-bottom must land on the
/// *active* viewport (which follows new output), not on a boundary pin that
/// would let `linesBack` grow again on the next byte. `snapScrollToActiveBottom`
/// in `TerminalBitmapView` depends on this so a non-alt-screen app's overlay
/// scroll indicator hides at the bottom even after output streamed while the
/// user was scrolled back. If an upstream libghostty-vt pin bump (ADR 0004)
/// changes delta-scroll clamping, this test catches it.
final class ScrollActiveFollowTests: XCTestCase {

  private func makeFixtureSession(rows: Int32, cols: Int32) -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0 else { return nil }
    return session
  }

  private func feed(_ session: OpaquePointer, _ s: String) {
    let bytes = Array(s.utf8)
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  private func vstate(_ session: OpaquePointer) -> LabanViewportState {
    var vs = LabanViewportState()
    XCTAssertEqual(laban_session_viewport_state(session, &vs), 0)
    return vs
  }

  private func linesBack(_ vs: LabanViewportState) -> Int {
    let bottomOffset = max(0, Int(vs.total_rows) - Int(vs.viewport_rows))
    return max(0, bottomOffset - Int(vs.viewport_offset))
  }

  func testExactDeltaToBottomEngagesActiveFollow() {
    guard let session = makeFixtureSession(rows: 10, cols: 40) else {
      XCTFail("session create failed")
      return
    }
    defer { laban_session_destroy(session) }

    for i in 0..<200 { feed(session, "line-\(i)\r\n") }
    // Scroll up into history, then stream more output (the live bottom moves
    // away while we stay pinned in scrollback).
    XCTAssertEqual(laban_session_scroll_viewport(session, -50), 0)
    for i in 200..<260 { feed(session, "line-\(i)\r\n") }
    let scrolled = vstate(session)
    XCTAssertGreaterThan(linesBack(scrolled), 50, "output should have pushed the bottom away")

    // Scroll down by exactly the live delta-to-bottom.
    let bottomOffset = max(0, Int(scrolled.total_rows) - Int(scrolled.viewport_rows))
    let toBottom = bottomOffset - Int(scrolled.viewport_offset)
    XCTAssertEqual(laban_session_scroll_viewport(session, Int32(toBottom)), 0)
    XCTAssertEqual(linesBack(vstate(session)), 0, "exact delta must land on the live bottom")

    // The decisive check: new output must keep us pinned, proving the viewport
    // is active (following) and not a stale boundary pin.
    for i in 260..<300 { feed(session, "line-\(i)\r\n") }
    XCTAssertEqual(
      linesBack(vstate(session)), 0,
      "after the exact-delta snap, output must follow (viewport is active)")
  }
}
