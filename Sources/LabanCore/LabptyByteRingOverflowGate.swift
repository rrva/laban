import Foundation

/// Distinguishes the byte-ring reader's first positioning read from a genuine
/// live fall-behind, so a restart reconnect does not raise the "output skipped"
/// badge for output that was never dropped while the user was watching.
///
/// `LabptyByteRingReader` reports `overflowed` whenever the gap between the
/// caller's last offset and the producer's current write offset exceeds the
/// readable window. The very first read starts from offset 0, so its gap spans
/// the session's entire lifetime: on any session that has ever emitted more than
/// a window of output (a build, an agent run, lots of `ls`), that first read
/// "overflows" by construction. That is a join-mid-stream repaint — the screen
/// is repainted from the window tail — not output dropped live. Only once the
/// reader holds an established mid-stream cursor does an overflow mean "we fell
/// behind the producer in real time", which is the rare event the badge marks.
public struct LabptyByteRingOverflowGate: Sendable {
  private var positioned: Bool

  public init() {
    self.positioned = false
  }

  /// Record one non-empty read and report whether an overflow on it is a genuine
  /// live drop (the badge-worthy event). The first read merely positions the
  /// cursor and is never a live drop, however far it spans; every read after it
  /// is judged purely on whether it overflowed. Call this exactly once per
  /// non-empty read, overflow or not, so the cursor is marked positioned even
  /// when the first read did not overflow.
  public mutating func isLiveDrop(overflowed: Bool) -> Bool {
    let wasPositioned = positioned
    positioned = true
    return overflowed && wasPositioned
  }
}
