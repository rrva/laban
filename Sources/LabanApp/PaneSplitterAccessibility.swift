import AppKit
import LabanCore

/// What identifies a splitter element: when none of it changes the cached element is
/// still accurate.
struct PaneSplitterSignature: Equatable {
  let tabId: Tab.ID
  let path: PanePath
  let rect: CGRect
  let fraction: Double

  init(divider: PaneDivider, tabId: Tab.ID) {
    self.tabId = tabId
    self.path = divider.path
    self.rect = divider.rect
    self.fraction = divider.fraction
  }
}

/// A pane divider as a VoiceOver `splitter`. The terminal is one view with no per-pane
/// subviews, so each divider is an explicit accessibility child of `TerminalBitmapView`.
/// Increment and decrement run the same two-cell step as Cmd+Control+Arrow.
final class PaneSplitterAccessibilityElement: NSAccessibilityElement {
  var onIncrement: (() -> Bool)?
  var onDecrement: (() -> Bool)?

  override func accessibilityPerformIncrement() -> Bool { onIncrement?() ?? false }
  override func accessibilityPerformDecrement() -> Bool { onDecrement?() ?? false }
}
