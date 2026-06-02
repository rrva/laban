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
    /// The app has mouse tracking on, so forward the press — and the drag and
    /// release that follow — to it as SGR mouse reports (the iTerm2/Ghostty
    /// model). The app runs its own selection and can autoscroll its buffer
    /// past one screen, which is the only way to select text spanning more
    /// than one screen in a fullscreen renderer. Shift still forces native
    /// selection.
    case forwardToApp
  }

  /// Route a left press. Shift always forces native selection (the historical
  /// override, preserved). Otherwise an app with mouse tracking on receives the
  /// gesture as forwarded mouse reports so it can run its own selection and
  /// scroll; with no tracking, a plain press selects natively as before.
  static func leftMouseDownDisposition(
    mouseTracking: Bool,
    shiftHeld: Bool
  ) -> LeftMouseDownDisposition {
    if shiftHeld { return .localSelection }
    return mouseTracking ? .forwardToApp : .localSelection
  }
}
