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
