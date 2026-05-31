import LabanTerminalCore
import XCTest

/// Regression for the stuck overlay scroll indicator: a chatty non-alt-screen
/// app (Codex/Claude Code) streams output on Laban's reader thread while the
/// user is scrolled back. "Go to bottom" used to read the scrollbar, compute
/// `(total - len) - offset`, and scroll by that delta in a *separate* step —
/// two lock acquisitions. Output appended between them made the delta stale, so
/// the viewport landed short of the live bottom; because it was no longer
/// exactly at the bottom, libghostty never re-engaged follow-output and
/// `linesBack` stayed > 0, pinning the indicator on forever (typing re-lost the
/// same race). `laban_session_scroll_viewport_to_bottom` pins atomically under
/// one lock, so intervening output cannot wedge it short.
final class ScrollViewportToBottomAtomicTests: XCTestCase {

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

  /// Documents the bug the atomic primitive fixes: a delta read *before*
  /// intervening output, applied *after* it, lands short and never follows.
  func testStaleDeltaLandsShortWhenOutputStreamsBetweenReadAndScroll() {
    guard let session = makeFixtureSession(rows: 10, cols: 40) else {
      XCTFail("session create failed")
      return
    }
    defer { laban_session_destroy(session) }

    for i in 0..<200 { feed(session, "line-\(i)\r\n") }
    XCTAssertEqual(laban_session_scroll_viewport(session, -50), 0)

    // Read the delta the old two-step snap would have used...
    let beforeStream = vstate(session)
    let staleBottomOffset = max(0, Int(beforeStream.total_rows) - Int(beforeStream.viewport_rows))
    let staleDelta = staleBottomOffset - Int(beforeStream.viewport_offset)
    XCTAssertGreaterThan(staleDelta, 0)

    // ...then the reader thread appends output before the scroll is applied.
    for i in 200..<260 { feed(session, "line-\(i)\r\n") }

    // Applying the stale delta lands short of the now-moved live bottom.
    XCTAssertEqual(laban_session_scroll_viewport(session, Int32(staleDelta)), 0)
    let landed = linesBack(vstate(session))
    XCTAssertGreaterThan(
      landed, 0, "stale delta must land short of the live bottom (the indicator-stuck condition)")

    // And it stays stuck: more output grows linesBack, proving follow never
    // engaged.
    for i in 260..<300 { feed(session, "line-\(i)\r\n") }
    XCTAssertGreaterThan(
      linesBack(vstate(session)), landed, "short of bottom means output keeps moving it away")
  }

  /// The fix: pinning atomically reaches the live bottom even though output
  /// streamed after the user's last sample, and engages follow so it stays.
  func testAtomicScrollToBottomIgnoresInterveningOutputAndFollows() {
    guard let session = makeFixtureSession(rows: 10, cols: 40) else {
      XCTFail("session create failed")
      return
    }
    defer { laban_session_destroy(session) }

    for i in 0..<200 { feed(session, "line-\(i)\r\n") }
    XCTAssertEqual(laban_session_scroll_viewport(session, -50), 0)
    for i in 200..<260 { feed(session, "line-\(i)\r\n") }
    XCTAssertGreaterThan(
      linesBack(vstate(session)), 50, "output should have pushed the bottom away")

    var moved: Int32 = 0
    XCTAssertEqual(laban_session_scroll_viewport_to_bottom(session, &moved), 0)
    XCTAssertGreaterThan(moved, 0, "reports the rows the viewport moved")
    XCTAssertEqual(
      linesBack(vstate(session)), 0, "atomic pin lands on the live bottom despite the moved bottom")

    for i in 260..<300 { feed(session, "line-\(i)\r\n") }
    XCTAssertEqual(
      linesBack(vstate(session)), 0, "after the atomic pin, output must follow (viewport is active)"
    )
  }

  /// Already at the bottom: a no-op that reports zero movement and stays pinned.
  func testAtomicScrollToBottomIsNoopWhenAlreadyPinned() {
    guard let session = makeFixtureSession(rows: 10, cols: 40) else {
      XCTFail("session create failed")
      return
    }
    defer { laban_session_destroy(session) }

    for i in 0..<200 { feed(session, "line-\(i)\r\n") }
    XCTAssertEqual(linesBack(vstate(session)), 0, "starts pinned to the bottom")

    var moved: Int32 = -1
    XCTAssertEqual(laban_session_scroll_viewport_to_bottom(session, &moved), 0)
    XCTAssertEqual(moved, 0, "no movement when already at the live bottom")
    XCTAssertEqual(linesBack(vstate(session)), 0)
  }

  /// Defends the null-out-param contract the Swift wrapper relies on.
  func testAtomicScrollToBottomToleratesNilDeltaOut() {
    guard let session = makeFixtureSession(rows: 10, cols: 40) else {
      XCTFail("session create failed")
      return
    }
    defer { laban_session_destroy(session) }

    for i in 0..<50 { feed(session, "line-\(i)\r\n") }
    XCTAssertEqual(laban_session_scroll_viewport(session, -20), 0)
    XCTAssertEqual(laban_session_scroll_viewport_to_bottom(session, nil), 0)
    XCTAssertEqual(linesBack(vstate(session)), 0)
  }
}
