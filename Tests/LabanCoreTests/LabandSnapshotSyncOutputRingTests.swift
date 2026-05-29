import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Regression for synchronized output (DEC private mode 2026) on the laband
/// multi-client tier. The daemon publishes a snapshot on every PTY drain — including
/// frames produced mid-update while the program holds synchronized output — and the
/// "synchronized output active" state must cross the snapshot ring so the app can
/// hold presentation (via TerminalRenderGate) instead of showing half-drawn frames.
/// Previously `slotFlags` never stamped the reserved `synchronizedOutput` bit, so the
/// state never reached clients and every mid-BSU frame tore.
///
/// This publishes a snapshot taken while mode 2026 is active and reads it back through
/// the ring, asserting the flag survives; a normal snapshot must not carry it.
final class LabandSnapshotSyncOutputRingTests: XCTestCase {

  func testSynchronizedOutputFlagCrossesTheRing() throws {
    XCTAssertTrue(
      try publishedSyncFlag(enable2026: true),
      "a snapshot taken during synchronized output must carry the flag across the ring")
    XCTAssertFalse(
      try publishedSyncFlag(enable2026: false),
      "a normal snapshot must not carry the synchronized-output flag")
  }

  private func publishedSyncFlag(enable2026: Bool) throws -> Bool {
    var size = LabanTerminalSize()
    size.rows = 6
    size.cols = 24
    let session = try Session.fixture(size: size)
    // ?2026h begins synchronized output; the snapshot taken now is a mid-update
    // frame the daemon would publish on its next drain.
    _ = session.write(Array((enable2026 ? "\u{1b}[?2026h" : "hello").utf8))
    _ = session.poll()
    XCTAssertEqual(session.synchronizedOutputActive, enable2026)

    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }

    let dir = ".tmp/sync-ring-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
    let writer = try LabandSnapshotRingWriter(
      path: "\(dir)/ring.bin",
      logicalSessionId: "sync-output-ring",
      incarnationId: "inc",
      maxRows: Int(size.rows),
      maxCols: Int(size.cols))
    try writer.publish(snapshot: snap)

    let reader = try LabandSnapshotRingReader(
      attachment: writer.attachment,
      logicalSessionId: "sync-output-ring",
      incarnationId: "inc")
    return try reader.latestSnapshot().synchronizedOutput ?? false
  }
}
