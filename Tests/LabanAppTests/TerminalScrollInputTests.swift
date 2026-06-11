import CoreGraphics
import Foundation
import XCTest

@testable import LabanApp

final class TerminalScrollInputTests: XCTestCase {

  // MARK: - Unit cases

  func testZeroPixelEventProducesNoRowDeltaAndNoResidualChange() {
    let d = TerminalScrollInput.decide(
      event: .init(deltaY: 0, scrollingDeltaY: 0, hasPreciseScrollingDeltas: true),
      residualPx: 7,
      cellHeightPx: 24
    )
    XCTAssertEqual(d.rowsDelta, 0)
    XCTAssertEqual(d.newResidualPx, 7)
  }

  func testSubCellPositiveDeltaAccumulatesIntoResidualWithoutScrolling() {
    let d = TerminalScrollInput.decide(
      event: .init(deltaY: 0, scrollingDeltaY: 8, hasPreciseScrollingDeltas: true),
      residualPx: 0,
      cellHeightPx: 24
    )
    XCTAssertEqual(d.rowsDelta, 0)
    XCTAssertEqual(d.newResidualPx, 8)
  }

  func testAccumulatedResidualEmitsUpwardRowOnceCellHeightCrossed() {
    let d = TerminalScrollInput.decide(
      event: .init(deltaY: 0, scrollingDeltaY: 7, hasPreciseScrollingDeltas: true),
      residualPx: 18,
      cellHeightPx: 24
    )
    XCTAssertEqual(d.rowsDelta, -1)
    XCTAssertEqual(d.newResidualPx, 1)
  }

  func testNonPreciseDeviceUsesLineDeltaScaledByCellHeight() {
    let d = TerminalScrollInput.decide(
      event: .init(deltaY: 1, scrollingDeltaY: 0, hasPreciseScrollingDeltas: false),
      residualPx: 0,
      cellHeightPx: 24
    )
    XCTAssertEqual(d.rowsDelta, -1)
    XCTAssertEqual(d.newResidualPx, 0)
  }

  func testNegativePixelsProduceDownwardRowDelta() {
    let d = TerminalScrollInput.decide(
      event: .init(deltaY: 0, scrollingDeltaY: -24, hasPreciseScrollingDeltas: true),
      residualPx: 0,
      cellHeightPx: 24
    )
    XCTAssertEqual(d.rowsDelta, 1)
    XCTAssertEqual(d.newResidualPx, 0)
  }

  func testMouseTrackingWheelDirectionUsesPreciseScrollingDeltaWhenLegacyDeltaIsZero() {
    let up = TerminalScrollInput.mouseTrackingWheelDirection(
      event: .init(deltaY: 0, scrollingDeltaY: 3.5, hasPreciseScrollingDeltas: true)
    )
    let down = TerminalScrollInput.mouseTrackingWheelDirection(
      event: .init(deltaY: 0, scrollingDeltaY: -2.0, hasPreciseScrollingDeltas: true)
    )

    XCTAssertEqual(up, .up)
    XCTAssertEqual(down, .down)
  }

  func testMouseTrackingWheelDirectionUsesLegacyDeltaForNotchedWheel() {
    let direction = TerminalScrollInput.mouseTrackingWheelDirection(
      event: .init(deltaY: -1, scrollingDeltaY: 0, hasPreciseScrollingDeltas: false)
    )

    XCTAssertEqual(direction, .down)
  }

  // MARK: - Alternate scroll mode (DEC private 1007)

  func testAltScrollKeysNoMotionProducesNoKeys() {
    XCTAssertNil(TerminalScrollInput.altScrollKeys(rowsDelta: 0))
  }

  func testAltScrollKeysScrollingTowardHistoryEmitsUpArrows() {
    // `decide` yields negative rows for visually-up scrolling toward older
    // content; in less/vim Up is "scroll back".
    let keys = TerminalScrollInput.altScrollKeys(rowsDelta: -3)
    XCTAssertEqual(keys?.key, .up)
    XCTAssertEqual(keys?.count, 3)
  }

  func testAltScrollKeysScrollingTowardBottomEmitsDownArrows() {
    let keys = TerminalScrollInput.altScrollKeys(rowsDelta: 2)
    XCTAssertEqual(keys?.key, .down)
    XCTAssertEqual(keys?.count, 2)
  }

  func testAltScrollKeysCountIsBoundedByMaxKeys() {
    let keys = TerminalScrollInput.altScrollKeys(rowsDelta: -500, maxKeys: 64)
    XCTAssertEqual(keys?.key, .up)
    XCTAssertEqual(keys?.count, 64)
  }

  func testAltScrollKeysNonPositiveMaxProducesNoKeys() {
    XCTAssertNil(TerminalScrollInput.altScrollKeys(rowsDelta: -3, maxKeys: 0))
  }

  func testAppliedRowsFromViewportUsesBottomAsZeroAndOlderHistoryAsNegative() {
    XCTAssertEqual(
      TerminalScrollInput.appliedRowsFromViewport(
        viewportOffset: 100,
        totalRows: 105,
        viewportRows: 5
      ),
      0
    )
    XCTAssertEqual(
      TerminalScrollInput.appliedRowsFromViewport(
        viewportOffset: 0,
        totalRows: 105,
        viewportRows: 5
      ),
      -100
    )
  }

  func testReconcileAppliedRowsReportsClampedOverscroll() {
    let reconciled = TerminalScrollInput.reconcileAppliedRows(
      desiredAppliedRows: -140,
      viewportOffset: 0,
      totalRows: 105,
      viewportRows: 5
    )

    XCTAssertEqual(reconciled.actualAppliedRows, -100)
    XCTAssertTrue(reconciled.clamped)
  }

  func testDragAutoscrollAboveTopMovesTowardOlderHistory() {
    XCTAssertEqual(
      TerminalScrollInput.dragAutoscrollDeltaRows(
        pointerY: 472,
        contentBottom: 8,
        contentTop: 440
      ),
      -1
    )
  }

  func testDragAutoscrollBelowBottomMovesTowardActiveBottom() {
    XCTAssertEqual(
      TerminalScrollInput.dragAutoscrollDeltaRows(
        pointerY: 2,
        contentBottom: 8,
        contentTop: 440
      ),
      1
    )
  }

  func testDragAutoscrollInsideViewportDoesNotScroll() {
    XCTAssertEqual(
      TerminalScrollInput.dragAutoscrollDeltaRows(
        pointerY: 120,
        contentBottom: 8,
        contentTop: 440
      ),
      0
    )
  }

  func testDragAutoscrollDoesNotScrollForwardPastActiveBottom() {
    XCTAssertFalse(
      TerminalScrollInput.canApplyDragAutoscroll(deltaRows: 1, appliedRows: 0))
    XCTAssertTrue(
      TerminalScrollInput.canApplyDragAutoscroll(deltaRows: -1, appliedRows: 0))
    XCTAssertTrue(
      TerminalScrollInput.canApplyDragAutoscroll(deltaRows: 1, appliedRows: -12))
  }

  // MARK: - Captured-gesture replay

  /// Replays a real two-gesture trackpad capture (saved as JSONL alongside this
  /// test) through the decision function. The captured stream is monotonically
  /// upward: every event has `scrollingDeltaY >= 0`. The bug we are guarding
  /// against turned `scrollingDeltaY > 0` events with `deltaY == 0` into
  /// downward row deltas, walking the viewport offset back up — the visible
  /// "bounce." The invariants below would have failed against the buggy code.
  func testCapturedUpwardGestureNeverProducesDownwardRowDelta() throws {
    let events = try loadCapturedStream("scrollwheel-bounce-2026-05-04")
    let cellHeight: CGFloat = 24
    var residual: CGFloat = 0
    var simulatedOffset = 1000  // arbitrary upper bound; clamp at 0 = top of scrollback
    let startingOffset = simulatedOffset

    for (i, e) in events.enumerated() {
      let d = TerminalScrollInput.decide(
        event: .init(
          deltaY: CGFloat(e.deltaY),
          scrollingDeltaY: CGFloat(e.scrollingDeltaY),
          hasPreciseScrollingDeltas: e.hasPrecise
        ),
        residualPx: residual,
        cellHeightPx: cellHeight
      )
      residual = d.newResidualPx

      let pixelsUp =
        e.hasPrecise
        ? CGFloat(e.scrollingDeltaY)
        : CGFloat(e.deltaY) * cellHeight

      if pixelsUp >= 0 {
        XCTAssertLessThanOrEqual(
          d.rowsDelta, 0,
          "event \(i): pixelsUp=\(pixelsUp) but rowsDelta=\(d.rowsDelta) (would cause bounce-back)"
        )
      } else {
        XCTAssertGreaterThanOrEqual(d.rowsDelta, 0, "event \(i)")
      }

      simulatedOffset = max(0, simulatedOffset + d.rowsDelta)
    }

    XCTAssertLessThan(
      simulatedOffset, startingOffset,
      "two upward gestures should leave the viewport closer to the top of scrollback"
    )
  }

  // MARK: - Precise fractional scrolling

  func testPreciseRowsDeltaProducesFractionalRows() {
    let delta = TerminalScrollInput.preciseRowsDelta(scrollingDeltaY: 8, cellHeightPx: 24)
    XCTAssertEqual(delta, -1.0 / 3.0, accuracy: 1e-9, "8px up over 24px cells is a third of a row toward history")
  }

  func testPreciseRowsDeltaZeroCellHeightIsInert() {
    XCTAssertEqual(TerminalScrollInput.preciseRowsDelta(scrollingDeltaY: 10, cellHeightPx: 0), 0)
    XCTAssertEqual(TerminalScrollInput.preciseRowsDelta(scrollingDeltaY: 10, cellHeightPx: -3), 0)
  }

  func testClampedFractionalTargetBoundsBottomAndTop() {
    XCTAssertEqual(TerminalScrollInput.clampedFractionalTarget(0.7, maxScrollbackRows: 100), 0, "cannot scroll below the live bottom")
    XCTAssertEqual(TerminalScrollInput.clampedFractionalTarget(-42.25, maxScrollbackRows: 100), -42.25)
    XCTAssertEqual(
      TerminalScrollInput.clampedFractionalTarget(-150.5, maxScrollbackRows: 100), -100,
      "phantom distance past the top of history must not accumulate")
    XCTAssertEqual(TerminalScrollInput.clampedFractionalTarget(-3, maxScrollbackRows: 0), 0)
  }

  func testGestureDesiredAppliedRowsHoldsBelowBottomWhileTargetInHistory() {
    // The sticky-bottom regression at the pure level: a small fraction must
    // not round to 0 (the active-bottom snap resets gesture accumulation).
    XCTAssertEqual(
      TerminalScrollInput.gestureDesiredAppliedRows(displayedRows: -0.2, targetRows: -0.2), -1)
    XCTAssertEqual(
      TerminalScrollInput.gestureDesiredAppliedRows(displayedRows: -0.5, targetRows: -0.5), -1)
  }

  func testGestureDesiredAppliedRowsRoundsToNearestInHistory() {
    XCTAssertEqual(
      TerminalScrollInput.gestureDesiredAppliedRows(displayedRows: -10.4, targetRows: -10.4), -10)
    XCTAssertEqual(
      TerminalScrollInput.gestureDesiredAppliedRows(displayedRows: -10.6, targetRows: -10.6), -11)
  }

  func testGestureDesiredAppliedRowsAtBottomTargetSnapsToZero() {
    XCTAssertEqual(
      TerminalScrollInput.gestureDesiredAppliedRows(displayedRows: 0, targetRows: 0), 0,
      "a true return to 0 routes through the active-bottom snap")
  }

  func testSettledTargetRowsRoundsToWholeRowAndNeverPositive() {
    XCTAssertEqual(TerminalScrollInput.settledTargetRows(displayedRows: -0.3), 0)
    XCTAssertEqual(TerminalScrollInput.settledTargetRows(displayedRows: -10.5), -11)
    XCTAssertEqual(TerminalScrollInput.settledTargetRows(displayedRows: -10.4), -10)
    XCTAssertEqual(TerminalScrollInput.settledTargetRows(displayedRows: 0.4), 0)
  }

  func testPreciseSettleActionMomentumEndSettlesNow() {
    XCTAssertEqual(
      TerminalScrollInput.preciseSettleAction(momentumEnded: true, hasFraction: true),
      .settleNow)
    XCTAssertEqual(
      TerminalScrollInput.preciseSettleAction(momentumEnded: true, hasFraction: false),
      .settleNow)
  }

  func testPreciseSettleActionFractionArmsQuiescence() {
    XCTAssertEqual(
      TerminalScrollInput.preciseSettleAction(momentumEnded: false, hasFraction: true),
      .armQuiescence)
  }

  func testPreciseSettleActionWholeRowMotionStaysTimerFree() {
    XCTAssertEqual(
      TerminalScrollInput.preciseSettleAction(momentumEnded: false, hasFraction: false),
      .none)
  }

  // MARK: - Fixture loader

  private struct CapturedEvent: Decodable {
    let deltaY: Double
    let scrollingDeltaY: Double
    let hasPrecise: Bool
    let phase: Int
    let momentumPhase: Int
    let observedOffset: Int
  }

  private func loadCapturedStream(_ name: String) throws -> [CapturedEvent] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name).jsonl")
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    let text = String(decoding: data, as: UTF8.self)
    return try text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
      .filter { !$0.isEmpty }
      .map { line in
        try decoder.decode(CapturedEvent.self, from: Data(line.utf8))
      }
  }
}
