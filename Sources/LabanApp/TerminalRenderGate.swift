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
    var wakeAfter: TimeInterval?
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

  struct BackpressureInvalidationDecision: Equatable {
    var shouldPark: Bool
  }

  /// Failures that still retry on the next main-loop turn before the retry
  /// drops to `pacedRenderFailureRetrySeconds`. A single transient miss must
  /// repaint immediately — with the display link parked that retry is the
  /// latency path for a keystroke — so the fast path is preserved for the first
  /// attempts and only a repeating failure is slowed down.
  static let immediateRenderFailureRetries = 2
  /// Retry cadence once a backend keeps refusing the same frame. Matches the
  /// parked display link's own floor (`TerminalIdlePolicy`), so a stuck render
  /// costs about what an idle window costs.
  static let pacedRenderFailureRetrySeconds: TimeInterval =
    1.0 / TimeInterval(TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)

  /// How long to wait before re-attempting a frame whose backend `render(...)`
  /// returned false, given how many consecutive frames have now failed.
  ///
  /// Zero means "next main-loop turn". A non-zero delay exists because that
  /// immediate retry is unbounded: `MetalDrawableScheduler.beginFrame` blocks
  /// the main thread for up to 16 ms per non-scroll attempt, so a failure that
  /// repeats leaves the main thread unavailable ~16 ms out of every 17 ms and a
  /// tab click waits seconds to be serviced. Slowing the retry keeps a repair
  /// path alive (the failure may clear on its own with no other wake) at a cost
  /// input latency does not notice.
  static func renderFailureRetryDelay(consecutiveFailures: Int) -> TimeInterval {
    consecutiveFailures <= immediateRenderFailureRetries ? 0 : pacedRenderFailureRetrySeconds
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
      return SynchronizedOutputDecision(
        shouldDefer: false, shouldResetMode: false, hold: nil, wakeAfter: nil)
    }

    let currentHold: SynchronizedOutputHold
    if let hold, hold.sessionId == sessionId {
      currentHold = hold
    } else {
      currentHold = SynchronizedOutputHold(sessionId: sessionId, startedAt: now)
    }

    let elapsed = now.timeIntervalSince(currentHold.startedAt)
    if elapsed >= timeout {
      return SynchronizedOutputDecision(
        shouldDefer: false, shouldResetMode: true, hold: nil, wakeAfter: nil)
    }

    // Carry the time remaining to the watchdog so a deferred frame can schedule
    // its own re-wake. Without it the held frame relies entirely on the display
    // link still ticking; if the link parks the watchdog reset is never reached
    // and the frame freezes until the user scrolls.
    let wakeAfter = max(0.001, timeout - elapsed)
    return SynchronizedOutputDecision(
      shouldDefer: true, shouldResetMode: false, hold: currentHold, wakeAfter: wakeAfter)
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

  static func backpressureInvalidationDecision(
    renderInvalidated: Bool,
    renderInvalidatedFromGPUBackpressureOnly: Bool,
    terminalDirty: Bool,
    activeTerminalDirty: Bool,
    tabChanged: Bool,
    cursorBlinkFrame: Bool,
    attentionAnimating: Bool,
    scrollAnimating: Bool,
    renderingResizeFrame: Bool,
    gpuCellCommandFallbackPending: Bool
  ) -> BackpressureInvalidationDecision {
    let independentWork =
      terminalDirty || activeTerminalDirty || tabChanged || cursorBlinkFrame || attentionAnimating
      || scrollAnimating || renderingResizeFrame || gpuCellCommandFallbackPending

    return BackpressureInvalidationDecision(
      shouldPark: renderInvalidated && renderInvalidatedFromGPUBackpressureOnly && !independentWork)
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
