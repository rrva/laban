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

  /// Codex prefixes its terminal title with "[ ! ]" (its
  /// `ACTION_REQUIRED_PREVIEW_PREFIX`) for as long as a view is blocked on
  /// the user — approvals, questions, input — and restores the normal title
  /// when unblocked. It is the only signal Codex emits unconditionally in
  /// terminals it does not recognize (its OSC 9 path is gated on terminal
  /// detection), so the title prefix doubles as a blocking-request flag.
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
  /// Seconds per breath. ~1.5s reads as calm; sub-second on/off reads as alarm.
  public static let period: TimeInterval = 1.5
  /// The marker never fully fades — it breathes between `floor` and full so it
  /// reads as a pulse, not a blink. A 0.55 floor proved too subtle to catch
  /// the eye ("the hues it shifts between are too little"); 0.25 nearly
  /// extinguishes the dot at the trough so each breath has a visible swing.
  public static let floor: Double = 0.25

  /// Alpha in `[floor, 1.0]` following a raised-cosine ("ease in/out") breath.
  /// Anchored to an absolute clock so every `needsAction` tab pulses in unison.
  public static func alpha(at now: Date) -> Double {
    let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
    let phase = t / period * 2 * Double.pi
    let unit = (1 - cos(phase)) / 2  // 0 → 1 → 0, smooth at both ends
    return floor + (1 - floor) * unit
  }

  /// Replace the low alpha byte of a `0xRRGGBBAA` colour with `a` (clamped to
  /// `0…1`), leaving its RGB untouched.
  public static func applyAlpha(_ color: UInt32, _ a: Double) -> UInt32 {
    let byte = UInt32((min(max(a, 0), 1) * 255).rounded())
    return (color & 0xFFFF_FF00) | byte
  }
}
