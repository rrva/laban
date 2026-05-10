import AppKit
import Foundation
import LabanCore

enum TerminalClipboard {
  enum StringRead: Equatable {
    case empty
    case tooLarge(Int)
    case value(String, bytes: Int)
  }

  static let hardLimitBytes = TerminalPaste.hardLimitBytes
  static let warnLimitBytes = TerminalPaste.warnLimitBytes

  static func readString(_ pasteboard: NSPasteboard) -> StringRead {
    if let data = pasteboard.data(forType: .string), data.count > hardLimitBytes {
      return .tooLarge(data.count)
    }
    guard let raw = pasteboard.string(forType: .string), !raw.isEmpty else {
      return .empty
    }
    let bytes = raw.utf8.count
    if bytes > hardLimitBytes {
      return .tooLarge(bytes)
    }
    return .value(raw, bytes: bytes)
  }

  static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
  }

  static func shouldForwardImagePasteToTerminal(for tab: Tab) -> Bool {
    let metadata = tab.titleMetadata
    if executableLooksLikeClaude(metadata.process.foregroundProcess) {
      return true
    }
    if executableLooksLikeClaude(metadata.process.foregroundCommand) {
      return true
    }

    let titles = [
      metadata.terminalTitle,
      metadata.displayTitle,
      metadata.userTitle,
      metadata.agent.agentName,
      metadata.agent.sessionName,
    ]
    return titles.contains { value in
      value?.range(of: "Claude Code", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  static func sanitizePaste(_ text: String) -> String {
    TerminalPaste.sanitize(text)
  }

  private static func executableLooksLikeClaude(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let token = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
    let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    let basename = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
    return basename == "claude" || basename == "claude-code"
  }
}
