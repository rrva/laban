import Foundation

/// Idle policy for the cursor blink timer.
///
/// Mirrors `TerminalIdlePolicy` in shape: pure and AppKit-free so the
/// "should the timer be running?" decision is unit-tested without a window.
///
/// The timer must run only when ALL three conditions are true:
///   1. Blink is enabled (user setting or program DECSCUSR override)
///   2. The window is visible to the user (key + not occluded)
///   3. The cursor is visible in the snapshot
///
/// When any gate is false the timer stops and the phase resets to visible
/// (solid cursor) so the cursor is never frozen in the hidden phase.
public enum CursorBlinkPolicy {

  /// Toggle interval: cursor flips every 500 ms (2 Hz), matching today's
  /// `TerminalBitmapView.cursorBlinkInterval` constant.
  public static let blinkInterval: TimeInterval = 0.5

  /// Whether the blink timer should be running.
  ///
  /// - Parameters:
  ///   - blinkActive:          Resolved blink flag from `CursorStyleResolver` (user
  ///                           setting OR program DECSCUSR/mode-12 override).
  ///   - windowVisibleToUser:  The window is the key window *and* not occluded.
  ///   - cursorVisible:        The cursor is visible in the current snapshot.
  public static func timerShouldRun(
    blinkActive: Bool,
    windowVisibleToUser: Bool,
    cursorVisible: Bool
  ) -> Bool {
    blinkActive && windowVisibleToUser && cursorVisible
  }
}
