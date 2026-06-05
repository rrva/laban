/// Idle policy for the terminal's per-frame display link.
///
/// The display link needs to tick to drive on-screen animation — cursor blink,
/// smooth scroll, attention pulse, and recently-dirty visible terminal output.
/// Output is still pushed straight to a frame via the reader-thread
/// `onSessionDirty` callback, but keeping the visible link at the active rate
/// prevents continuous terminal output from falling back to the idle cadence.
/// A backgrounded or fully occluded window can park the link entirely and the
/// push path still paints any background output, taking idle CPU/refresh wake-ups
/// toward zero.
///
/// Pure and AppKit-free so the "should the link be running?" decision is
/// unit-tested without a window or display.
public enum TerminalIdlePolicy {
  public static let idleDisplayLinkFramesPerSecond = 8
  public static let activeDisplayLinkFramesPerSecond = 120

  /// Whether the per-frame display link should keep ticking.
  ///
  /// - Parameters:
  ///   - windowVisibleToUser: the window is the key window *and* not occluded.
  ///   - scrollAnimating: a smooth-scroll animation is in flight. Kept as a
  ///     gate so a scroll that is still settling never freezes mid-animation
  ///     even if visibility flips during it.
  public static func displayLinkShouldRun(
    windowVisibleToUser: Bool,
    scrollAnimating: Bool
  ) -> Bool {
    windowVisibleToUser || scrollAnimating
  }

  public static func preferredDisplayLinkFramesPerSecond(
    windowVisibleToUser: Bool,
    scrollAnimating: Bool,
    attentionAnimating: Bool,
    terminalOutputActive: Bool
  ) -> Int {
    guard
      displayLinkShouldRun(
        windowVisibleToUser: windowVisibleToUser,
        scrollAnimating: scrollAnimating)
    else {
      return idleDisplayLinkFramesPerSecond
    }
    return (scrollAnimating || attentionAnimating || terminalOutputActive)
      ? activeDisplayLinkFramesPerSecond
      : idleDisplayLinkFramesPerSecond
  }
}
