import Foundation
import LabanCore

enum TerminalRenderGate {
  struct SynchronizedOutputHold: Equatable {
    var sessionId: Session.ID
    var startedAt: Date
  }

  struct SynchronizedOutputDecision: Equatable {
    var shouldDefer: Bool
    var shouldResetMode: Bool
    var hold: SynchronizedOutputHold?
  }

  struct OutputSettleHold: Equatable {
    var sessionId: Session.ID
    var startedAt: Date
  }

  struct OutputSettleDecision: Equatable {
    var shouldDefer: Bool
    var hold: OutputSettleHold?
    var wakeAfter: TimeInterval?
  }

  static let synchronizedOutputMaxHoldSeconds: TimeInterval = 1.0
  static let outputSettleQuietSeconds: TimeInterval = 0.012
  static let remoteSnapshotOutputSettleQuietSeconds: TimeInterval = 0.008
  static let outputSettleMaxHoldSeconds: TimeInterval = 0.025

  static func settleQuietSeconds(
    remoteDirtyRanges: [LabandSnapshotDirtyRange]?
  ) -> TimeInterval {
    guard let remoteDirtyRanges, !remoteDirtyRanges.isEmpty else {
      return outputSettleQuietSeconds
    }
    return remoteSnapshotOutputSettleQuietSeconds
  }

  static func synchronizedOutputDecision(
    terminalDirty: Bool,
    synchronizedOutputActive: Bool,
    sessionId: Session.ID,
    now: Date,
    hold: SynchronizedOutputHold?,
    timeout: TimeInterval = synchronizedOutputMaxHoldSeconds
  ) -> SynchronizedOutputDecision {
    guard terminalDirty && synchronizedOutputActive else {
      return SynchronizedOutputDecision(shouldDefer: false, shouldResetMode: false, hold: nil)
    }

    let currentHold: SynchronizedOutputHold
    if let hold, hold.sessionId == sessionId {
      currentHold = hold
    } else {
      currentHold = SynchronizedOutputHold(sessionId: sessionId, startedAt: now)
    }

    if now.timeIntervalSince(currentHold.startedAt) >= timeout {
      return SynchronizedOutputDecision(shouldDefer: false, shouldResetMode: true, hold: nil)
    }

    return SynchronizedOutputDecision(
      shouldDefer: true, shouldResetMode: false, hold: currentHold)
  }

  static func outputSettleDecision(
    terminalDirty: Bool,
    sessionId: Session.ID,
    lastDirtyAt: Date?,
    now: Date,
    hold: OutputSettleHold?,
    quiet: TimeInterval = outputSettleQuietSeconds,
    maxHold: TimeInterval = outputSettleMaxHoldSeconds
  ) -> OutputSettleDecision {
    guard terminalDirty, let lastDirtyAt else {
      return OutputSettleDecision(shouldDefer: false, hold: nil, wakeAfter: nil)
    }

    let currentHold: OutputSettleHold
    if let hold, hold.sessionId == sessionId {
      currentHold = hold
    } else {
      currentHold = OutputSettleHold(sessionId: sessionId, startedAt: now)
    }

    let quietElapsed = now.timeIntervalSince(lastDirtyAt)
    let holdElapsed = now.timeIntervalSince(currentHold.startedAt)
    guard quietElapsed < quiet, holdElapsed < maxHold else {
      return OutputSettleDecision(shouldDefer: false, hold: nil, wakeAfter: nil)
    }

    let remainingQuiet = quiet - quietElapsed
    let remainingHold = maxHold - holdElapsed
    let wakeAfter = max(0.001, min(remainingQuiet, remainingHold))
    return OutputSettleDecision(
      shouldDefer: true, hold: currentHold, wakeAfter: wakeAfter)
  }

  struct ParkedFrameDecision: Equatable {
    var shouldRecord: Bool
    var signature: String?
  }

  /// The display link ticks every vsync while the window is visible, so the
  /// idle early-return in `advanceFrame` fires continuously. Recording every
  /// idle tick would overrun the bounded render-journal ring in seconds and
  /// bury real history. A park that leaves the viewport off the live bottom is
  /// the only diagnostically interesting one — it is the "scrolled down but the
  /// final frame never landed" signature — and only the first park at each
  /// distinct off-bottom position is worth an entry. At the live bottom the
  /// signature resets to `nil` so a later return to the same position logs
  /// again instead of being deduplicated against a stale park.
  static func parkedFrameDecision(
    appliedScrollRows: Int,
    lastParkSignature: String?
  ) -> ParkedFrameDecision {
    guard appliedScrollRows != 0 else {
      return ParkedFrameDecision(shouldRecord: false, signature: nil)
    }
    let signature = String(appliedScrollRows)
    return ParkedFrameDecision(
      shouldRecord: signature != lastParkSignature,
      signature: signature)
  }
}
