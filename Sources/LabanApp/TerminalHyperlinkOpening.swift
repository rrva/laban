import AppKit
import Foundation

protocol ExternalURLOpening {
  @discardableResult
  func open(_ url: URL) -> Bool
}

extension NSWorkspace: ExternalURLOpening {}

enum TerminalHoverCursorStyle: Equatable {
  case arrow
  case pointingHand
}

enum TerminalHyperlinkOpening {
  static func browserURL(from uri: String) -> URL? {
    guard let url = URL(string: uri),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host,
      !host.isEmpty
    else {
      return nil
    }
    return url
  }

  @discardableResult
  static func open(
    _ uri: String,
    using opener: any ExternalURLOpening
  ) -> Bool {
    guard let url = browserURL(from: uri) else { return false }
    return opener.open(url)
  }

  static func shouldActivate(
    clickCount: Int,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    clickCount == 1 && modifierFlags.contains(.command)
  }

  static func hoverCursorStyle(
    externalHyperlinkURI uri: String?,
    modifierFlags: NSEvent.ModifierFlags = []
  ) -> TerminalHoverCursorStyle {
    uri != nil && modifierFlags.contains(.command) ? .pointingHand : .arrow
  }
}
