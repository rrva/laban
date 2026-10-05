/// Decides when a local selection has gone stale because the terminal app, not
/// Laban, replaced the content under it. Laban never reprojects a selection
/// through an app-driven repaint, so the only sane response (iTerm2's) is to
/// drop the selection. Shared by `TerminalBitmapView` and
/// `HeadlessDebugRuntime` so both clear on the same frames.
///
/// Call `shouldClear` once per rendered frame for the focused session.
public struct TerminalSelectionInvalidation {
  private var altScreenBySession: [Session.ID: Bool] = [:]

  public init() {}

  /// True when `sessionId`'s selection must be cleared this frame.
  ///
  /// - A swap between the primary and alternate screen (either direction)
  ///   leaves the selection's rows pointing at the other screen's unrelated
  ///   cells. The first observation of a session only records its screen.
  public mutating func shouldClear(
    sessionId: Session.ID,
    altScreen: Bool,
    selection: TerminalSelection?
  ) -> Bool {
    let previousAltScreen = altScreenBySession.updateValue(altScreen, forKey: sessionId)
    guard selection != nil else { return false }
    return previousAltScreen.map { $0 != altScreen } ?? false
  }
}
