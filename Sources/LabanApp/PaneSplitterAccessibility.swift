import AppKit
import LabanCore

/// What identifies a splitter element across layout changes: the divider's place in its
/// tab. Moving the divider or the window updates the element in place, so VoiceOver keeps
/// its focus through every increment.
struct PaneSplitterKey: Hashable {
  let tabId: Tab.ID
  let path: PanePath
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
