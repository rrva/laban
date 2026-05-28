import AppKit
import LabanCore

enum TerminalMouseInput {
  static func surfacePosition(
    viewPoint: NSPoint,
    boundsHeight: CGFloat,
    sidebarWidth: CGFloat
  ) -> (x: Float, y: Float) {
    (
      Float(viewPoint.x - sidebarWidth),
      Float(boundsHeight - viewPoint.y)
    )
  }

  static func surfaceSize(
    boundsWidth: CGFloat,
    boundsHeight: CGFloat,
    sidebarWidth: CGFloat
  ) -> (width: Int, height: Int) {
    (
      max(1, Int(boundsWidth - sidebarWidth)),
      max(1, Int(boundsHeight))
    )
  }

  static func ghosttyModifierMask(from modifierFlags: NSEvent.ModifierFlags) -> Int {
    var m = 0
    if modifierFlags.contains(.shift) { m |= 1 }
    if modifierFlags.contains(.control) { m |= 2 }
    if modifierFlags.contains(.option) { m |= 4 }
    if modifierFlags.contains(.command) { m |= 8 }
    return m
  }

  static func trackedTerminalButton(
    _ trackedButton: MouseButton,
    matching expectedButton: MouseButton
  ) -> MouseButton? {
    trackedButton == expectedButton ? trackedButton : nil
  }

  /// What a left mouse-button press should do in terminal content.
  enum LeftMouseDownDisposition: Equatable {
    /// Start a Laban-native text selection immediately; nothing is forwarded.
    case localSelection
    /// The app has mouse tracking on, so hold the press: a drag becomes a
    /// native selection (the point of selecting without the Shift bypass),
    /// while a release with no drag is forwarded as a press+release click so
    /// the app's click-to-act behaviors keep working.
    case deferUnderTracking
  }

  /// Route a left press. Shift always forces native selection (the historical
  /// override, preserved). Otherwise an app with mouse tracking on defers so a
  /// plain drag can select without Shift; with no tracking, a plain press just
  /// selects as before.
  static func leftMouseDownDisposition(
    mouseTracking: Bool,
    shiftHeld: Bool
  ) -> LeftMouseDownDisposition {
    if shiftHeld { return .localSelection }
    return mouseTracking ? .deferUnderTracking : .localSelection
  }
}
