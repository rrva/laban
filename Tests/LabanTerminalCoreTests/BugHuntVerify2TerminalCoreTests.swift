import Darwin
import LabanTerminalCore
import XCTest

/// Bug-hunt 2026-10-05 finding #13 and the #17 OSC 10/11/12 minor,
/// reproduced against the C terminal core. Correct-behavior assertions are
/// wrapped in `XCTExpectFailure` so the suite stays green while each defect
/// exists and turns red once it is fixed.
final class BugHuntVerify2TerminalCoreTests: XCTestCase {

  // MARK: - #13 laban_session_resize int -> uint16 truncation

  func testBug13_ResizeTo70000ColumnsSilentlyTruncatesTo4464() throws {
    let session = try XCTUnwrap(makeFixtureSession())
    defer { laban_session_destroy(session) }

    var size = LabanTerminalSize()
    size.rows = 10
    size.cols = 70_000
    let rc = laban_session_resize(session, size)
    let cols = try snapshotCols(session)

    XCTExpectFailure("bug #13: 70000 is cast to uint16 (4464) and reported as success")
    XCTAssertTrue(
      rc != 0 || cols == 4096,
      "an out-of-range resize must fail or clamp; got rc=\(rc) cols=\(cols)")
  }

  func testBug13_ResizeWithNegativeRowsWrapsTo65535() throws {
    let session = try XCTUnwrap(makeFixtureSession())
    defer { laban_session_destroy(session) }

    var size = LabanTerminalSize()
    size.rows = -1
    size.cols = 10
    let rc = laban_session_resize(session, size)
    let rows = try snapshotRows(session)

    XCTExpectFailure("bug #13: rows=-1 wraps past the > 0 guard to 65535")
    XCTAssertTrue(
      rc != 0 || rows <= 4096,
      "a negative row count must be rejected; got rc=\(rc) rows=\(rows)")
  }

  // MARK: - #17 OSC 10/11/12 fallback drops multi-query

  /// xterm: `OSC 10 ; ? ; ?` queries foreground AND background (each extra
  /// param advances to the next dynamic color). With no configured colors the
  /// osc_host.c fallback only answers the first.
  func testBug17_OSCDynamicColorMultiQueryFallbackAnswersOnlyFirst() throws {
    let session = try XCTUnwrap(makeFixtureSession())
    defer { laban_session_destroy(session) }
    XCTAssertEqual(
      laban_session_set_color_scheme(session, Int32(LABAN_COLOR_SCHEME_DARK)), 0)

    writeBytes(session, Array("\u{1b}]10;?;?\u{07}".utf8))
    let reply = String(bytes: drainResponse(session), encoding: .utf8) ?? ""

    XCTAssertTrue(reply.contains("\u{1b}]10;rgb:ffff/ffff/ffff"), "got \(reply.debugDescription)")
    XCTExpectFailure("bug #17: fallback answers only OSC 10; the chained 11 query is dropped")
    XCTAssertTrue(
      reply.contains("\u{1b}]11;rgb:0000/0000/0000"),
      "the chained background query must be answered; got \(reply.debugDescription)")
  }

  // MARK: - Helpers

  private func makeFixtureSession() -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0 else { return nil }
    return session
  }

  private func writeBytes(_ session: OpaquePointer, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  private func drainResponse(_ session: OpaquePointer) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 512)
    var len: size_t = 0
    XCTAssertEqual(laban_session_drain_response(session, &buf, buf.count, &len), 0)
    return Array(buf.prefix(Int(len)))
  }

  private func snapshotCols(_ session: OpaquePointer) throws -> Int32 {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
    let s = try XCTUnwrap(snap)
    defer { laban_snapshot_destroy(s) }
    return s.pointee.cols
  }

  private func snapshotRows(_ session: OpaquePointer) throws -> Int32 {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(session, &snap), 0)
    let s = try XCTUnwrap(snap)
    defer { laban_snapshot_destroy(s) }
    return s.pointee.rows
  }
}
