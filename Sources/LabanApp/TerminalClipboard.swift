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

  /// Apply an OSC 52 clipboard *write* — `ESC ] 52 ; c ; <base64> ST`, already
  /// base64-decoded by the Session bridge — to the pasteboard. OSC 52 payloads
  /// are conventionally UTF-8 text, so decode lossily: a copy from a remote
  /// program (over SSH, where its native clipboard is unreachable) should
  /// always land something usable. Returns the string written.
  @discardableResult
  static func writeOSC52(_ data: Data, to pasteboard: NSPasteboard) -> String {
    let text = String(decoding: data, as: UTF8.self)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return text
  }

  /// Current pasteboard contents as bytes for an OSC 52 *read* reply, honoring
  /// the paste size limit. Returns empty for an empty, oversized, or absent
  /// clipboard so the reply is always well-formed.
  static func osc52ReadData(_ pasteboard: NSPasteboard) -> Data {
    switch readString(pasteboard) {
    case .value(let string, _):
      return Data(string.utf8)
    case .empty, .tooLarge:
      return Data()
    }
  }

  static func shouldForwardImagePasteToTerminal(for tab: Tab) -> Bool {
    tabRunsClaudeCode(tab)
  }

  /// True when the tab's foreground process or title metadata identifies
  /// Claude Code. Claude Code never enables bracketed paste (its paste
  /// handling is a chunk-arrival heuristic that inserts pasted newlines
  /// into the prompt buffer instead of submitting), so callers use this
  /// both to forward image pastes and to skip the multi-line unsafe-paste
  /// warning that exists for raw shells.
  static func tabRunsClaudeCode(_ tab: Tab) -> Bool {
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
