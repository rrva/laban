import LabanTerminalCore

/// Decides when a local selection has gone stale because the terminal app, not
/// Laban, replaced the content under it. Laban never reprojects a selection
/// through an app-driven repaint, so the only sane response (iTerm2's) is to
/// drop the selection. Shared by `TerminalBitmapView` and
/// `HeadlessDebugRuntime` so both clear on the same frames.
///
/// Call `shouldClear` once per rendered frame for the focused session.
public struct TerminalSelectionInvalidation {
  private struct ContentBaseline {
    var sessionId: Session.ID
    var selection: TerminalSelection
    var text: String
  }

  private var altScreenBySession: [Session.ID: Bool] = [:]
  private var contentBaseline: ContentBaseline?

  public init() {}

  /// True when `sessionId`'s selection must be cleared this frame.
  ///
  /// - A swap between the primary and alternate screen (either direction)
  ///   leaves the selection's rows pointing at the other screen's unrelated
  ///   cells. The first observation of a session only records its screen.
  /// - Under mouse tracking the app owns its screen and repaints it without
  ///   any Laban scroll (the selection is reachable there only via Shift-drag).
  ///   When the text under an unchanged selection differs from what it was
  ///   on the frame the selection last changed, the highlight now marks
  ///   different text. This compares the selected cells' text rather than
  ///   libghostty's per-row dirty bits: those mean "may have changed" and are
  ///   set wholesale by full redraws, cursor and attribute updates, so a
  ///   row-intersection test would also drop the selection on identical
  ///   repaints, which mouse-tracking TUIs emit constantly. The text is only
  ///   read while a selection exists under mouse tracking.
  ///
  /// While `gestureActive` (a local selection drag is in flight) nothing is
  /// cleared; the baseline just follows the selection.
  public mutating func shouldClear(
    sessionId: Session.ID,
    altScreen: Bool,
    mouseTracking: Bool,
    selection: TerminalSelection?,
    gestureActive: Bool = false,
    selectedText: () -> String
  ) -> Bool {
    let previousAltScreen = altScreenBySession.updateValue(altScreen, forKey: sessionId)
    guard let selection else {
      contentBaseline = nil
      return false
    }
    if !gestureActive, let previousAltScreen, previousAltScreen != altScreen {
      contentBaseline = nil
      return true
    }
    guard mouseTracking else {
      contentBaseline = nil
      return false
    }
    let text = selectedText()
    if !gestureActive, let baseline = contentBaseline, baseline.sessionId == sessionId,
      baseline.selection == selection, baseline.text != text
    {
      contentBaseline = nil
      return true
    }
    contentBaseline = ContentBaseline(sessionId: sessionId, selection: selection, text: text)
    return false
  }

  /// The selection's text as Copy reads it: scrollback-aware when the
  /// viewport state is known.
  public static func selectedText(of selection: TerminalSelection, in session: Session) -> String {
    guard let snapshot = session.snapshot() else { return "" }
    defer { laban_snapshot_destroy(snapshot) }
    guard let viewportState = session.viewportState() else {
      return selection.selectedText(from: snapshot.pointee)
    }
    return selection.selectedText(
      from: session, viewportSnapshot: snapshot.pointee, viewportState: viewportState)
  }
}
