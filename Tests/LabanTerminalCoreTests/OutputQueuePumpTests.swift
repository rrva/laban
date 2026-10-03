import Foundation
import LabanTerminalCore
import XCTest

/// ADR 0040: a PTY-backed session pumps its ordered output queue from the
/// drain loop as the child reads, so a multi-megabyte clipboard reply reaches
/// the child whole instead of being cut off by the 20 ms bounded PTY write.
final class OutputQueuePumpTests: XCTestCase {
  func testQueuedOutputReachesTheChildWhole() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-queue-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let outPath = dir.appendingPathComponent("out").path
    let total = 2_000_000
    let script = "stty raw -echo; head -c \(total) > '\(outPath)'"

    let exe = strdup("/bin/sh")!
    var argv: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sh"), strdup("-c"), strdup(script), nil,
    ]
    let argvCount = argv.count
    defer {
      free(exe)
      for p in argv where p != nil { free(p) }
    }
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    var config = LabanLaunchConfig()
    let session: OpaquePointer? = argv.withUnsafeMutableBufferPointer { argvBuf in
      argvBuf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: argvCount) {
        config.executable = UnsafePointer(exe)
        config.argv = UnsafePointer($0)
        var s: OpaquePointer?
        return laban_session_create(&config, size, &s) == 0 ? s : nil
      }
    }
    let s = try XCTUnwrap(session)
    defer { laban_session_destroy(s) }

    // Let `stty raw` take effect before the payload arrives.
    let settle = Date().addingTimeInterval(0.5)
    while Date() < settle { _ = laban_session_poll_blocking(s, 50) }

    let payload = (0..<total).map { UInt8(truncatingIfNeeded: $0 % 251) }
    XCTAssertEqual(
      payload.withUnsafeBufferPointer { laban_session_queue_output(s, $0.baseAddress, $0.count) },
      0)

    let deadline = Date().addingTimeInterval(15)
    var written = 0
    while Date() < deadline {
      _ = laban_session_poll_blocking(s, 50)
      written = (try? FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int) ?? 0
      if written >= total { break }
    }
    XCTAssertEqual(written, total)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outPath)), Data(payload))
    var pending: Int32 = 1
    XCTAssertEqual(laban_session_has_queued_output(s, &pending), 0)
    XCTAssertEqual(pending, 0)
  }
}
