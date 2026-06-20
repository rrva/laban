import Foundation
import LabanCore

enum DebugRuntimeKeyInput {
  static func key(fromName name: String) -> Key? {
    ControlKeyName.key(fromName: name)
  }

  static func modifiers(from strings: [String]?) -> KeyModifiers {
    ControlKeyName.modifiers(from: strings)
  }

  static func action(from type: String?) -> KeyAction {
    ControlKeyName.action(from: type)
  }

  static func commandRoute(for key: Key) -> (route: String, command: String?) {
    appCommandRoute(for: key, modifiers: .command)
  }

  static func appCommandRoute(
    for key: Key,
    modifiers: KeyModifiers
  ) -> (route: String, command: String?) {
    if modifiers.contains(.control), key == .tab {
      return modifiers.contains(.shift)
        ? ("appCommand", "selectPreviousTab")
        : ("appCommand", "selectNextTab")
    }

    guard modifiers.contains(.command) else { return ("ignored", nil) }

    if isCommandLineEditingKey(key, modifiers: modifiers) {
      return ("terminal", nil)
    }

    switch key {
    case .m: return ("appCommand", "minimize")
    case .t: return ("appCommand", "newTab")
    case .w: return ("appCommand", "closeTab")
    case .c: return ("appCommand", "copy")
    case .v: return ("appCommand", "paste")
    case .f: return ("appCommand", "find")
    case .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8:
      return ("appCommand", "selectTab")
    case .digit9:
      return ("appCommand", "selectLastTab")
    case .equal:
      return ("appCommand", "increaseFontSize")
    case .minus:
      return ("appCommand", "decreaseFontSize")
    case .digit0:
      return ("appCommand", "resetFontSize")
    case .arrowRight where modifiers.contains(.alt):
      return ("appCommand", "selectNextTab")
    case .arrowLeft where modifiers.contains(.alt):
      return ("appCommand", "selectPreviousTab")
    case .bracketRight where modifiers.contains(.shift):
      return ("appCommand", "selectNextTab")
    case .bracketLeft where modifiers.contains(.shift):
      return ("appCommand", "selectPreviousTab")
    default: return ("ignored", nil)
    }
  }

  static func isCommandLineEditingKey(_ key: Key, modifiers: KeyModifiers) -> Bool {
    commandLineEditingBytes(for: key, modifiers: modifiers) != nil
  }

  /// Mirror GUI M-2: a line-edit chord's release must not reach the PTY.
  static func isCommandLineEditingRelease(
    _ key: Key,
    modifiers: KeyModifiers,
    action: KeyAction
  ) -> Bool {
    action == .release && isCommandLineEditingKey(key, modifiers: modifiers)
  }

  static func commandLineEditingBytes(for key: Key, modifiers: KeyModifiers) -> [UInt8]? {
    guard modifiers.contains(.command) else { return nil }
    switch key {
    case .arrowLeft where !modifiers.contains(.alt):
      return [0x01]
    case .arrowRight where !modifiers.contains(.alt):
      return [0x05]
    case .backspace:
      return [0x15]
    default:
      return nil
    }
  }

  static func tabIndex(for key: Key) -> Int? {
    switch key {
    case .digit1: return 0
    case .digit2: return 1
    case .digit3: return 2
    case .digit4: return 3
    case .digit5: return 4
    case .digit6: return 5
    case .digit7: return 6
    case .digit8: return 7
    default: return nil
    }
  }
}
