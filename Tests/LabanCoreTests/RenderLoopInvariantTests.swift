import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Invariants of the snapshot → render → mark_rendered render loop.
/// The dirty-bit race fix in `7f79c5c` introduced a per-snapshot dirty
/// mask and a mutation generation counter; these tests pin the load-
/// bearing properties of that lifecycle beyond the original race
/// regressions in `MarkRenderedSnapshotRaceTests`.
///
/// What was specifically *not* covered before the fix shipped:
///   - Multi-cycle behavior (repeated frames, not just one race).
///   - Mutation paths besides `feedOutput`: resize, replay, scroll.
///   - Multiple snapshots between two mark_rendered calls.
///   - Mark_rendered with no preceding snapshot (the inactive-tab path
///     in `TerminalSurfaceController`).
final class RenderLoopInvariantTests: XCTestCase {
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

  // MARK: - Multi-cycle steady state

  /// Three consecutive render cycles. Each cycle's mark_rendered must
  /// only clear rows from its own snapshot, leaving the next cycle's
  /// fresh feed dirty.
  func testThreeCyclesEachOnlyClearsItsOwnSnapshot() throws {
    let s = try session()
    defer { s.close() }

    for cycle in 0..<3 {
      let row = 5 + cycle * 2
      XCTAssertEqual(s.feedOutput(Array("\u{1B}[\(row + 1);1H#".utf8)), 0)
      guard let snap = s.snapshot() else {
        XCTFail("cycle \(cycle) snapshot")
        return
      }
      XCTAssertEqual(
        dirtyRows(of: snap)[row], 1,
        "cycle \(cycle): row \(row) should be dirty in its own snapshot")
      laban_snapshot_destroy(snap)
      XCTAssertEqual(s.markRendered(), 0)
      guard let after = s.snapshot() else {
        XCTFail("cycle \(cycle) post-mark snapshot")
        return
      }
      XCTAssertEqual(
        dirtyRows(of: after)[row], 0,
        "cycle \(cycle): row \(row) must be clean after mark_rendered")
      laban_snapshot_destroy(after)
    }
  }

  // MARK: - Mutation paths besides feedOutput

  /// Resize between snapshot and mark_rendered must bump the dirty
  /// generation so mark_rendered does not clear the snapshot's rows
  /// (the renderer drew against the pre-resize geometry; the post-
  /// resize state needs a fresh frame).
  func testResizeBetweenSnapshotAndMarkRenderedPreservesDirty() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[6;1H@".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snap1")
      return
    }
    XCTAssertEqual(dirtyRows(of: snap1)[5], 1)
    laban_snapshot_destroy(snap1)

    var newSize = LabanTerminalSize()
    newSize.rows = 24
    newSize.cols = 100
    XCTAssertEqual(s.resize(newSize), 0)

    XCTAssertEqual(s.markRendered(), 0)

    guard let snap2 = s.snapshot() else {
      XCTFail("snap2")
      return
    }
    let d2 = dirtyRows(of: snap2)
    laban_snapshot_destroy(snap2)
    XCTAssertTrue(
      d2.contains(1),
      "resize between snapshot and mark_rendered must leave rows dirty for next frame")
  }

  // MARK: - Multiple snapshots without intervening mark_rendered

  /// Two snapshots without a mark_rendered in between (e.g., a render
  /// retry pattern). The second snapshot's dirty mask must include
  /// rows touched after the first snapshot, and mark_rendered then
  /// clears against the *second* mask. Rows dirtied between snap1 and
  /// snap2 are part of snap2's render, so clearing them is correct.
  func testTwoSnapshotsBeforeMarkRenderedUsesLatestMask() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[4;1HA".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snap1")
      return
    }
    XCTAssertEqual(dirtyRows(of: snap1)[3], 1)
    laban_snapshot_destroy(snap1)

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[8;1HB".utf8)), 0)

    guard let snap2 = s.snapshot() else {
      XCTFail("snap2")
      return
    }
    let d2 = dirtyRows(of: snap2)
    laban_snapshot_destroy(snap2)
    XCTAssertEqual(d2[3], 1, "row 3 still dirty (snap1 didn't get mark_rendered)")
    XCTAssertEqual(d2[7], 1, "row 7 dirtied between snapshots, picked up by snap2")

    XCTAssertEqual(s.markRendered(), 0)

    guard let snap3 = s.snapshot() else {
      XCTFail("snap3")
      return
    }
    let d3 = dirtyRows(of: snap3)
    laban_snapshot_destroy(snap3)
    XCTAssertEqual(d3[3], 0, "row 3 was in snap2's mask, cleared")
    XCTAssertEqual(d3[7], 0, "row 7 was in snap2's mask, cleared")
  }

  // MARK: - Tab-switch / inactive-tab pattern

  /// API contract for the inactive-tab path in
  /// `TerminalSurfaceController.swift:282-297`: that code calls
  /// `renderDirty()` first, then `markRendered()` only when the
  /// query returned true. `renderDirty()` is what consumes the raw
  /// row-dirty bits into render state; mark_rendered then clears
  /// those render-state bits. The next `renderDirty()` returns
  /// false. The reverse order — mark_rendered before any consumer —
  /// is a no-op for visible dirty state, because the raw bits are
  /// still set and the next snapshot/renderDirty will re-derive
  /// them. This test pins both orderings so a future refactor can't
  /// silently transpose them.
  func testInactiveTabRenderDirtyThenMarkRenderedClearsCleanly() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[10;1HQ".utf8)), 0)
    XCTAssertTrue(
      s.renderDirty(),
      "renderDirty must report true after a feed, consuming raw row bits")
    XCTAssertEqual(s.markRendered(), 0)
    XCTAssertFalse(
      s.renderDirty(),
      "after renderDirty + markRendered, the inactive-tab pattern leaves nothing dirty")
  }

  func testMarkRenderedBeforeAnyConsumerIsANoOp() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[10;1HQ".utf8)), 0)
    XCTAssertEqual(s.markRendered(), 0)
    XCTAssertTrue(
      s.renderDirty(),
      "markRendered before any snapshot/renderDirty must not flush dirty state — raw bits stay set")
  }

  // MARK: - Race + resize composition

  /// Resize and parser feed both bump the mutation generation. When
  /// both happen between snapshot and mark_rendered, mark_rendered
  /// must still leave the screen marked dirty for the next frame.
  func testResizeAndRacingFeedBothPreserveDirty() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[2;1HX".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snap1")
      return
    }
    laban_snapshot_destroy(snap1)

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[15;1HY".utf8)), 0)
    var newSize = LabanTerminalSize()
    newSize.rows = 24
    newSize.cols = 90
    XCTAssertEqual(s.resize(newSize), 0)

    XCTAssertEqual(s.markRendered(), 0)

    XCTAssertTrue(
      s.renderDirty(),
      "render_dirty must report true after a snapshot that was raced by both a feed and a resize")
  }

  // MARK: - Empty-feed safety

  /// A zero-length feedOutput must not bump the generation in a way
  /// that causes mark_rendered to drop into the PARTIAL branch
  /// unnecessarily. Otherwise a polling loop that drains nothing
  /// would keep the screen marked dirty forever.
  func testEmptyFeedDoesNotForcePartialAfterMarkRendered() throws {
    let s = try session()
    defer { s.close() }

    XCTAssertEqual(s.feedOutput(Array("\u{1B}[3;1HZ".utf8)), 0)

    guard let snap1 = s.snapshot() else {
      XCTFail("snap1")
      return
    }
    laban_snapshot_destroy(snap1)

    XCTAssertEqual(s.feedOutput([]), 0)

    XCTAssertEqual(s.markRendered(), 0)

    XCTAssertFalse(
      s.renderDirty(),
      "render_dirty must be false after mark_rendered when only an empty feed raced in")
  }
}
