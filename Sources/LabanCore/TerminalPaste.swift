public enum TerminalPaste {
  /// Refuse pastes above this size. Bigger than this is almost certainly a
  /// clipboard mishap or hostile content.
  public static let hardLimitBytes = 10 * 1024 * 1024

  /// Warn-and-confirm above this size. Below it, no prompt.
  public static let warnLimitBytes = 64 * 1024

  public static func sanitize(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
      let v = scalar.value
      // Whitelist: HT, LF, CR. Drop every other C0 control, DEL, and C1
      // control scalar before handing bytes to libghostty's paste encoder.
      if v == 0x09 || v == 0x0A || v == 0x0D {
        out.append(scalar)
      } else if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
        continue
      } else {
        out.append(scalar)
      }
    }
    return String(out)
  }
}
