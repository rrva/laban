import CoreGraphics

enum TerminalScrollInput {
  enum WheelDirection {
    case up
    case down
  }

  struct Event {
    let deltaY: CGFloat
    let scrollingDeltaY: CGFloat
    let hasPreciseScrollingDeltas: Bool
  }

  struct Decision {
    let rowsDelta: Int
    let newResidualPx: CGFloat
  }

  /// Resolve a scroll-wheel event into a row delta plus carried sub-cell residual.
  ///
  /// Sign convention matches `Session.scrollViewport(deltaRows:)`: negative rows
  /// move toward older history (visually up), positive rows toward the active
  /// bottom. AppKit's `scrollingDeltaY` and `deltaY` are positive when the user
  /// scrolls upward, so positive resolved pixels produce negative `rowsDelta`.
  ///
  /// On precise devices the legacy `deltaY` rounds to zero for sub-line motion
  /// even while `scrollingDeltaY` carries real signed pixels; treating that as a
  /// reversed direction is the bounce-back that `decide` exists to prevent.
  static func decide(
    event: Event,
    residualPx: CGFloat,
    cellHeightPx: CGFloat
  ) -> Decision {
    guard cellHeightPx > 0 else {
      return Decision(rowsDelta: 0, newResidualPx: residualPx)
    }

    let pixelsUp: CGFloat =
      event.hasPreciseScrollingDeltas
      ? event.scrollingDeltaY
      : event.deltaY * cellHeightPx

    let totalPx = residualPx + pixelsUp
    let rows = (totalPx / cellHeightPx).rounded(.towardZero)
    let consumedPx = rows * cellHeightPx
    return Decision(
      rowsDelta: -Int(rows),
      newResidualPx: totalPx - consumedPx
    )
  }

  // MARK: - Precise fractional scrolling

  /// Fractional rows for precise (pixel) input: 1:1 finger tracking with no
  /// residual and no truncation. Sign convention matches `decide`.
  static func preciseRowsDelta(
    scrollingDeltaY: CGFloat,
    cellHeightPx: CGFloat
  ) -> Double {
    guard cellHeightPx > 0 else { return 0 }
    return -Double(scrollingDeltaY / cellHeightPx)
  }

  /// Clamp a fractional scroll target into the scrollable range
  /// `[-maxScrollbackRows, 0]` so a gesture can neither overshoot the live
  /// bottom nor build phantom distance past the top of history (where no
  /// `scrollViewport` delta would ever fire the clamp-reconcile).
  static func clampedFractionalTarget(
    _ rows: Double,
    maxScrollbackRows: Int
  ) -> Double {
    min(0, max(-Double(max(0, maxScrollbackRows)), rows))
  }

  /// Integer viewport rows to apply mid-gesture. Round-to-nearest, but held
  /// at ≤ -1 while the target is above the bottom: rounding a small fraction
  /// to 0 would route through the active-bottom snap, whose state reset
  /// destroys the gesture's accumulation on every event — a slow scroll up
  /// from the bottom could then never leave it. The snap (and its
  /// follow-output re-engage semantics) fires only when the user actually
  /// returns to 0.
  static func gestureDesiredAppliedRows(
    displayedRows: Double,
    targetRows: Double
  ) -> Int {
    var desired = Int(displayedRows.rounded(.toNearestOrAwayFromZero))
    if targetRows < 0 { desired = min(desired, -1) }
    return desired
  }

  /// Whole-row resting position for a settle once precise input goes quiet.
  static func settledTargetRows(displayedRows: Double) -> Double {
    min(0, displayedRows.rounded(.toNearestOrAwayFromZero))
  }

  enum SettleAction: Equatable {
    case none
    case settleNow
    case armQuiescence
  }

  /// Decide how a precise event affects the settle-to-whole-row machinery.
  /// Momentum end/cancel is an authoritative "input is over" signal. Any
  /// other event with a pending fraction re-arms the quiescence timer: while
  /// a stream is active the next event (~8 ms away) re-arms long before the
  /// timer fires, so it only ever fires after real quiet — gesture over,
  /// momentum died without an end marker, phaseless devices, synthetic
  /// events, or a finger resting mid-gesture (which should sit on a whole
  /// row too).
  static func preciseSettleAction(
    momentumEnded: Bool,
    hasFraction: Bool
  ) -> SettleAction {
    if momentumEnded { return .settleNow }
    return hasFraction ? .armQuiescence : .none
  }

  static func mouseTrackingWheelDirection(event: Event) -> WheelDirection? {
    let signedDelta =
      event.hasPreciseScrollingDeltas
      ? event.scrollingDeltaY
      : event.deltaY
    if signedDelta > 0 { return .up }
    if signedDelta < 0 { return .down }
    return nil
  }

  enum AltScrollKey {
    case up
    case down
  }

  /// Translate a resolved row delta into alternate-scroll-mode (DEC private
  /// 1007) cursor-key presses. `decide` yields negative rows for visually-up
  /// scrolling toward older content, which maps to Up-arrow presses — the key
  /// `less`, `man`, and `vim` read as "scroll back" on the alternate screen.
  /// `maxKeys` bounds a fast trackpad fling so it cannot flood the PTY with
  /// hundreds of synthesized keystrokes in a single event.
  static func altScrollKeys(
    rowsDelta: Int,
    maxKeys: Int = 64
  ) -> (key: AltScrollKey, count: Int)? {
    guard rowsDelta != 0, maxKeys > 0 else { return nil }
    let count = min(abs(rowsDelta), maxKeys)
    return rowsDelta < 0 ? (.up, count) : (.down, count)
  }

  static func appliedRowsFromViewport(
    viewportOffset: Int,
    totalRows: Int,
    viewportRows: Int
  ) -> Int {
    let bottomOffset = max(0, totalRows - viewportRows)
    return viewportOffset - bottomOffset
  }

  static func reconcileAppliedRows(
    desiredAppliedRows: Int,
    viewportOffset: Int,
    totalRows: Int,
    viewportRows: Int
  ) -> (actualAppliedRows: Int, clamped: Bool) {
    let actual = appliedRowsFromViewport(
      viewportOffset: viewportOffset,
      totalRows: totalRows,
      viewportRows: viewportRows
    )
    return (actual, actual != desiredAppliedRows)
  }

  static func dragAutoscrollDeltaRows(
    pointerY: CGFloat,
    contentBottom: CGFloat,
    contentTop: CGFloat
  ) -> Int {
    if pointerY >= contentTop {
      return -1
    }
    if pointerY < contentBottom {
      return 1
    }
    return 0
  }

  static func canApplyDragAutoscroll(
    deltaRows: Int,
    appliedRows: Int
  ) -> Bool {
    guard deltaRows != 0 else { return false }
    if deltaRows > 0, appliedRows >= 0 {
      return false
    }
    return true
  }
}
