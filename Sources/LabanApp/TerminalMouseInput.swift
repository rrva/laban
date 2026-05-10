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
}
