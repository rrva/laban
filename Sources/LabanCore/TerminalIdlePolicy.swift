/// Idle policy for the terminal's per-frame display link.
///
/// The display link only needs to tick to drive *on-screen animation* — cursor
/// blink, smooth scroll, and the attention pulse — all of which run only while
/// the window is visible to the user (key window, not occluded). Terminal
/// *output* does not need the link: it is pushed straight to a frame via the
/// reader-thread `onSessionDirty` callback. So a backgrounded or fully occluded
/// window can park the link entirely and the push path still paints any
/// background output, taking idle CPU/refresh wake-ups toward zero.
///
/// Pure and AppKit-free so the "should the link be running?" decision is
/// unit-tested without a window or display.
public enum TerminalIdlePolicy {
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
}
