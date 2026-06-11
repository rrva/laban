import LabanTerminalCore
import XCTest

/// Throwaway micro-benchmark for the laban_vt_write_capture scanner path.
/// Run manually: swift test --filter ScanThroughputBench
/// Not asserting on time — prints throughput for before/after comparison.
final class ScanThroughputBench: XCTestCase {

  private func makeFixtureSession() -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 50
    size.cols = 200
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0 else { return nil }
    return session
  }

  func testPlainTextFloodThroughput() throws {
    let session = try XCTUnwrap(makeFixtureSession())
    defer { laban_session_destroy(session) }
    // Activate the gated scanners like the app does.
    laban_session_set_tab_status_callback(session, { _, _, _, _, _ in }, nil)
    laban_session_set_osc133_callback(session, { _, _, _, _, _ in }, nil)

    // 8 KiB chunk of plain text with newlines, no ESC anywhere.
    var chunk = [UInt8]()
    chunk.reserveCapacity(8192)
    while chunk.count < 8128 {
      chunk.append(contentsOf: Array("lorem ipsum dolor sit amet 0123456789 ".utf8))
    }
    chunk.append(contentsOf: Array("\r\n".utf8))

    let totalBytes = 256 * 1024 * 1024
    let iterations = totalBytes / chunk.count
    let start = ContinuousClock.now
    for _ in 0..<iterations {
      let rc = chunk.withUnsafeBufferPointer {
        laban_session_feed_output(session, $0.baseAddress, $0.count)
      }
      XCTAssertEqual(rc, 0)
    }
    let elapsed = (ContinuousClock.now - start)
    let secs =
      Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    let mbps = Double(iterations * chunk.count) / 1024 / 1024 / secs
    print(
      "BENCH plain-text: \(String(format: "%.2f", secs))s, \(String(format: "%.1f", mbps)) MiB/s")
  }

  func testEscHeavyThroughput() throws {
    let session = try XCTUnwrap(makeFixtureSession())
    defer { laban_session_destroy(session) }
    laban_session_set_tab_status_callback(session, { _, _, _, _, _ in }, nil)
    laban_session_set_osc133_callback(session, { _, _, _, _, _ in }, nil)

    // Realistic colored-build-log style: SGR sequences sprinkled through text.
    var chunk = [UInt8]()
    while chunk.count < 8128 {
      chunk.append(contentsOf: Array("\u{1B}[32mok\u{1B}[0m compiling module xyz ".utf8))
    }
    chunk.append(contentsOf: Array("\r\n".utf8))

    let totalBytes = 64 * 1024 * 1024
    let iterations = totalBytes / chunk.count
    let start = ContinuousClock.now
    for _ in 0..<iterations {
      let rc = chunk.withUnsafeBufferPointer {
        laban_session_feed_output(session, $0.baseAddress, $0.count)
      }
      XCTAssertEqual(rc, 0)
    }
    let elapsed = (ContinuousClock.now - start)
    let secs =
      Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    let mbps = Double(iterations * chunk.count) / 1024 / 1024 / secs
    print(
      "BENCH esc-heavy: \(String(format: "%.2f", secs))s, \(String(format: "%.1f", mbps)) MiB/s")
  }
}
