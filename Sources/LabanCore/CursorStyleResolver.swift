import Foundation
import LabanTerminalCore

/// Resolves the effective cursor style and blink flag for a single frame.
///
/// Rule: when a program has explicitly set a cursor attribute via DECSCUSR or
/// DEC mode 12 (the `*Explicit` flags), the snapshot value wins; otherwise the
/// user's persisted preference applies.
///
/// Pure function: takes no UserDefaults, no AppKit — fully unit-testable.
public enum CursorStyleResolver {

  /// Resolve the effective cursor appearance for a single frame.
  ///
  /// - Parameters:
  ///   - userStyle:        The user's persisted style preference.
  ///   - userBlinkEnabled: The user's persisted blink preference.
  ///   - snapshotStyle:    `LABAN_CURSOR_STYLE_*` value from the libghostty snapshot.
  ///   - snapshotBlinking: `cursor_blinking` value from the libghostty snapshot.
  ///   - styleExplicit:    `cursor_style_explicit` — non-zero when a program overrode style.
  ///   - blinkExplicit:    `cursor_blink_explicit` — non-zero when a program overrode blink.
  /// - Returns: The `(style, blinking)` pair to use when drawing this frame.
  public static func resolve(
    userStyle: CursorSettings.Style,
    userBlinkEnabled: Bool,
    snapshotStyle: Int32,
    snapshotBlinking: Bool,
    styleExplicit: Int32,
    blinkExplicit: Int32
  ) -> (style: Int32, blinking: Bool) {
    let resolvedStyle: Int32 =
      styleExplicit != 0 ? snapshotStyle : userStyle.labanStyleValue
    let resolvedBlink: Bool =
      blinkExplicit != 0 ? snapshotBlinking : userBlinkEnabled
    return (resolvedStyle, resolvedBlink)
  }
}
