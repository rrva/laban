import Foundation

/// How urgently a tab wants the user's attention, derived purely from its
/// metadata. Drives the sidebar's right-edge marker and row tint, and is
/// surfaced in the debug state (`TabResponse.attention`) for autonomous
/// verification.
///
/// The vocabulary is deliberately small so each level carries one meaning: an
/// idle tab is silent, passive activity is low-salience, and `needsAction` is
/// the only level that earns a distinct colour + shape + (in the app) a gentle
/// pulse. Every level clears when the user focuses the tab — a focused tab is
/// always `.none`.
///
/// Failure indicators (a non-zero last-command exit, an exited process) are
/// deliberately *not* an attention level here: a finished-with-error command
/// isn't blocked on the user, so it stays a steady error marker rendered by the
/// existing `SidebarProducer.shellPhaseIndicatorColor` / status-badge path
/// rather than a pulsing `needsAction`.
public enum TabAttention: String, Equatable, Codable, Sendable {
  /// Nothing to surface: the focused tab, or a background tab sitting idle, at
  /// a prompt, or merely running with nothing unseen.
  case none
  /// Unseen output or a bell rang on a background tab — worth a quiet marker,
  /// not an alarm.
  case passive
  /// A background task reported completion (an informational notification) —
  /// done, but no action required.
  case done
  /// The user is blocked: an agent asked for permission/input, or the shell is
  /// waiting on input.
  case needsAction
}

public enum TabAttentionClassifier {
  /// Classify a tab purely from its metadata. `isActive` is whether this tab is
  /// the focused/selected tab; a focused tab is always `.none` because the user
  /// is already looking at it (so opening a tab clears its attention).
  ///
  /// Priority, highest first: a blocking request (`needsAction`) beats an
  /// informational completion (`done`), which beats low-salience activity
  /// (`passive`).
  public static func classify(_ m: TabTitleMetadata, isActive: Bool) -> TabAttention {
    if isActive { return .none }
    if (m.notification?.urgent ?? false)
      || m.activityState == .waiting
      || m.agent.awaitingInput
      || hasActionRequiredTitle(m)
    {
      return .needsAction
    }
    if m.notification != nil { return .done }
    if m.unseenOutput || m.bellAttention { return .passive }
    return .none
  }

  /// Leading terminal-title scalars that mark an agent awaiting user input.
  /// Claude Code flips its OSC 0 title from a braille spinner ("⠂ Claude
  /// Code") to "✳ <task label>" the instant it starts waiting — ~6 seconds
  /// before it emits its own debounced OSC 9/777 notification (verified
  /// against capture appkit-2026-06-12T06-21-05Z), so the title flip is the
  /// earliest blocked-on-the-user signal available.
  ///
  /// Deliberately NOT part of `classify`: unlike Codex's transient "[ ! ]",
  /// "✳" is the *resting* state of every idle Claude Code tab (it persists
  /// until the user answers), so deriving `needsAction` from it statelessly
  /// turned every restored or long-idle agent tab permanently yellow. The
  /// marker matters as an *edge*: `AppModel.detectAwaitMarkerTransitions`
  /// reacts to the flip by raising the urgent notification badge (which this
  /// classifier already maps to `needsAction`) and posting the banner — both
  /// inherit seen-clearing and restore-grace suppression.
  public static let awaitingInputTitleMarkers: Set<Character> = ["✳"]

  /// Title states that signal "blocked on the user" for the edge-triggered
  /// attention episodes in `AppModel.detectAwaitMarkerTransitions`.
  public static func titleSignalsAwaitingInput(_ m: TabTitleMetadata) -> Bool {
    guard let title = m.terminalTitle else { return false }
    if title.hasPrefix("[ ! ]") { return true }
    if let first = title.first, awaitingInputTitleMarkers.contains(first) { return true }
    return false
  }

  /// Codex prefixes its terminal title with "[ ! ]" (its
  /// `ACTION_REQUIRED_PREVIEW_PREFIX`) for as long as a view is blocked on
  /// the user — approvals, questions, input — and restores the normal title
  /// when unblocked. It is the only signal Codex emits unconditionally in
  /// terminals it does not recognize (its OSC 9 path is gated on terminal
  /// detection), so the title prefix doubles as a blocking-request flag.
  /// Safe to classify statelessly because Codex removes it when unblocked.
  private static func hasActionRequiredTitle(_ m: TabTitleMetadata) -> Bool {
    m.terminalTitle?.hasPrefix("[ ! ]") ?? false
  }

  /// Whether any *unfocused* tab needs the user — i.e. whether the sidebar is
  /// currently showing a marker that should breathe. The render loop uses this
  /// (further gated on window visibility and Reduce Motion) to decide whether to
  /// keep ticking, so an idle terminal parks the loop and holds its idle-CPU
  /// budget.
  public static func anyNeedsAction(tabs: [Tab], activeTabId: Tab.ID?) -> Bool {
    tabs.contains { tab in
      tab.id != activeTabId && classify(tab.titleMetadata, isActive: false) == .needsAction
    }
  }
}

/// A calm "breathing" pulse for the `needsAction` marker. Pure and
/// app-independent so it is unit-testable without a running render loop; the
/// AppKit layer feeds it a per-frame `now` and gates it on Reduce Motion.
public enum AttentionPulse {
  /// Announce-once timeline. A continuous breathing loop in the peripheral
  /// sidebar reads as blinking — the pattern the HIG and the peripheral-motion
  /// literature warn against, and one no 2026 peer ships (Ghostty, VS Code,
  /// Zed all announce once, then rest). Instead: a brief entrance bloom when a
  /// tab starts needing the user, a static marker at rest, and one gentle dip
  /// every `pingPeriod` while still unattended. Between windows no frames are
  /// needed, so the render loop parks.
  public static let entranceDuration: TimeInterval = 0.6
  public static let pingPeriod: TimeInterval = 45
  public static let pingDuration: TimeInterval = 0.8
  /// The re-ping dips to this alpha and back — shallow enough to never read
  /// as a blink, deep enough for peripheral vision to catch the motion.
  public static let pingFloor: Double = 0.55
  public static let haloMaxScale: Double = 1.8
  public static let haloPeakAlpha: Double = 0.35

  /// Marker alpha at `elapsed` seconds since the tab entered needsAction.
  public static func markerAlpha(elapsed: TimeInterval) -> Double {
    guard elapsed > 0 else { return 0 }
    if elapsed < entranceDuration {
      return (1 - cos(.pi * elapsed / entranceDuration)) / 2
    }
    let rest = elapsed - entranceDuration
    let cycle = rest.truncatingRemainder(dividingBy: pingPeriod)
    // The first ping fires one full period after the entrance, so a freshly
    // announced tab stays quiet for `pingPeriod` before its first reminder.
    if rest >= pingPeriod, cycle < pingDuration {
      let bump = (1 - cos(2 * .pi * cycle / pingDuration)) / 2  // 0 → 1 → 0
      return 1 - (1 - pingFloor) * bump
    }
    return 1
  }

  /// Entrance halo: a square bloom behind the marker that expands and fades
  /// through the announce. nil outside the entrance window.
  public static func halo(elapsed: TimeInterval) -> (scale: Double, alpha: Double)? {
    guard elapsed >= 0, elapsed < entranceDuration else { return nil }
    let eased = 1 - pow(1 - elapsed / entranceDuration, 3)  // ease-out cubic
    let alpha = haloPeakAlpha * (1 - eased)
    guard alpha > 0.001 else { return nil }
    return (scale: 1 + (haloMaxScale - 1) * eased, alpha: alpha)
  }

  /// True while the marker sits inside an animation window (entrance or
  /// ping). Between windows the marker is static and no frames are needed.
  public static func isAnimating(elapsed: TimeInterval) -> Bool {
    guard elapsed >= 0 else { return true }
    if elapsed < entranceDuration { return true }
    let rest = elapsed - entranceDuration
    let cycle = rest.truncatingRemainder(dividingBy: pingPeriod)
    return rest >= pingPeriod && cycle < pingDuration
  }

  /// Seconds until the next animation window opens; 0 while inside one. Lets
  /// the frame loop schedule a single wake instead of polling while resting.
  public static func delayToNextAnimation(elapsed: TimeInterval) -> TimeInterval {
    guard elapsed >= 0, !isAnimating(elapsed: elapsed) else { return 0 }
    let rest = elapsed - entranceDuration
    if rest < pingPeriod { return pingPeriod - rest }
    return pingPeriod - rest.truncatingRemainder(dividingBy: pingPeriod)
  }

  /// Replace the low alpha byte of a `0xRRGGBBAA` colour with `a` (clamped to
  /// `0…1`), leaving its RGB untouched.
  public static func applyAlpha(_ color: UInt32, _ a: Double) -> UInt32 {
    let byte = UInt32((min(max(a, 0), 1) * 255).rounded())
    return (color & 0xFFFF_FF00) | byte
  }
}
