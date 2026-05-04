enum TerminalTitle {
  static let maxLength = 256

  /// Sanitize a raw terminal title string for storage in AppModel.
  /// - Replaces tab, LF, and CR with a single space.
  /// - Removes C0/C1 control characters and DEL.
  /// - Trims leading and trailing whitespace.
  /// - Caps the result to maxLength Unicode scalars.
  /// - Returns nil if the sanitized result is empty.
  static func sanitize(_ raw: String?, maxScalars: Int = maxLength) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    guard maxScalars > 0 else { return nil }
    var result = ""
    result.reserveCapacity(min(raw.count, maxScalars))
    var lastWasSpace = false
    for scalar in raw.unicodeScalars {
      let v = scalar.value
      if v == 0x09 || v == 0x0A || v == 0x0D {
        if !lastWasSpace {
          result.append(" ")
          lastWasSpace = true
        }
      } else if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
        // remove other control characters
      } else {
        result.unicodeScalars.append(scalar)
        lastWasSpace = scalar.properties.isWhitespace
      }
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.isEmpty { return nil }
    result = prefixScalars(result, maxScalars: maxScalars)
    return result
  }

  static func prefixScalars(_ value: String, maxScalars: Int) -> String {
    guard maxScalars >= 0 else { return "" }
    var result = ""
    result.reserveCapacity(min(value.count, maxScalars))
    var count = 0
    for scalar in value.unicodeScalars {
      guard count < maxScalars else { break }
      result.unicodeScalars.append(scalar)
      count += 1
    }
    return result
  }

  static func scalarCount(_ value: String) -> Int {
    value.unicodeScalars.count
  }
}
