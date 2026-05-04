enum TerminalTitle {
  static let maxLength = 80

  /// Sanitize a raw terminal title string for storage in AppModel.
  /// - Replaces tab, LF, and CR with a space.
  /// - Removes other ASCII control characters (< 0x20) and DEL (0x7F).
  /// - Trims leading and trailing whitespace.
  /// - Caps the result to maxLength Swift characters.
  /// - Returns nil if the sanitized result is empty.
  static func sanitize(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    var result = ""
    result.reserveCapacity(min(raw.count, maxLength))
    for scalar in raw.unicodeScalars {
      let v = scalar.value
      if v == 0x09 || v == 0x0A || v == 0x0D {
        result.append(" ")
      } else if v < 0x20 || v == 0x7F {
        // remove other ASCII control characters
      } else {
        result.append(Character(scalar))
      }
    }
    result = result.trimmingCharacters(in: .whitespaces)
    if result.isEmpty { return nil }
    if result.count > maxLength {
      result = String(result.prefix(maxLength))
    }
    return result
  }
}
