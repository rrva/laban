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
    {
      return .needsAction
    }
    if m.notification != nil { return .done }
    if m.unseenOutput || m.bellAttention { return .passive }
    return .none
  }
}
