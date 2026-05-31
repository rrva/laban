import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Disabled in normal CI; opt in via:
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter TerminalCellPayloadAllocationBench
///
/// This gates the payload builder's retained-storage contract. The warmed
/// one-dirty-row path must not grow any payload arrays; ASCII glyph cells also
/// stay on the scalar fast path and do not materialize per-cell String text.
final class TerminalCellPayloadAllocationBench: XCTestCase {
  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  func testOneDirtyRowPayloadHasZeroWarmStorageGrowth() throws {
    guard enabled() else { return }
    #if DEBUG
      throw XCTSkip("allocation bench must run with -c release")
    #else
      var size = LabanTerminalSize()
      size.rows = 48
      size.cols = 160
      let session = try Session.fixture(size: size)
      defer { session.close() }

      _ = session.write(Array(String(repeating: "A", count: Int(size.cols)).utf8))
      _ = session.poll()
      let snap = try XCTUnwrap(session.snapshot())
      defer { laban_snapshot_destroy(snap) }

      let producer = FrameProducer(
        cellWidth: 9,
        cellHeight: 19,
        originX: 0,
        originY: 0,
        contentYOffset: 0)
      var payload = TerminalCellPayload(
        rows: Int(size.rows),
        cols: Int(size.cols),
        origin: .zero,
        cellSize: CGSize(width: 9, height: 19),
        contentYOffset: 0,
        defaultBackground: snap.pointee.default_background_rgba)

      let dirtyRows = [0]
      producer.fillTerminalCellPayload(
        into: &payload,
        from: UnsafePointer(snap),
        includedRows: dirtyRows,
        cursorBlinkVisible: false)
      let warmed = payload.capacitySnapshot

      var storageGrowthEvents = 0
      let iterations = 10_000
      let start = ContinuousClock.now
      for _ in 0..<iterations {
        let before = payload.capacitySnapshot
        producer.fillTerminalCellPayload(
          into: &payload,
          from: UnsafePointer(snap),
          includedRows: dirtyRows,
          cursorBlinkVisible: false)
        storageGrowthEvents += before.storageGrowthEvents(to: payload.capacitySnapshot)
      }
      let elapsed = ContinuousClock.now - start
      let elapsedMs = Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1e15
      print(
        String(
          format:
            "\n=== TerminalCellPayload allocation bench ===\n  one dirty row: iterations=%d storageGrowthEvents=%d total=%.3f ms perFrame=%.3f us capacities=%@\n",
          iterations,
          storageGrowthEvents,
          elapsedMs,
          elapsedMs * 1000 / Double(iterations),
          String(describing: warmed)))

      XCTAssertEqual(storageGrowthEvents, 0)
      XCTAssertEqual(payload.capacitySnapshot, warmed)
      XCTAssertEqual(payload.dirtyRows, dirtyRows)
      XCTAssertNil(payload.fallbackReason)
    #endif
  }
}

private extension TerminalCellPayload.CapacitySnapshot {
  func storageGrowthEvents(to next: Self) -> Int {
    [
      next.dirtyRows > dirtyRows,
      next.backgroundRuns > backgroundRuns,
      next.glyphs > glyphs,
      next.cursorRects > cursorRects,
      next.utf8Bytes > utf8Bytes,
    ].filter { $0 }.count
  }
}
