/// Idle policy for the terminal's per-frame display link.
///
/// The display link is a transient animation timer, not a guaranteed periodic
/// repaint (ADR 0018). Frame production is event-driven: every state change
/// that can alter pixels wakes the frame loop explicitly (PTY output push,
/// input handlers, model-mutation hooks, the owned cursor-blink timer). The
/// link runs only while something is actually animating — smooth scroll, the
/// attention pulse, the post-output hold — or while the user has opted back
/// into the legacy 8 Hz visible-idle floor via the `LabanDisplayLinkIdleFloor`
/// parachute default. A focused, quiescent terminal parks the link completely,
/// taking idle CPU and refresh wake-ups toward zero.
///
/// Pure and AppKit-free so the "should the link be running?" decision is
/// unit-tested without a window or display. All window/UserDefaults reads
/// happen in `TerminalBitmapView` and are passed in as plain values.
public enum TerminalIdlePolicy {
  public static let idleDisplayLinkFramesPerSecond = 8
  public static let activeDisplayLinkFramesPerSecond = 120
  /// Budget rate for decorative animation (the breathing sidebar attention
  /// marker). `AttentionPulse.period` is a 1.5 s raised-cosine breath and
  /// `alpha(at:)` is a continuous function of wall-clock time, so 30 fps gives
  /// 45 phase-correct samples per breath — visually smooth at a quarter of the
  /// 120 fps energy. Smooth scroll keeps the active rate because
  /// finger-tracking latency is user-perceivable.
  public static let animationDisplayLinkFramesPerSecond = 30

  /// Whether the per-frame display link should keep ticking (full-park
  /// policy).
  ///
  /// - Parameters:
  ///   - windowVisibleToUser: the window is the key window *and* not occluded.
  ///   - scrollAnimating: a smooth-scroll animation is in flight. Overrides
  ///     everything else so a scroll that is still settling never freezes
  ///     mid-animation, even if visibility flips during it (matches the
  ///     pre-park gate).
  ///   - attentionAnimating: a background tab's sidebar marker is breathing.
  ///   - terminalOutputActive: terminal output landed within the output-hold
  ///     window, so the link is carrying the paint cadence for a stream.
  ///   - cursorBlinkActive: the owned cursor-blink timer is running (blink
  ///     enabled in Settings + window visible + cursor visible). Off by
  ///     default; the blink driver also wakes flips itself, this input just
  ///     keeps the legacy blink floor while the feature is on.
  ///   - idleFloorEnabled: the `LabanDisplayLinkIdleFloor` parachute — restores
  ///     the pre-park 8 Hz visible-idle floor with no rebuild.
  ///   - glyphEffectAnimating: a per-glyph effect (keystroke-impulse type-in,
  ///     bell shake) is live. Rides the active (panel) rate while live —
  ///   a ~130 ms spring needs the samples — and parks the moment the last
  ///   effect decays (ADR 0018: the link is a transient animation timer).
  public static func displayLinkShouldRun(
    windowVisibleToUser: Bool,
    scrollAnimating: Bool,
    attentionAnimating: Bool,
    terminalOutputActive: Bool,
    cursorBlinkActive: Bool,
    idleFloorEnabled: Bool,
    glyphEffectAnimating: Bool = false
  ) -> Bool {
    if scrollAnimating { return true }
    return windowVisibleToUser
      && (terminalOutputActive || attentionAnimating || cursorBlinkActive || idleFloorEnabled
        || glyphEffectAnimating)
  }

  /// Compatibility shim with the pre-park two-argument semantics
  /// (`visible || scrolling`), which are exactly the full-park policy with the
  /// idle floor forced on. Kept so M1-era callers and tests remain valid;
  /// production plumbing passes the full input set.
  public static func displayLinkShouldRun(
    windowVisibleToUser: Bool,
    scrollAnimating: Bool
  ) -> Bool {
    displayLinkShouldRun(
      windowVisibleToUser: windowVisibleToUser,
      scrollAnimating: scrollAnimating,
      attentionAnimating: false,
      terminalOutputActive: false,
      cursorBlinkActive: false,
      idleFloorEnabled: true,
      glyphEffectAnimating: false)
  }

  /// Preferred frame rate while the link runs: the active rate for scroll and
  /// live output, the animation budget rate for attention-only frames, the
  /// idle rate for blink-only or floor-only operation (and as the don't-care
  /// value while parked). Glyph effects ride the active rate too: the
  /// keystroke impulse settles in ~130 ms, so the 30 fps decorative budget
  /// would give it ~4 frames — the frame starvation that made the old
  /// ink-bloom read as flicker. Effects park the moment they decay, so the
  /// energy cost stays bounded.
  public static func preferredDisplayLinkFramesPerSecond(
    windowVisibleToUser: Bool,
    scrollAnimating: Bool,
    attentionAnimating: Bool,
    terminalOutputActive: Bool,
    cursorBlinkActive: Bool,
    idleFloorEnabled: Bool,
    glyphEffectAnimating: Bool = false
  ) -> Int {
    guard
      displayLinkShouldRun(
        windowVisibleToUser: windowVisibleToUser,
        scrollAnimating: scrollAnimating,
        attentionAnimating: attentionAnimating,
        terminalOutputActive: terminalOutputActive,
        cursorBlinkActive: cursorBlinkActive,
        idleFloorEnabled: idleFloorEnabled,
        glyphEffectAnimating: glyphEffectAnimating)
    else {
      return idleDisplayLinkFramesPerSecond
    }
    if scrollAnimating || terminalOutputActive {
      return activeDisplayLinkFramesPerSecond
    }
    if glyphEffectAnimating {
      return activeDisplayLinkFramesPerSecond
    }
    if attentionAnimating {
      return animationDisplayLinkFramesPerSecond
    }
    return idleDisplayLinkFramesPerSecond
  }

  /// Compatibility shim with the pre-park four-argument semantics (idle floor
  /// forced on, no blink input). Kept for M1-era tests; production plumbing
  /// passes the full input set.
  public static func preferredDisplayLinkFramesPerSecond(
    windowVisibleToUser: Bool,
    scrollAnimating: Bool,
    attentionAnimating: Bool,
    terminalOutputActive: Bool
  ) -> Int {
    preferredDisplayLinkFramesPerSecond(
      windowVisibleToUser: windowVisibleToUser,
      scrollAnimating: scrollAnimating,
      attentionAnimating: attentionAnimating,
      terminalOutputActive: terminalOutputActive,
      cursorBlinkActive: false,
      idleFloorEnabled: true,
      glyphEffectAnimating: false)
  }
}
