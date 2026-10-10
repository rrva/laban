import AppKit
import LabanCore

/// What identifies a splitter element: the divider's place in its tab plus the split it
/// belongs to (its axis and the panes on either side). Moving the divider or the window
/// keeps the key, so the element is updated in place and VoiceOver keeps its focus. A
/// structural change that hands the path to another split (closing a pane shifts paths)
/// changes the key, so that divider gets a fresh element instead of the old one.
struct PaneSplitterKey: Hashable {
  let tabId: Tab.ID
  let path: PanePath
  let axis: PaneAxis
  let leaves: [Session.ID]

  init(tab: Tab, divider: PaneDivider) {
    tabId = tab.id
    path = divider.path
    axis = divider.axis
    leaves = tab.panes.subtree(at: divider.path)?.leafSessionIds() ?? []
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
