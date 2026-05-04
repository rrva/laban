import CoreGraphics

enum TerminalScrollInput {
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
}
