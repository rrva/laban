import AppKit
import LabanCore

/// The pasteboard representations offered to a program in a Kitty paste event
/// (ADR 0040). The program reads the ones it wants with an OSC 5522 read that
/// the session serves from this snapshot, so it is taken once, on the main
/// thread, at the user's ⌘V.
enum PasteEventClipboard {
  /// Matches the C snapshot cap (`LABAN_PASTE_SNAPSHOT_MAX_BYTES`).
  static let maxTotalBytes = 64 * 1024 * 1024

  static func items(from pasteboard: NSPasteboard) -> [Session.PasteEventItem] {
    var items: [Session.PasteEventItem] = []
    if let png = pngData(pasteboard) {
      items.append(Session.PasteEventItem(mime: "image/png", data: png))
    }
    if case .value(let text, _) = TerminalClipboard.readString(pasteboard) {
      items += self.items(text: text)
    }
    return capped(items)
  }

  /// Text goes through the same sanitize as every other user paste entry
  /// point (ADR 0020): the program may echo it back to the terminal.
  static func items(text: String) -> [Session.PasteEventItem] {
    let sanitized = TerminalClipboard.sanitizePaste(text)
    return sanitized.isEmpty
      ? [] : [Session.PasteEventItem(mime: "text/plain", data: Data(sanitized.utf8))]
  }

  /// Drops representations past the total cap, keeping the earlier (preferred) ones.
  static func capped(_ items: [Session.PasteEventItem]) -> [Session.PasteEventItem] {
    var total = 0
    return items.filter { item in
      guard item.data.count <= maxTotalBytes - total else { return false }
      total += item.data.count
      return true
    }
  }

  /// The clipboard image as PNG: the PNG representation when one exists,
  /// otherwise a conversion of the TIFF representation macOS screenshots use.
  static func pngData(_ pasteboard: NSPasteboard) -> Data? {
    if let png = pasteboard.data(forType: .png), !png.isEmpty { return png }
    guard TerminalClipboard.containsImage(pasteboard),
      let tiff = pasteboard.data(forType: .tiff),
      let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}
