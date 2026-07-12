import Darwin
import Foundation
import XCTest

@testable import LabanAgent

final class DebugServerSocketPathTests: XCTestCase {
  func testShortCandidateIsUsedAsIs() {
    let candidate = URL(fileURLWithPath: "/tmp/laban-socket-path-tests-short", isDirectory: true)
    XCTAssertEqual(
      debugServerSocketPath(preferring: candidate),
      candidate.appendingPathComponent("control.sock").path)
  }

  func testOverlongCandidateFallsBackToAShortPath() {
    let addr = sockaddr_un()
    let limit = MemoryLayout.size(ofValue: addr.sun_path)
    let overlong = "/tmp/" + String(repeating: "x", count: limit + 20)
    let candidate = URL(fileURLWithPath: overlong, isDirectory: true)

    let result = debugServerSocketPath(preferring: candidate)

    XCTAssertLessThanOrEqual(result.utf8CString.count, limit)
    XCTAssertTrue(result.hasSuffix("/control.sock"))
    XCTAssertFalse(result.hasPrefix(overlong))
  }
}
