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

    // Fast path: sanitizing an already-clean string is the common case (the
    // resolver re-sanitizes stored, already-sanitized fields every frame).
    // Verify cleanliness in one allocation-free scan and hand back the
    // original — no scalar buffer, no second String.
    if isAlreadySanitized(raw, maxScalars: maxScalars) { return raw }

    // Build into a scalar buffer in one pass: per-scalar growth of a `String`
    // bridges/retains on every append, and `scalar.properties.isWhitespace`
    // hits the Unicode property database for every scalar. Titles are almost
    // entirely ASCII, so fast-path that and consult Unicode only for the rest.
    var scalars: [Unicode.Scalar] = []
    scalars.reserveCapacity(raw.unicodeScalars.count)
    var lastWasSpace = false
    for scalar in raw.unicodeScalars {
      let v = scalar.value
      if v == 0x09 || v == 0x0A || v == 0x0D {
        if !lastWasSpace {
          scalars.append(" ")
          lastWasSpace = true
        }
      } else if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
        // remove other control characters
      } else {
        scalars.append(scalar)
        // Among scalars reaching this branch the only ASCII whitespace is
        // U+0020; everything else ASCII is non-whitespace, so skip the
        // property lookup for the common case.
        lastWasSpace = v < 0x80 ? (v == 0x20) : scalar.properties.isWhitespace
      }
    }

    // Trim leading/trailing whitespace. Control chars are already gone and
    // tab/LF/CR are collapsed to U+0020, so the remaining whitespace is
    // U+0020 plus non-ASCII Unicode whitespace — the White_Space property
    // matches CharacterSet.whitespacesAndNewlines on this content.
    var lo = 0
    var hi = scalars.count
    while lo < hi, isTrimmableWhitespace(scalars[lo]) { lo += 1 }
    while hi > lo, isTrimmableWhitespace(scalars[hi - 1]) { hi -= 1 }
    if lo >= hi { return nil }

    // Cap after trimming (matches the previous trim-then-prefix order), so a
    // single buffer build replaces the former second `prefixScalars` pass.
    let count = min(hi - lo, maxScalars)
    var view = String.UnicodeScalarView()
    view.reserveCapacity(count)
    view.append(contentsOf: scalars[lo..<(lo + count)])
    return String(view)
  }

  private static func isTrimmableWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    let v = scalar.value
    if v < 0x80 { return v == 0x20 }
    return scalar.properties.isWhitespace
  }

  /// True when `sanitize` would return `value` unchanged: no characters to
  /// collapse or remove, no leading/trailing whitespace to trim, and within
  /// the scalar cap. Single pass, no allocation.
  private static func isAlreadySanitized(_ value: String, maxScalars: Int) -> Bool {
    var count = 0
    var first: Unicode.Scalar?
    var last: Unicode.Scalar = " "
    for scalar in value.unicodeScalars {
      let v = scalar.value
      // tab/LF/CR collapse to a space; other C0/C1/DEL get removed — either
      // way the result would differ from the input.
      if v == 0x09 || v == 0x0A || v == 0x0D { return false }
      if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) { return false }
      if first == nil { first = scalar }
      last = scalar
      count += 1
      if count > maxScalars { return false }
    }
    guard let firstScalar = first else { return false }
    return !isTrimmableWhitespace(firstScalar) && !isTrimmableWhitespace(last)
  }

  static func prefixScalars(_ value: String, maxScalars: Int) -> String {
    guard maxScalars >= 0 else { return "" }
    let scalars = value.unicodeScalars
    guard scalars.count > maxScalars else { return value }
    var view = String.UnicodeScalarView()
    view.reserveCapacity(maxScalars)
    view.append(contentsOf: scalars.prefix(maxScalars))
    return String(view)
  }

  static func scalarCount(_ value: String) -> Int {
    value.unicodeScalars.count
  }
}
