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

    public init(viewportOffset: Int, totalRows: Int, viewportRows: Int, isHoverEdge: Bool) {
      self.viewportOffset = viewportOffset
      self.totalRows = totalRows
      self.viewportRows = viewportRows
      self.isHoverEdge = isHoverEdge
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

  public static func decide(_ input: Input) -> Output {
    guard input.viewportRows > 0, input.totalRows > input.viewportRows else {
      return .hidden
    }

    let maxScrollback = input.totalRows - input.viewportRows
    let bottomOffset = max(0, maxScrollback)
    let appliedRows = input.viewportOffset - bottomOffset
    let linesBack = max(0, -appliedRows)

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
}
