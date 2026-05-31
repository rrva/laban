import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Regression: pastes over labpty rendered with stale rows (digits
/// from paste content visibly persisting on the status row) until a
/// Ctrl-L forced a full redraw. Root cause: `laban_session_mark_rendered`
/// unconditionally clears every row's dirty bit, while the renderer's
/// `snapshot → render → mark_rendered` runs on the main thread and
/// `LabptyParserFeed.poll` feeds bytes on a separate queue. Any feed
/// that lands between the snapshot and the mark-rendered clears its
/// own dirty marks before the renderer has had a chance to commit
/// them, so those rows never get redrawn.
///
/// These tests pin the desired behavior: mark_rendered must only clear
/// the bits the renderer actually committed (i.e. the ones the
/// matching snapshot observed). Rows dirtied after that snapshot must
/// remain dirty so the next frame redraws them.
final class MarkRenderedSnapshotRaceTests: XCTestCase {
  private func session() throws -> Session {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    return try Session.fixture(size: size)
  }

  private func dirtyRows(of snap: UnsafeMutablePointer<LabanSnapshot>) -> [UInt8] {
    let s = snap.pointee
    guard let dirty = s.dirty_rows, s.dirty_row_count > 0 else { return [] }
    return Array(UnsafeBufferPointer(start: dirty, count: Int(s.dirty_row_count)))
  }

  /// The simulated race in single-threaded form:
  ///
  ///   1. feed row 10           (parser side, frame N-1)
  ///   2. snapshot              (main side, frame N — sees row 10)
  ///   3. feed row 11           (parser side, racing in)
  ///   4. mark_rendered         (main side, frame N commit)
  ///   5. snapshot              (main side, frame N+1)
  ///
  /// After step 4, the dirty bit for row 11 must still be set: row 11
  /// was modified after the frame-N snapshot, so the renderer has not
  /// committed those cells. The current implementation clears it
  /// unconditionally in step 4, which is the bug.
  func testRowDirtiedBetweenSnapshotAndMarkRenderedSurvives() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[11;1HABC".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snapshot 1")
      return
    }
    let dirty1 = dirtyRows(of: snap1)
    laban_snapshot_destroy(snap1)
    XCTAssertEqual(
      dirty1[10], 1,
      "row 10 should be dirty in snapshot taken after writing to it")

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[12;1HDEF".utf8)), 0)

    XCTAssertEqual(s.markRendered(), 0)

    guard let snap2 = s.snapshot() else {
      XCTFail("snapshot 2")
      return
    }
    let dirty2 = dirtyRows(of: snap2)
    laban_snapshot_destroy(snap2)
    XCTAssertEqual(
      dirty2[11], 1,
      "row 11 was dirtied after snap1 but before mark_rendered; it must remain dirty so the next frame redraws it"
    )
  }

  /// mark_rendered must still clear the rows that the matching
  /// snapshot observed as dirty — otherwise every frame would
  /// re-render the same rows forever.
  func testRowDirtiedBeforeSnapshotIsClearedByMarkRendered() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[5;1HXYZ".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snapshot 1")
      return
    }
    laban_snapshot_destroy(snap1)
    XCTAssertEqual(s.markRendered(), 0)

    guard let snap2 = s.snapshot() else {
      XCTFail("snapshot 2")
      return
    }
    let dirty2 = dirtyRows(of: snap2)
    laban_snapshot_destroy(snap2)
    XCTAssertEqual(
      dirty2[4], 0,
      "row 4 was dirty in snap1, which was rendered (mark_rendered), so the bit must be cleared")
  }

  /// If another dirty query/update runs after the racing feed but before
  /// mark_rendered, libghostty has already moved the parser's dirty mark into
  /// render state. mark_rendered still must not clear that row, because it was
  /// not part of the committed snapshot.
  func testRenderDirtyAfterRacingFeedStillSurvivesMarkRendered() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[11;1HABC".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snapshot 1")
      return
    }
    let dirty1 = dirtyRows(of: snap1)
    laban_snapshot_destroy(snap1)
    XCTAssertEqual(
      dirty1[10], 1,
      "row 10 should be dirty in snapshot taken after writing to it")

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[12;1HDEF".utf8)), 0)
    XCTAssertTrue(
      s.renderDirty(),
      "dirty query should observe the row dirtied after snap1")

    XCTAssertEqual(s.markRendered(), 0)

    guard let snap2 = s.snapshot() else {
      XCTFail("snapshot 2")
      return
    }
    let dirty2 = dirtyRows(of: snap2)
    laban_snapshot_destroy(snap2)
    XCTAssertEqual(
      dirty2[11], 1,
      "row 11 was dirtied after snap1 and observed before mark_rendered; it still must remain dirty"
    )
  }

  /// Across many micro-feeds interleaved with one snapshot/mark cycle,
  /// every row that received any byte after the snapshot must remain
  /// dirty.
  func testManyRacingFeedsAllSurviveMarkRendered() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[1;1HHEAD".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snapshot 1")
      return
    }
    laban_snapshot_destroy(snap1)

    let racingRows = [5, 7, 12, 19, 22]
    for row in racingRows {
      let seq = "\u{1B}[\(row + 1);1HRACE"
      XCTAssertEqual(s.feedOutput(Array(seq.utf8)), 0)
    }

    XCTAssertEqual(s.markRendered(), 0)

    guard let snap2 = s.snapshot() else {
      XCTFail("snapshot 2")
      return
    }
    let dirty2 = dirtyRows(of: snap2)
    laban_snapshot_destroy(snap2)
    for row in racingRows {
      XCTAssertEqual(
        dirty2[row], 1,
        "row \(row) was raced between snapshot and mark_rendered and must remain dirty")
    }
  }
}
