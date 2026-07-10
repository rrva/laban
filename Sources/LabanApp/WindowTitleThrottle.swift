import Foundation

/// Debounces `NSWindow.title` assignment to at most one set per
/// `minimumIntervalNs`, without ever losing the final value.
///
/// A TUI that puts a spinner glyph in its OSC title (the escape sequence a
/// program prints to set its terminal tab/window title, e.g. "⠴ laban") can
/// change the title several times per second. Each `NSWindow.title` set costs
/// real AppKit work, so applying every change as it arrives burns CPU on
/// state that flips right back. This type decides when to apply and when to
/// hold a change for a trailing apply, but it never touches AppKit itself:
/// it is a pure value type, main-thread-confined by convention (the caller
/// owns thread discipline), so it is fully unit-testable without a window.
///
/// Time is passed in by the caller as monotonic uptime nanoseconds
/// (`DispatchTime.now().uptimeNanoseconds`) rather than read internally,
/// which is what makes `decide(title:nowNs:)` a deterministic pure function.
struct WindowTitleThrottle {
  enum Decision: Equatable {
    /// Apply this title to the window right now.
    case apply
    /// Hold this title; schedule a trailing apply in `afterNs` nanoseconds.
    case `defer`(afterNs: UInt64)
    /// Nothing to do: the title is unchanged, or a trailing apply is already
    /// pending and will pick up the latest value when it fires.
    case none
  }

  let minimumIntervalNs: UInt64
  private(set) var lastAppliedTitle: String?
  private(set) var lastApplyNs: UInt64?
  private var deferPending = false

  init(minimumIntervalNs: UInt64) {
    self.minimumIntervalNs = minimumIntervalNs
  }

  /// Decide what to do about a candidate title observed at `nowNs`. Does not
  /// mutate `lastAppliedTitle`/`lastApplyNs`; the caller commits an accepted
  /// title via `markApplied(title:nowNs:)` once it has actually set
  /// `window.title`.
  mutating func decide(title: String, nowNs: UInt64) -> Decision {
    guard title != lastAppliedTitle else { return .none }
    // A trailing apply is already scheduled: it will re-read the current
    // title when it fires, so this change rides along for free. Scheduling a
    // second timer here would just mean two AppKit sets close together
    // instead of one, which is exactly the churn this type exists to avoid.
    guard !deferPending else { return .none }
    if let lastApplyNs {
      // Clamp to 0 rather than underflow if `nowNs` ever regresses relative
      // to `lastApplyNs` (it should not, since both come from the same
      // monotonic clock, but a 0-elapsed reading must fall into the "still
      // within the interval" branch below, not wrap around to a huge value).
      let elapsed = nowNs >= lastApplyNs ? nowNs - lastApplyNs : 0
      if elapsed < minimumIntervalNs {
        deferPending = true
        return .defer(afterNs: minimumIntervalNs - elapsed)
      }
    }
    // Never applied, or the last apply is at least one interval old: a
    // single, isolated title change (e.g. `cd`) must not lag.
    return .apply
  }

  /// Record that `title` was applied to the window at `nowNs`. Called both
  /// on the immediate `.apply` path and by the trailing timer once it fires,
  /// which is also what clears the pending-defer latch.
  mutating func markApplied(title: String, nowNs: UInt64) {
    lastAppliedTitle = title
    lastApplyNs = nowNs
    deferPending = false
  }
}
