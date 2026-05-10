import Foundation
import LabanCore

enum TerminalInputCaptureMetadata {
  static func encodedHex(_ bytes: [UInt8]) -> String? {
    guard !bytes.isEmpty else { return nil }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func encodedLength(_ bytes: [UInt8]) -> Int? {
    bytes.isEmpty ? nil : bytes.count
  }

  static func modifierNames(_ modifiers: KeyModifiers) -> [String]? {
    var names: [String] = []
    if modifiers.contains(.shift) { names.append("shift") }
    if modifiers.contains(.control) { names.append("control") }
    if modifiers.contains(.alt) { names.append("option") }
    if modifiers.contains(.command) { names.append("command") }
    if modifiers.contains(.capsLock) { names.append("capsLock") }
    return names.isEmpty ? nil : names
  }

  static func captureName(for command: AppCommand) -> String {
    switch command {
    case .newTab: return "newTab"
    case .closeTab: return "closeTab"
    case .selectTab: return "selectTab"
    case .copy: return "copy"
    case .paste: return "paste"
    }
  }
}
