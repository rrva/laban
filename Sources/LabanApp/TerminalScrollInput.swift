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
  /// Momentum end/cancel is an authoritative "input is over" signal. While
  /// the gesture or momentum is active (fingers down or inertia flowing)
  /// the settle must never run: a slow or resting finger produces event
  /// gaps longer than any quiescence window, and a timer firing under it
  /// creeps the content to a whole row and shifts the base the next finger
  /// movement accumulates from — mid-gesture jank. A resting finger is
  /// holding the page; whole-row alignment applies to lifted fingers only.
  /// An inactive stream with a pending fraction arms the quiescence timer:
  /// the gap between gesture end and a possible momentum start, momentum
  /// that dies without an end marker, phaseless precise devices, and
  /// synthetic event streams.
  static func preciseSettleAction(
    momentumEnded: Bool,
    gestureOrMomentumActive: Bool,
    hasFraction: Bool
  ) -> SettleAction {
    if momentumEnded { return .settleNow }
    if gestureOrMomentumActive { return .none }
    return hasFraction ? .armQuiescence : .none
  }

  /// Exponentially-smoothed input velocity estimate (rows/sec) updated from
  /// one precise event's delta and inter-event gap. Drives the resampler
  /// stiffness only — never positions — so estimate noise cannot move
  /// content.
  static func updatedInputVelocityEstimate(
    previous: Double,
    deltaRows: Double,
    dtSeconds: Double
  ) -> Double {
    guard dtSeconds > 0.0005 else { return previous }
    let instantaneous = deltaRows / dtSeconds
    return previous + 0.3 * (instantaneous - previous)
  }

  /// Speed-adaptive stiffness for the precise-input resampler. A critically
  /// damped follower trails its target by ≈ 2·v/ω, so a fixed ω is either
  /// too soft at flick speed (rubber-band lag) or too stiff at reading
  /// speed (reproduces the whole-point input pulses it exists to smooth).
  /// Scaling ω with input speed keeps lag under ~a quarter row everywhere
  /// while giving slow scrolling a ~15-20 ms smoothing window — enough to
  /// turn macOS's quantized 1-pt momentum deltas into continuous motion.
  static func adaptiveScrollOmega(
    inputRowsPerSec: Double,
    baseOmega: Double
  ) -> Double {
    min(400, baseOmega + 7.0 * abs(inputRowsPerSec))
  }

  /// Translate a resolved row delta into wheel reports for mouse-tracking
  /// mode. The caller runs the raw event through `decide` first, so a
  /// trackpad's high-frequency trickle of sub-row precise deltas accumulates
  /// in the residual and only crosses a report per terminal row of travel —
  /// one report per NSEvent would hand apps like tmux (which scrolls several
  /// lines per wheel event) a report per few pixels instead. Notched wheels
  /// are unaffected: their line-unit `deltaY` resolves to one report per
  /// notch. Sign convention matches `decide`: negative rows scroll toward
  /// older history and map to wheel-up. `maxReports` bounds a fast trackpad
  /// fling so it cannot flood the PTY in a single event.
  static func mouseTrackingWheelReports(
    rowsDelta: Int,
    maxReports: Int = 64
  ) -> (direction: WheelDirection, count: Int)? {
    guard rowsDelta != 0, maxReports > 0 else { return nil }
    let count = min(abs(rowsDelta), maxReports)
    return rowsDelta < 0 ? (.up, count) : (.down, count)
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
