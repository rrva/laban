import Foundation
import LabanCore

/// Owns the cursor-blink timer and its phase state.
///
/// Exactly one `CursorBlinkDriver` exists per `TerminalBitmapView`. It owns a
/// main-queue `DispatchSourceTimer` that fires every `CursorBlinkPolicy.blinkInterval`
/// (0.5 s) and toggles `phaseVisible`. The timer runs only when all three gates
/// are true (blink enabled + window visible + cursor visible). When any gate
/// opens the timer is cancelled and the phase resets to `true` (solid cursor).
///
/// `noteInput()` forces the phase to visible and restarts the timer interval
/// so the cursor stays solid while the user is typing and blinks only after
/// a full interval of silence.
///
/// All methods and properties must be called on the **main queue**.
final class CursorBlinkDriver {

  // MARK: - Properties

  /// Current blink phase: `true` = cursor drawn, `false` = cursor hidden.
  private(set) var phaseVisible: Bool = true

  /// Called on every phase flip (on the main queue). The caller should
  /// trigger an immediate repaint so the cursor toggles without waiting
  /// up to 125 ms for the next 8 Hz display-link tick.
  var onPhaseFlip: (() -> Void)?

  // MARK: - Private state

  private var timer: DispatchSourceTimer?
  private(set) var timerRunning = false
  /// Set to `true` by the timer handler when a phase flip fires between
  /// `advanceFrame` calls. `consumePendingFlip()` returns and clears it.
  private var pendingFlip = false

  // MARK: - Init

  deinit {
    stopTimer()
  }

  // MARK: - Pending-flip consumption

  /// Returns `true` if the timer fired a phase flip since the last call,
  /// then clears the flag. Called once per `advanceFrame` to drive the
  /// `cursorBlinkFrame` decision.
  func consumePendingFlip() -> Bool {
    let had = pendingFlip
    pendingFlip = false
    return had
  }

  // MARK: - Input notification

  /// Called at the start of `keyDown(with:)` and `insertText(_:replacementRange:)`.
  /// Forces phase to visible and restarts the interval so the cursor stays
  /// solid while typing.
  func noteInput() {
    phaseVisible = true
    pendingFlip = false   // cancel any in-flight flip so the frame guard passes correctly
    if timerRunning {
      restartTimer()
    }
  }

  // MARK: - Gate synchronization

  /// Called after each rendered frame and from window key/occlusion observers.
  ///
  /// Starts or stops the timer according to `CursorBlinkPolicy.timerShouldRun`.
  /// When the timer stops the phase resets to `true` (solid) — a cursor that
  /// was hidden in the off-phase instantly becomes solid, matching the
  /// "solid when unfocused or idle" design decision.
  func sync(
    blinkActive: Bool,
    windowVisibleToUser: Bool,
    cursorVisible: Bool
  ) {
    let shouldRun = CursorBlinkPolicy.timerShouldRun(
      blinkActive: blinkActive,
      windowVisibleToUser: windowVisibleToUser,
      cursorVisible: cursorVisible)

    if shouldRun, !timerRunning {
      startTimer()
    } else if !shouldRun, timerRunning {
      // Capture the phase BEFORE stopTimer resets it: stopping mid-off-phase
      // must repaint, or a resigning window freezes with the cursor hidden
      // (the display link parks, so no later tick would fix it).
      let wasHidden = !phaseVisible
      stopTimer()
      if wasHidden {
        // Re-arm the pending flip after stopTimer cleared it so the repaint
        // frame's `consumePendingFlip()` guard passes and actually paints
        // the now-solid cursor.
        pendingFlip = true
        onPhaseFlip?()
      }
    }
  }

  // MARK: - Timer management

  /// The timer's event-handler body. Toggles the phase, marks the flip
  /// pending for the next frame guard, and requests an immediate repaint.
  private func timerFired() {
    phaseVisible.toggle()
    pendingFlip = true
    onPhaseFlip?()
  }

  /// Test hook: run the production timer handler synchronously, as if the
  /// 500 ms interval had elapsed. Lets tests reach the hidden phase
  /// deterministically without real waits. Only valid while the timer is
  /// running (mirrors when the real handler can fire).
  func simulateTimerFireForTesting() {
    guard timerRunning else { return }
    timerFired()
  }

  private func startTimer() {
    timerRunning = true
    let t = DispatchSource.makeTimerSource(queue: .main)
    let interval = CursorBlinkPolicy.blinkInterval
    t.schedule(
      deadline: .now() + interval,
      repeating: interval,
      leeway: .milliseconds(20))
    t.setEventHandler { [weak self] in
      self?.timerFired()
    }
    t.resume()
    timer = t
  }

  private func stopTimer() {
    timerRunning = false
    timer?.cancel()
    timer = nil
    phaseVisible = true
    pendingFlip = false
  }

  private func restartTimer() {
    guard let t = timer else { return }
    let interval = CursorBlinkPolicy.blinkInterval
    t.schedule(
      deadline: .now() + interval,
      repeating: interval,
      leeway: .milliseconds(20))
  }
}
