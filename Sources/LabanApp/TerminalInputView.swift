import AppKit

struct TerminalKeyEncoder {
  static let tabBytes: [UInt8] = [0x09]
  static let backtabBytes: [UInt8] = [0x1B, 0x5B, 0x5A]

  static func bytes(
    forControlModifiedCharacters characters: String?,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> [UInt8]? {
    let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control),
      !flags.contains(.command),
      !flags.contains(.option)
    else { return nil }

    if let scalar = singleScalar(in: characters) {
      let v = scalar.value
      if (v > 0 && v < 0x20) || v == 0x7F {
        return [UInt8(v)]
      }
    }

    guard let scalar = singleScalar(in: charactersIgnoringModifiers) else { return nil }
    let v = scalar.value
    switch v {
    case 0x41...0x5A: return [UInt8(v - 0x40)]  // Ctrl-A through Ctrl-Z.
    case 0x61...0x7A: return [UInt8(v - 0x60)]
    case 0x20, 0x40: return [0x00]  // Ctrl-Space / Ctrl-@.
    case 0x5B: return [0x1B]  // Ctrl-[.
    case 0x5C: return [0x1C]  // Ctrl-\.
    case 0x5D: return [0x1D]  // Ctrl-].
    case 0x5E: return [0x1E]  // Ctrl-^.
    case 0x5F: return [0x1F]  // Ctrl-_.
    case 0x3F: return [0x7F]  // Ctrl-?.
    default: return nil
    }
  }

  static func bytes(
    forOptionMetaCharactersIgnoringModifiers charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> [UInt8]? {
    let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.option),
      !flags.contains(.command),
      !flags.contains(.control),
      let scalar = singleScalar(in: charactersIgnoringModifiers)
    else { return nil }

    let v = scalar.value
    switch v {
    case 0x41...0x5A, 0x61...0x7A:
      return [0x1B, UInt8(v)]
    default:
      return nil
    }
  }

  static func bytes(forFunctionKeyScalar scalar: Int) -> [UInt8]? {
    switch scalar {
    case NSUpArrowFunctionKey: return [0x1B, 0x5B, 0x41]
    case NSDownArrowFunctionKey: return [0x1B, 0x5B, 0x42]
    case NSRightArrowFunctionKey: return [0x1B, 0x5B, 0x43]
    case NSLeftArrowFunctionKey: return [0x1B, 0x5B, 0x44]
    case NSPageUpFunctionKey: return [0x1B, 0x5B, 0x35, 0x7E]
    case NSPageDownFunctionKey: return [0x1B, 0x5B, 0x36, 0x7E]
    case NSHomeFunctionKey: return [0x1B, 0x5B, 0x48]
    case NSEndFunctionKey: return [0x1B, 0x5B, 0x46]
    case NSDeleteFunctionKey: return [0x1B, 0x5B, 0x33, 0x7E]
    case NSF1FunctionKey: return [0x1B, 0x4F, 0x50]
    case NSF2FunctionKey: return [0x1B, 0x4F, 0x51]
    case NSF3FunctionKey: return [0x1B, 0x4F, 0x52]
    case NSF4FunctionKey: return [0x1B, 0x4F, 0x53]
    case NSF5FunctionKey: return [0x1B, 0x5B, 0x31, 0x35, 0x7E]
    case NSF6FunctionKey: return [0x1B, 0x5B, 0x31, 0x37, 0x7E]
    case NSF7FunctionKey: return [0x1B, 0x5B, 0x31, 0x38, 0x7E]
    case NSF8FunctionKey: return [0x1B, 0x5B, 0x31, 0x39, 0x7E]
    case NSF9FunctionKey: return [0x1B, 0x5B, 0x32, 0x30, 0x7E]
    case NSF10FunctionKey: return [0x1B, 0x5B, 0x32, 0x31, 0x7E]
    case NSF11FunctionKey: return [0x1B, 0x5B, 0x32, 0x33, 0x7E]
    case NSF12FunctionKey: return [0x1B, 0x5B, 0x32, 0x34, 0x7E]
    default: return nil
    }
  }

  private static func singleScalar(in text: String?) -> UnicodeScalar? {
    guard let text, text.unicodeScalars.count == 1 else { return nil }
    return text.unicodeScalars.first
  }
}
