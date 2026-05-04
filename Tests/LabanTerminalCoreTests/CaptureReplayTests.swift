import LabanTerminalCore
import XCTest

// Round-trips the PTY-byte capture file format: feed a known byte stream
// through one fixture session with capture enabled, then feed the captured
// file through a second fixture session and confirm the resulting grids
// match. This pins the on-disk format so future captures from interactive
// runs replay deterministically.
//
// Replay path used by bug-bisection: load a `.bin` capture, optionally
// truncate it to the first N bytes, feed it through `feed_output`, dump the
// grid. See `replayCaptureFile(...)` for the helper used by ad-hoc bisects.

final class CaptureReplayTests: XCTestCase {

  func testCaptureRoundTrip() throws {
    let captureURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("laban-capture-roundtrip-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: captureURL) }

    // ----- producer session -----
    let producer = makeFixtureSession(rows: 6, cols: 40)
    defer { laban_session_destroy(producer) }

    XCTAssertEqual(
      laban_session_capture_start(producer, captureURL.path), 0,
      "capture should open for write")
    XCTAssertEqual(laban_session_capture_active(producer), 1)

    let bytes: [UInt8] = Array(
      "hello\r\n\u{1B}[1;31mred line\u{1B}[0m\r\nthird line".utf8)
    feed(producer, bytes)
    XCTAssertEqual(laban_session_capture_stop(producer), 0)
    XCTAssertEqual(laban_session_capture_active(producer), 0)

    let producerGrid = gridText(producer)

    // ----- replay session -----
    let captured = try Data(contentsOf: captureURL)
    XCTAssertEqual(captured.count, bytes.count, "capture file size matches input")
    XCTAssertEqual(Array(captured), bytes, "capture file bytes match input")

    let replay = makeFixtureSession(rows: 6, cols: 40)
    defer { laban_session_destroy(replay) }
    feed(replay, Array(captured))

    let replayGrid = gridText(replay)
    XCTAssertEqual(
      producerGrid, replayGrid,
      "producer and replay grids must match after the same byte stream")
  }

  func testStopWithoutStartIsHarmless() {
    let s = makeFixtureSession(rows: 2, cols: 8)
    defer { laban_session_destroy(s) }
    XCTAssertEqual(laban_session_capture_active(s), 0)
    XCTAssertEqual(laban_session_capture_stop(s), 0)
  }

  func testCaptureCannotStartTwice() {
    let s = makeFixtureSession(rows: 2, cols: 8)
    defer { laban_session_destroy(s) }
    let p1 = NSTemporaryDirectory() + "laban-capture-1-\(UUID().uuidString).bin"
    let p2 = NSTemporaryDirectory() + "laban-capture-2-\(UUID().uuidString).bin"
    defer {
      try? FileManager.default.removeItem(atPath: p1)
      try? FileManager.default.removeItem(atPath: p2)
    }
    XCTAssertEqual(laban_session_capture_start(s, p1), 0)
    XCTAssertEqual(
      laban_session_capture_start(s, p2), -1,
      "second start without stop must fail")
    XCTAssertEqual(laban_session_capture_stop(s), 0)
  }

  // MARK: - Public-ish helper for ad-hoc capture replay

  /// Replays `captureURL` through a fixture session at `rows×cols` and
  /// returns a per-row text dump. Use from a one-off test to bisect a
  /// captured bug:
  ///
  ///   let grid = try CaptureReplayTests.replayCaptureFile(
  ///     URL(fileURLWithPath: "/path/to/capture.bin"), rows: 38, cols: 120)
  ///   print(grid)
  static func replayCaptureFile(
    _ captureURL: URL, rows: Int32, cols: Int32, byteLimit: Int? = nil
  ) throws -> String {
    var data = try Data(contentsOf: captureURL)
    if let limit = byteLimit, limit < data.count { data = data.prefix(limit) }

    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0, let s = session else {
      throw NSError(
        domain: "CaptureReplay", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "laban_session_create failed"])
    }
    defer { laban_session_destroy(s) }
    data.withUnsafeBytes { buf in
      _ = laban_session_write(
        s, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count)
    }
    return CaptureReplayTests.gridTextStatic(session: s)
  }

  // MARK: - Internals

  private func makeFixtureSession(rows: Int32, cols: Int32) -> OpaquePointer {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    let r = laban_session_create(&config, size, &session)
    precondition(r == 0, "laban_session_create failed")
    return session!
  }

  private func feed(_ session: OpaquePointer, _ bytes: [UInt8]) {
    _ = bytes.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
  }

  private func gridText(_ session: OpaquePointer) -> String {
    return CaptureReplayTests.gridTextStatic(session: session)
  }

  fileprivate static func gridTextStatic(session: OpaquePointer) -> String {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    precondition(laban_session_snapshot(session, &snap) == 0)
    defer { laban_snapshot_destroy(snap) }
    let s = snap!.pointee
    let rows = Int(s.rows)
    let cols = Int(s.cols)
    guard let cells = s.cells, let storage = s.utf8_storage else { return "" }
    var lines: [String] = []
    for row in 0..<rows {
      var line = ""
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        if cell.utf8_length > 0 {
          let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(cell.utf8_length))
          line += String(bytes: buf, encoding: .utf8) ?? " "
        } else {
          line += " "
        }
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}
