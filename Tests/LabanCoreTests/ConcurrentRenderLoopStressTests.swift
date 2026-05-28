import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Stress test the same multi-thread shape that produced the
/// dirty-bit race fixed in `7f79c5c`: one thread feeds bytes (the
/// parser-queue role from `LabptyParserFeed`) while another runs
/// the render loop (`snapshot → render → mark_rendered`, the main-
/// thread role from `TerminalBitmapView`). The single-threaded
/// race tests in `MarkRenderedSnapshotRaceTests` model the ordering
/// deterministically; this test exercises real concurrency over
/// many iterations to catch:
///   - any remaining race where mark_rendered drops a dirty row
///     the parser thread set after the snapshot
///   - the inverse: any path where mark_rendered fails to clear a
///     row the renderer did commit (would keep marking it dirty
///     forever, eating CPU)
///   - lock-ordering or recursion bugs introduced by future work
///     in the snapshot/mark_rendered/feed paths
///
/// The invariant: after the parser settles and one final render
/// cycle, the rendered bitmap must match the cell grid extracted
/// directly from a fresh fixture session fed the same bytes. The
/// "fresh fixture" is the ground truth — every byte produces the
/// same cell, regardless of how many race-induced re-renders the
/// stress session went through.
final class ConcurrentRenderLoopStressTests: XCTestCase {

  private let rows = 24
  private let cols = 80
  private let cellWidth = 8
  private let cellHeight = 16

  private func makeSize() -> LabanTerminalSize {
    var s = LabanTerminalSize()
    s.rows = Int32(rows)
    s.cols = Int32(cols)
    return s
  }

  private func renderBitmap(session: Session) -> BitmapSurface {
    guard let snap = session.snapshot() else {
      return BitmapSurface(width: 1, height: 1)
    }
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(
      cellWidth: cellWidth, cellHeight: cellHeight, originX: 0, originY: 0)
    let cmds = producer.commands(from: snap, cursorBlinkVisible: false)
    let backend = SoftwareBackend(
      fontAtlas: FontAtlas(),
      pixelWidth: cols * cellWidth, pixelHeight: rows * cellHeight, scale: 1)
    _ = backend.render(cmds, damage: .full)
    return backend.surface
  }

  /// Producer/consumer stress: a feeder thread emits a known
  /// sequence of CSI-positioned writes interleaved with a render
  /// loop on the test thread. The render loop snapshots, renders,
  /// and calls markRendered each iteration. After the feeder
  /// finishes, the test does one final render and asserts the
  /// bitmap matches a fresh fixture-session render of the same
  /// byte stream.
  func testConcurrentFeedAndRenderLoopConvergesToGroundTruth() throws {
    // Build a deterministic byte stream that touches many rows.
    // Each chunk writes a unique 8-char tag at a specific row so
    // that any "lost" feed shows as a missing tag in the final
    // grid — far easier to triage than an opaque pixel diff.
    var chunks: [[UInt8]] = []
    for row in 1...rows {
      let tag = "tag\(String(format: "%03d", row))_"  // 8 chars
      let seq = "\u{1B}[\(row);1H\(tag)"
      chunks.append(Array(seq.utf8))
    }
    // Run the stream several times so the feeder is alive long
    // enough for the render loop to overlap; later rounds overwrite
    // earlier tags at the same cells, so the final state is just
    // the last round's tags.
    let rounds = 50
    var feedQueue: [[UInt8]] = []
    feedQueue.reserveCapacity(chunks.count * rounds)
    for _ in 0..<rounds { feedQueue.append(contentsOf: chunks) }

    let stress = try Session.fixture(size: makeSize())
    defer { stress.close() }

    let feederDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async { [feedQueue, stress] in
      for chunk in feedQueue {
        _ = stress.feedOutput(chunk)
        // No sleep — let the scheduler interleave naturally. The
        // session lock serializes individual calls; the race lives
        // between snapshot and the next markRendered on the other
        // thread.
      }
      feederDone.signal()
    }

    // Render loop: spin until the feeder signals done, doing
    // snapshot+render+markRendered each iteration. This is exactly
    // the shape `TerminalBitmapView` runs.
    let renderDeadline = Date().addingTimeInterval(10)
    while feederDone.wait(timeout: .now()) == .timedOut {
      if Date() > renderDeadline {
        XCTFail("feeder did not finish in 10s")
        return
      }
      _ = renderBitmap(session: stress)
      _ = stress.markRendered()
    }

    // One final render cycle after the feeder is done, so any
    // dirty bits set just before the last loop iteration get
    // flushed to the bitmap. This is the load-bearing assertion:
    // the rendered bitmap after settle must match the ground truth.
    let stressFinal = renderBitmap(session: stress)

    // Ground truth: a fresh fixture fed the same complete stream
    // in one shot. The cell grid here is whatever libghostty
    // produces for the byte sequence, with no concurrency in the
    // way.
    let groundTruth = try Session.fixture(size: makeSize())
    defer { groundTruth.close() }
    for chunk in feedQueue {
      XCTAssertEqual(groundTruth.feedOutput(chunk), 0)
    }
    let groundTruthBitmap = renderBitmap(session: groundTruth)

    guard let diff = BitmapDiff.compare(stressFinal, groundTruthBitmap) else {
      XCTFail("bitmap dimensions differ")
      return
    }
    if !diff.isIdentical {
      BitmapDiffHarness.saveFailureArtifacts(
        label: "concurrent-render-convergence",
        expected: groundTruthBitmap,
        actual: stressFinal,
        diff: diff.diff,
        file: #file, line: #line)
    }
  }

  /// A stronger version of the same shape: instead of letting the
  /// render loop run "as fast as possible," every iteration of the
  /// render loop takes a snapshot, sleeps briefly to widen the race
  /// window, then calls markRendered. This is the worst case the
  /// fix has to handle — many feeds land between snapshot and
  /// markRendered each iteration. If the fix is correct, the final
  /// state still converges; if a row's dirty bit is dropped, the
  /// last few feeds for that row never repaint.
  func testWideRaceWindowStillConvergesToGroundTruth() throws {
    var chunks: [[UInt8]] = []
    for row in 1...rows {
      let tag = "row\(String(format: "%03d", row))!"  // 8 chars
      let seq = "\u{1B}[\(row);1H\(tag)"
      chunks.append(Array(seq.utf8))
    }
    let rounds = 30
    var feedQueue: [[UInt8]] = []
    for _ in 0..<rounds { feedQueue.append(contentsOf: chunks) }

    let stress = try Session.fixture(size: makeSize())
    defer { stress.close() }

    let feederDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async { [feedQueue, stress] in
      for chunk in feedQueue {
        _ = stress.feedOutput(chunk)
      }
      feederDone.signal()
    }

    let renderDeadline = Date().addingTimeInterval(15)
    while feederDone.wait(timeout: .now()) == .timedOut {
      if Date() > renderDeadline {
        XCTFail("feeder did not finish in 15s")
        return
      }
      _ = renderBitmap(session: stress)
      // Force a meaningful gap between snapshot and markRendered so
      // racing feeds have time to land. 200 µs is enough at the
      // feeder's speed to interleave several feeds inside the
      // window.
      usleep(200)
      _ = stress.markRendered()
    }

    let stressFinal = renderBitmap(session: stress)

    let groundTruth = try Session.fixture(size: makeSize())
    defer { groundTruth.close() }
    for chunk in feedQueue {
      XCTAssertEqual(groundTruth.feedOutput(chunk), 0)
    }
    let groundTruthBitmap = renderBitmap(session: groundTruth)

    guard let diff = BitmapDiff.compare(stressFinal, groundTruthBitmap) else {
      XCTFail("bitmap dimensions differ")
      return
    }
    if !diff.isIdentical {
      BitmapDiffHarness.saveFailureArtifacts(
        label: "wide-race-window-convergence",
        expected: groundTruthBitmap,
        actual: stressFinal,
        diff: diff.diff,
        file: #file, line: #line)
    }
  }
}
