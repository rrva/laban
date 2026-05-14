import Foundation
import LabanCore

enum DebugRuntimeKeyInput {
  static func key(fromName name: String) -> Key? {
    switch name.lowercased() {
    case "a": return .a
    case "b": return .b
    case "c": return .c
    case "d": return .d
    case "e": return .e
    case "f": return .f
    case "g": return .g
    case "h": return .h
    case "i": return .i
    case "j": return .j
    case "k": return .k
    case "l": return .l
    case "m": return .m
    case "n": return .n
    case "o": return .o
    case "p": return .p
    case "q": return .q
    case "r": return .r
    case "s": return .s
    case "t": return .t
    case "u": return .u
    case "v": return .v
    case "w": return .w
    case "x": return .x
    case "y": return .y
    case "z": return .z
    case "0": return .digit0
    case "1": return .digit1
    case "2": return .digit2
    case "3": return .digit3
    case "4": return .digit4
    case "5": return .digit5
    case "6": return .digit6
    case "7": return .digit7
    case "8": return .digit8
    case "9": return .digit9
    case "enter": return .enter
    case "backspace": return .backspace
    case "escape": return .escape
    case "tab": return .tab
    case "space": return .space
    case "delete": return .delete
    case "home": return .home
    case "end": return .end
    case "pageup": return .pageUp
    case "pagedown": return .pageDown
    case "insert": return .insert
    case "arrowup": return .arrowUp
    case "arrowdown": return .arrowDown
    case "arrowleft": return .arrowLeft
    case "arrowright": return .arrowRight
    case "f1": return .f1
    case "f2": return .f2
    case "f3": return .f3
    case "f4": return .f4
    case "f5": return .f5
    case "f6": return .f6
    case "f7": return .f7
    case "f8": return .f8
    case "f9": return .f9
    case "f10": return .f10
    case "f11": return .f11
    case "f12": return .f12
    case "f13": return .f13
    case "f14": return .f14
    case "f15": return .f15
    case "f16": return .f16
    case "f17": return .f17
    case "f18": return .f18
    case "f19": return .f19
    case "f20": return .f20
    case "f21": return .f21
    case "f22": return .f22
    case "f23": return .f23
    case "f24": return .f24
    default: return nil
    }
  }

  static func modifiers(from strings: [String]?) -> KeyModifiers {
    var modifiers: KeyModifiers = []
    for string in strings ?? [] {
      switch string.lowercased() {
      case "shift": modifiers.insert(.shift)
      case "control": modifiers.insert(.control)
      case "alt", "option": modifiers.insert(.alt)
      case "command", "super": modifiers.insert(.command)
      default: break
      }
    }
    return modifiers
  }

  static func action(from type: String?) -> KeyAction {
    switch type?.lowercased() {
    case "release": return .release
    case "repeat": return .held
    default: return .press
    }
  }

  static func commandRoute(for key: Key) -> (route: String, command: String?) {
    switch key {
    case .t: return ("appCommand", "newTab")
    case .w: return ("appCommand", "closeTab")
    case .c: return ("appCommand", "copy")
    case .v: return ("appCommand", "paste")
    case .f: return ("appCommand", "find")
    case .digit1, .digit2, .digit3, .digit4, .digit5,
      .digit6, .digit7, .digit8, .digit9:
      return ("appCommand", "selectTab")
    default: return ("ignored", nil)
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
    case .digit9: return 8
    default: return nil
    }
  }
}
