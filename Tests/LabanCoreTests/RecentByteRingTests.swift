import Foundation
import XCTest

@testable import LabanCore

final class RecentByteRingTests: XCTestCase {

  func testRecordsAndSnapshotsInOrder() {
    let ring = RecentByteRing(byteCapacity: 4096, headerCapacity: 16)
    write(ring: ring, string: "hello ")
    write(ring: ring, string: "world\r\n")
    let snapshot = ring.snapshot(window: 10)
    XCTAssertEqual(snapshot.count, 2)
    XCTAssertEqual(snapshot[0].bytes, Array("hello ".utf8))
    XCTAssertEqual(snapshot[1].bytes, Array("world\r\n".utf8))
    XCTAssertLessThanOrEqual(snapshot[0].timestampNanos, snapshot[1].timestampNanos)
  }

  func testTimestampsAreMonotonicAndDistinctEnoughForOrdering() {
    let ring = RecentByteRing()
    for _ in 0..<5 {
      write(ring: ring, string: "x")
    }
    let snapshot = ring.snapshot(window: 60)
    XCTAssertEqual(snapshot.count, 5)
    for i in 1..<snapshot.count {
      XCTAssertGreaterThanOrEqual(
        snapshot[i].timestampNanos, snapshot[i - 1].timestampNanos)
    }
  }

  func testByteRingOverflowDropsOldestChunks() {
    // Capacity is tight enough that the third 100-byte chunk
    // overwrites the bytes the first chunk owns. The first chunk's
    // header should be evicted so snapshot returns only the
    // surviving entries.
    let ring = RecentByteRing(byteCapacity: 256, headerCapacity: 16)
    write(ring: ring, bytes: Array(repeating: UInt8(ascii: "A"), count: 100))
    write(ring: ring, bytes: Array(repeating: UInt8(ascii: "B"), count: 100))
    write(ring: ring, bytes: Array(repeating: UInt8(ascii: "C"), count: 100))
    let snapshot = ring.snapshot(window: 60)
    XCTAssertEqual(snapshot.count, 2, "oldest chunk should be evicted")
    XCTAssertEqual(snapshot[0].bytes.first, UInt8(ascii: "B"))
    XCTAssertEqual(snapshot[1].bytes.first, UInt8(ascii: "C"))
  }

  func testSingleOverflowChunkRetainsTrailingTail() {
    let ring = RecentByteRing(byteCapacity: 32, headerCapacity: 8)
    let big = (UInt8(ascii: "0")...UInt8(ascii: "9")).flatMap {
      Array(repeating: $0, count: 10)
    }
    write(ring: ring, bytes: big)
    let snapshot = ring.snapshot(window: 60)
    XCTAssertEqual(snapshot.count, 1)
    XCTAssertEqual(snapshot[0].bytes.count, 32, "only the trailing 32 bytes survive")
    XCTAssertEqual(snapshot[0].bytes.first, UInt8(ascii: "6"))
    XCTAssertEqual(snapshot[0].bytes.last, UInt8(ascii: "9"))
  }

  func testWindowExcludesOlderEntries() {
    let ring = RecentByteRing()
    write(ring: ring, string: "old")
    Thread.sleep(forTimeInterval: 0.05)
    write(ring: ring, string: "new")
    let recent = ring.snapshot(window: 0.02)
    // Only the second chunk should survive a 20 ms window.
    XCTAssertEqual(recent.count, 1)
    XCTAssertEqual(recent[0].bytes, Array("new".utf8))
  }

  func testCastWindowSnapshotSplitsInitialReplayEntriesFromTimedEntries() {
    let ring = RecentByteRing()
    write(ring: ring, string: "old")
    Thread.sleep(forTimeInterval: 0.05)
    write(ring: ring, string: "new")

    let snapshot = ring.castWindowSnapshot(window: 0.02)
    XCTAssertEqual(snapshot.initialEntries.map(\.bytes), [Array("old".utf8)])
    XCTAssertEqual(snapshot.entries.map(\.bytes), [Array("new".utf8)])
  }

  func testInvalidWindowDoesNotTrap() {
    // Regression for C-1: /debug/cast/recent forwards a caller-controlled
    // `seconds` to the ring. Negative / NaN / inf / overflowing windows
    // must clamp to "include everything" instead of trapping the process.
    let ring = RecentByteRing()
    write(ring: ring, string: "hello")
    for window in [
      -1.0, -0.0001, .nan, .infinity, -.infinity, 1e20, Double.greatestFiniteMagnitude,
    ] {
      let cast = ring.castWindowSnapshot(window: window)
      XCTAssertEqual(
        cast.initialEntries.count + cast.entries.count, 1,
        "window \(window) should not drop or duplicate the recorded chunk")
      let snap = ring.snapshot(window: window)
      XCTAssertEqual(snap.count, 1, "window \(window) should not trap snapshot()")
    }
  }

  func testHeaderRingOverflowDropsOldestHeaders() {
    let ring = RecentByteRing(byteCapacity: 4096, headerCapacity: 4)
    for i in 0..<6 {
      write(ring: ring, string: "\(i)")
    }
    let snapshot = ring.snapshot(window: 60)
    XCTAssertEqual(snapshot.count, 4)
    XCTAssertEqual(snapshot[0].bytes, Array("2".utf8))
    XCTAssertEqual(snapshot[3].bytes, Array("5".utf8))
  }

  func testConcurrentRecordAndSnapshotDoNotCorrupt() {
    let ring = RecentByteRing(byteCapacity: 64 * 1024, headerCapacity: 8192)
    let bytes = Array("abc".utf8)
    let writers = DispatchQueue(label: "ring.writers", attributes: .concurrent)
    let group = DispatchGroup()
    for _ in 0..<200 {
      group.enter()
      writers.async {
        bytes.withUnsafeBufferPointer { buf in
          ring.record(bytes: buf.baseAddress!, count: buf.count)
        }
        group.leave()
      }
    }
    // Snapshot repeatedly from another queue while writes are in
    // flight. The point of this test is not exact counts but
    // absence of crashes/asan-detectable corruption.
    let readers = DispatchQueue(label: "ring.readers")
    for _ in 0..<50 {
      readers.async {
        _ = ring.snapshot(window: 5)
      }
    }
    group.wait()
    let final = ring.snapshot(window: 5)
    XCTAssertGreaterThan(final.count, 0)
  }

  // MARK: - Helpers

  private func write(ring: RecentByteRing, string: String) {
    write(ring: ring, bytes: Array(string.utf8))
  }

  private func write(ring: RecentByteRing, bytes: [UInt8]) {
    bytes.withUnsafeBufferPointer { buf in
      ring.record(bytes: buf.baseAddress!, count: buf.count)
    }
  }
}
