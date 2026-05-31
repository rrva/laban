import Foundation

/// Pure decision layer for the overlay scroll indicator. The AppKit view in
/// `LabanApp/TerminalScrollIndicatorView.swift` is a dumb renderer of
/// `Output`; all visibility/sizing logic lives here so the behavior contract
/// (hide-at-bottom, show-on-scrollback, hover-reveal) is unit-testable
/// without AppKit *and* reachable from `LabanDebug` for capture/replay
/// assertions on indicator state.
///
/// Sign convention matches `TerminalScrollInput.appliedRowsFromViewport`:
/// `appliedRows = viewportOffset - max(0, totalRows - viewportRows)` is ≤ 0,
/// where 0 means the viewport is pinned to the live bottom and -N means the
/// user has scrolled N rows back into history.
public enum TerminalScrollIndicator {

  public struct Input: Equatable, Codable {
    public var viewportOffset: Int
    public var totalRows: Int
    public var viewportRows: Int
    public var isHoverEdge: Bool
    /// The terminal is on the alternate screen (a full-screen TUI such as
    /// `less` or `vim`). Those apps own the screen and manage their own
    /// scrollback, so Laban has no history of its own for the overlay to point
    /// at — the indicator must stay hidden.
    public var isAltScreen: Bool
    /// The focused app has mouse tracking on (Claude Code's fullscreen renderer
    /// takes over the screen this way, often on the *primary* screen). Laban
    /// then routes the wheel to the app as mouse events instead of moving its
    /// own viewport, so the scrollback position the overlay would show is not
    /// something the user can drive — stay hidden.
    public var isMouseTracking: Bool

    public init(
      viewportOffset: Int,
      totalRows: Int,
      viewportRows: Int,
      isHoverEdge: Bool,
      isAltScreen: Bool = false,
      isMouseTracking: Bool = false
    ) {
      self.viewportOffset = viewportOffset
      self.totalRows = totalRows
      self.viewportRows = viewportRows
      self.isHoverEdge = isHoverEdge
      self.isAltScreen = isAltScreen
      self.isMouseTracking = isMouseTracking
    }
  }

  public struct Output: Equatable, Codable {
    /// True while the indicator should hold full opacity. False means the
    /// view should kick its idle-fade timer; it does not mean "hide now."
    public var shouldHold: Bool
    /// Thumb height as a fraction of the available track (0…1).
    public var thumbFraction: Double
    /// Thumb top edge as a fraction of the track, measured from the top
    /// (0…1).
    public var thumbOffsetFraction: Double
    /// Pill chip visible — only while scrolled away from the live bottom.
    /// Format is `linesBack / maxScrollback`. Age (`· 2m ago`) deferred:
    /// requires per-row timestamps that aren't plumbed through the snapshot
    /// path yet.
    public var pillVisible: Bool
    public var pillText: String

    public init(
      shouldHold: Bool,
      thumbFraction: Double,
      thumbOffsetFraction: Double,
      pillVisible: Bool,
      pillText: String
    ) {
      self.shouldHold = shouldHold
      self.thumbFraction = thumbFraction
      self.thumbOffsetFraction = thumbOffsetFraction
      self.pillVisible = pillVisible
      self.pillText = pillText
    }

    public static let hidden = Output(
      shouldHold: false,
      thumbFraction: 0,
      thumbOffsetFraction: 0,
      pillVisible: false,
      pillText: ""
    )
  }

  /// Minimum visual thumb fraction. Without a floor, a 5 000-row scrollback
  /// with a 40-row viewport produces a 3-px thumb that's harder to read than
  /// the "no scrollbar" baseline this indicator replaces.
  public static let minThumbFraction: Double = 0.06

  /// How many rows the viewport is scrolled back from the live bottom. 0 means
  /// pinned to the bottom; N means N rows into history. This is the only signal
  /// the idle-hide timer treats as *scroll activity*: streaming output grows
  /// `totalRows` while the viewport follows the tail, leaving this at 0, so it
  /// must not be mistaken for the user moving the viewport.
  public static func linesBack(_ input: Input) -> Int {
    let bottomOffset = max(0, input.totalRows - input.viewportRows)
    return max(0, bottomOffset - input.viewportOffset)
  }

  /// Drag-to-scrub inverse: map a desired thumb *top-edge* Y (view coordinates,
  /// non-flipped, y up) to a history fraction in [0, 1] where 0 is the oldest
  /// scrollback (thumb pinned to the track top) and 1 is the live bottom (thumb
  /// at the track bottom). This is the exact inverse of the thumb placement the
  /// AppKit view computes in `layoutFromOutput`, factored out so the scrub
  /// mapping is unit-testable without AppKit. The terminal multiplies the result
  /// by its authoritative `maxScrollback` to get an absolute viewport offset.
  public static func historyFraction(
    thumbTopY: Double, trackTop: Double, trackBottom: Double, thumbHeight: Double
  ) -> Double {
    let trackHeight = max(0, trackTop - trackBottom)
    let availableTravel = trackHeight - thumbHeight
    guard availableTravel > 0 else { return 1 }
    let offsetFromTop = min(max(0, trackTop - thumbTopY), availableTravel)
    return offsetFromTop / availableTravel
  }

  public static func decide(_ input: Input) -> Output {
    // When the focused app owns the wheel, there is no user-navigable Laban
    // scrollback for the overlay to point at, so stay hidden even when hovering
    // the edge. Two cases: the alternate screen (the app manages its own
    // history) and mouse tracking (Laban forwards the wheel as mouse events
    // rather than scrolling its viewport — Claude Code's fullscreen renderer
    // does this on the primary screen, where a stuck offset would otherwise pin
    // the indicator on permanently).
    guard !input.isAltScreen, !input.isMouseTracking else { return .hidden }
    guard input.viewportRows > 0, input.totalRows > input.viewportRows else {
      return .hidden
    }

    let maxScrollback = input.totalRows - input.viewportRows
    let linesBack = linesBack(input)

    let rawFraction = Double(input.viewportRows) / Double(input.totalRows)
    let thumbFraction = max(Self.minThumbFraction, min(0.95, rawFraction))
    let rawOffset = Double(input.viewportOffset) / Double(input.totalRows)
    let thumbOffset = max(0, min(1 - thumbFraction, rawOffset))

    let scrolledBack = linesBack > 0
    let shouldHold = scrolledBack || input.isHoverEdge

    return Output(
      shouldHold: shouldHold,
      thumbFraction: thumbFraction,
      thumbOffsetFraction: thumbOffset,
      pillVisible: scrolledBack,
      pillText: scrolledBack ? "\(linesBack) / \(maxScrollback)" : ""
    )
  }

  /// What the overlay view should do with its idle-hide timer for the latest
  /// viewport sample. The indicator holds while scrolled back or hovered, and
  /// otherwise fades after a short quiet delay — but the countdown is (re)armed
  /// only by genuine scroll movement (`linesBack` changing). A terminal
  /// streaming output at the live bottom therefore cannot keep re-arming the
  /// timer and pinning the indicator on screen: the fade lands a short delay
  /// after scrolling *stops*, not a short delay after the last byte of output.
  public enum IdleHideAction: Equatable {
    /// Cancel any pending hide and show at full opacity.
    case hold
    /// Start (or restart) the idle-hide countdown.
    case armHide
    /// Leave the pending timer and current opacity untouched.
    case keep
  }

  public static func idleHideAction(
    shouldHold: Bool,
    linesBack: Int,
    previousLinesBack: Int,
    isVisible: Bool,
    hidePending: Bool
  ) -> IdleHideAction {
    if shouldHold { return .hold }
    guard isVisible else { return .keep }
    let scrollMoved = linesBack != previousLinesBack
    return scrollMoved || !hidePending ? .armHide : .keep
  }
}
