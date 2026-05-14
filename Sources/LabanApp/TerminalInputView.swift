import AppKit
import Carbon.HIToolbox
import LabanCore

// MARK: - App commands

enum AppCommand: Equatable {
  case newTab
  case closeTab
  case selectTab(index: Int)
  case copy
  case paste
  case find
}

// MARK: - Key descriptor

struct TerminalKeyDescriptor {
  var action: KeyAction
  var key: Key?
  var modifiers: KeyModifiers
  var characters: String?
  var charactersIgnoringModifiers: String?
  var isComposing: Bool
  var isRepeat: Bool

  init(
    action: KeyAction,
    key: Key?,
    modifiers: KeyModifiers,
    characters: String? = nil,
    charactersIgnoringModifiers: String? = nil,
    isComposing: Bool = false,
    isRepeat: Bool = false
  ) {
    self.action = action
    self.key = key
    self.modifiers = modifiers
    self.characters = characters
    self.charactersIgnoringModifiers = charactersIgnoringModifiers
    self.isComposing = isComposing
    self.isRepeat = isRepeat
  }
}

// MARK: - Input route

enum TerminalInputRoute: Equatable {
  case appCommand(AppCommand)
  case swallowCommand
  case nativeText
  case encodedKey(KeyEvent)
  case ignored
}

// MARK: - Routing logic

extension TerminalKeyDescriptor {
  func route(hasMarkedText: Bool = false) -> TerminalInputRoute {
    if action == .release {
      guard let key else { return .ignored }
      return .encodedKey(KeyEvent(action: .release, key: key, modifiers: modifiers))
    }

    if hasMarkedText {
      return .nativeText
    }

    if modifiers.contains(.command) {
      return routeCommand()
    }

    if modifiers.contains(.control), let key {
      return .encodedKey(
        KeyEvent(
          action: action,
          key: key,
          modifiers: modifiers,
          unshiftedCodepoint: unshiftedCodepoint
        ))
    }

    if let key, Self.isNonTextKey(key) {
      return .encodedKey(KeyEvent(action: action, key: key, modifiers: modifiers))
    }

    return .nativeText
  }

  private func routeCommand() -> TerminalInputRoute {
    guard let key else { return .swallowCommand }
    switch key {
    case .t: return .appCommand(.newTab)
    case .w: return .appCommand(.closeTab)
    case .c: return .appCommand(.copy)
    case .v: return .appCommand(.paste)
    case .f: return .appCommand(.find)
    case .digit1: return .appCommand(.selectTab(index: 0))
    case .digit2: return .appCommand(.selectTab(index: 1))
    case .digit3: return .appCommand(.selectTab(index: 2))
    case .digit4: return .appCommand(.selectTab(index: 3))
    case .digit5: return .appCommand(.selectTab(index: 4))
    case .digit6: return .appCommand(.selectTab(index: 5))
    case .digit7: return .appCommand(.selectTab(index: 6))
    case .digit8: return .appCommand(.selectTab(index: 7))
    case .digit9: return .appCommand(.selectTab(index: 8))
    default: return .swallowCommand
    }
  }

  static func isNonTextKey(_ key: Key) -> Bool {
    switch key {
    case .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
      .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
      .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24,
      .escape, .backspace, .enter, .tab,
      .delete, .home, .end, .pageUp, .pageDown, .insert:
      return true
    default:
      return false
    }
  }

  var unshiftedCodepoint: UInt32 {
    guard let chars = charactersIgnoringModifiers,
      let scalar = chars.unicodeScalars.first
    else { return 0 }
    let v = scalar.value
    guard v < 0xF700 || v > 0xF8FF else { return 0 }
    return v
  }

  static func buildTextKeyEvent(
    text: String,
    descriptor: TerminalKeyDescriptor?
  ) -> KeyEvent? {
    guard let descriptor, let key = descriptor.key else { return nil }
    let firstScalar = text.unicodeScalars.first?.value ?? 0
    let isC0 = firstScalar <= 0x1F || firstScalar == 0x7F
    let isPUA = firstScalar >= 0xF700 && firstScalar <= 0xF8FF
    var consumed: KeyModifiers = []
    if descriptor.modifiers.contains(.shift) { consumed.insert(.shift) }
    if descriptor.modifiers.contains(.alt) { consumed.insert(.alt) }
    return KeyEvent(
      action: descriptor.action,
      key: key,
      modifiers: descriptor.modifiers,
      consumedModifiers: consumed,
      unshiftedCodepoint: descriptor.unshiftedCodepoint,
      text: (isC0 || isPUA) ? nil : text
    )
  }

  static func selectorKeyEvent(
    for selector: Selector,
    modifiers: KeyModifiers = []
  ) -> KeyEvent? {
    let key: Key
    switch selector {
    case #selector(NSResponder.insertNewline(_:)): key = .enter
    case #selector(NSResponder.deleteBackward(_:)): key = .backspace
    case #selector(NSResponder.cancelOperation(_:)): key = .escape
    case #selector(NSResponder.insertTab(_:)): key = .tab
    case #selector(NSResponder.insertBacktab(_:)):
      return KeyEvent(action: .press, key: .tab, modifiers: modifiers.union(.shift))
    default: return nil
    }
    return KeyEvent(action: .press, key: key, modifiers: modifiers)
  }
}

// MARK: - NSEvent → TerminalKeyDescriptor

extension TerminalKeyDescriptor {
  init(keyDown event: NSEvent) {
    let mods = KeyModifiers(appKitFlags: event.modifierFlags)
    let key = Self.resolveKey(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers
    )
    self.init(
      action: event.isARepeat ? .held : .press,
      key: key,
      modifiers: mods,
      characters: event.characters,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      isRepeat: event.isARepeat
    )
  }

  init(keyUp event: NSEvent) {
    let mods = KeyModifiers(appKitFlags: event.modifierFlags)
    let key = Self.resolveKey(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers
    )
    self.init(action: .release, key: key, modifiers: mods)
  }

  static func resolveKey(keyCode: UInt16, charactersIgnoringModifiers: String?) -> Key? {
    if let chars = charactersIgnoringModifiers,
      let scalar = chars.unicodeScalars.first,
      scalar.value >= 0xF700 && scalar.value <= 0xF8FF,
      let key = keyFromPUA(scalar)
    {
      return key
    }
    return keyFromCode(keyCode)
  }

  static func keyFromPUA(_ scalar: UnicodeScalar) -> Key? {
    switch Int(scalar.value) {
    case NSUpArrowFunctionKey: return .arrowUp
    case NSDownArrowFunctionKey: return .arrowDown
    case NSLeftArrowFunctionKey: return .arrowLeft
    case NSRightArrowFunctionKey: return .arrowRight
    case NSPageUpFunctionKey: return .pageUp
    case NSPageDownFunctionKey: return .pageDown
    case NSHomeFunctionKey: return .home
    case NSEndFunctionKey: return .end
    case NSDeleteFunctionKey: return .delete
    case NSInsertFunctionKey: return .insert
    case NSF1FunctionKey: return .f1
    case NSF2FunctionKey: return .f2
    case NSF3FunctionKey: return .f3
    case NSF4FunctionKey: return .f4
    case NSF5FunctionKey: return .f5
    case NSF6FunctionKey: return .f6
    case NSF7FunctionKey: return .f7
    case NSF8FunctionKey: return .f8
    case NSF9FunctionKey: return .f9
    case NSF10FunctionKey: return .f10
    case NSF11FunctionKey: return .f11
    case NSF12FunctionKey: return .f12
    case NSF13FunctionKey: return .f13
    case NSF14FunctionKey: return .f14
    case NSF15FunctionKey: return .f15
    case NSF16FunctionKey: return .f16
    case NSF17FunctionKey: return .f17
    case NSF18FunctionKey: return .f18
    case NSF19FunctionKey: return .f19
    case NSF20FunctionKey: return .f20
    case NSF21FunctionKey: return .f21
    case NSF22FunctionKey: return .f22
    case NSF23FunctionKey: return .f23
    case NSF24FunctionKey: return .f24
    default: return nil
    }
  }

  static func keyFromCode(_ keyCode: UInt16) -> Key? {
    switch Int(keyCode) {
    case kVK_ANSI_A: return .a
    case kVK_ANSI_B: return .b
    case kVK_ANSI_C: return .c
    case kVK_ANSI_D: return .d
    case kVK_ANSI_E: return .e
    case kVK_ANSI_F: return .f
    case kVK_ANSI_G: return .g
    case kVK_ANSI_H: return .h
    case kVK_ANSI_I: return .i
    case kVK_ANSI_J: return .j
    case kVK_ANSI_K: return .k
    case kVK_ANSI_L: return .l
    case kVK_ANSI_M: return .m
    case kVK_ANSI_N: return .n
    case kVK_ANSI_O: return .o
    case kVK_ANSI_P: return .p
    case kVK_ANSI_Q: return .q
    case kVK_ANSI_R: return .r
    case kVK_ANSI_S: return .s
    case kVK_ANSI_T: return .t
    case kVK_ANSI_U: return .u
    case kVK_ANSI_V: return .v
    case kVK_ANSI_W: return .w
    case kVK_ANSI_X: return .x
    case kVK_ANSI_Y: return .y
    case kVK_ANSI_Z: return .z
    case kVK_ANSI_0: return .digit0
    case kVK_ANSI_1: return .digit1
    case kVK_ANSI_2: return .digit2
    case kVK_ANSI_3: return .digit3
    case kVK_ANSI_4: return .digit4
    case kVK_ANSI_5: return .digit5
    case kVK_ANSI_6: return .digit6
    case kVK_ANSI_7: return .digit7
    case kVK_ANSI_8: return .digit8
    case kVK_ANSI_9: return .digit9
    case kVK_Return: return .enter
    case kVK_Delete: return .backspace
    case kVK_Escape: return .escape
    case kVK_Tab: return .tab
    case kVK_Space: return .space
    case kVK_ANSI_Equal: return .equal
    case kVK_ANSI_Minus: return .minus
    case kVK_ANSI_Quote: return .quote
    case kVK_ANSI_Semicolon: return .semicolon
    case kVK_ANSI_Slash: return .slash
    case kVK_ANSI_Backslash: return .backslash
    case kVK_ANSI_Grave: return .backquote
    case kVK_ANSI_LeftBracket: return .bracketLeft
    case kVK_ANSI_RightBracket: return .bracketRight
    case kVK_ANSI_Comma: return .comma
    case kVK_ANSI_Period: return .period
    case kVK_UpArrow: return .arrowUp
    case kVK_DownArrow: return .arrowDown
    case kVK_LeftArrow: return .arrowLeft
    case kVK_RightArrow: return .arrowRight
    case kVK_ForwardDelete: return .delete
    case kVK_Home: return .home
    case kVK_End: return .end
    case kVK_PageUp: return .pageUp
    case kVK_PageDown: return .pageDown
    case kVK_Help: return .insert
    case kVK_F1: return .f1
    case kVK_F2: return .f2
    case kVK_F3: return .f3
    case kVK_F4: return .f4
    case kVK_F5: return .f5
    case kVK_F6: return .f6
    case kVK_F7: return .f7
    case kVK_F8: return .f8
    case kVK_F9: return .f9
    case kVK_F10: return .f10
    case kVK_F11: return .f11
    case kVK_F12: return .f12
    case kVK_F13: return .f13
    case kVK_F14: return .f14
    case kVK_F15: return .f15
    case kVK_F16: return .f16
    case kVK_F17: return .f17
    case kVK_F18: return .f18
    case kVK_F19: return .f19
    case kVK_F20: return .f20
    default: return nil
    }
  }
}

// MARK: - KeyModifiers from AppKit flags

extension KeyModifiers {
  init(appKitFlags flags: NSEvent.ModifierFlags) {
    var raw: Int32 = 0
    if flags.contains(.shift) { raw |= KeyModifiers.shift.rawValue }
    if flags.contains(.control) { raw |= KeyModifiers.control.rawValue }
    if flags.contains(.option) { raw |= KeyModifiers.alt.rawValue }
    if flags.contains(.command) { raw |= KeyModifiers.command.rawValue }
    if flags.contains(.capsLock) { raw |= KeyModifiers.capsLock.rawValue }
    self.init(rawValue: raw)
  }
}
