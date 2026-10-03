import Foundation

/// Unicode BiDi mirroring for paired punctuation: in a right-to-left run an
/// opening bracket is drawn as its closing counterpart and vice versa, so
/// `שלום (עולם)` reads correctly once the run is mirrored. The mapping is
/// its own inverse.
public enum BidiMirroring {
  private static let pairs: [UInt32: UInt32] = {
    let list: [(UInt32, UInt32)] = [
      (0x0028, 0x0029), (0x003C, 0x003E), (0x005B, 0x005D), (0x007B, 0x007D),
      (0x00AB, 0x00BB), (0x2039, 0x203A), (0x2045, 0x2046), (0x207D, 0x207E),
      (0x208D, 0x208E), (0x2264, 0x2265), (0x2329, 0x232A), (0x27E6, 0x27E7),
      (0x27E8, 0x27E9), (0x27EA, 0x27EB), (0x2983, 0x2984), (0x2985, 0x2986),
      (0x3008, 0x3009), (0x300A, 0x300B), (0x300C, 0x300D), (0x300E, 0x300F),
      (0x3010, 0x3011), (0xFF08, 0xFF09), (0xFF1C, 0xFF1E), (0xFF3B, 0xFF3D),
      (0xFF5B, 0xFF5D),
    ]
    var map: [UInt32: UInt32] = [:]
    for (open, close) in list {
      map[open] = close
      map[close] = open
    }
    return map
  }()

  public static func mirrored(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: { pairs[$0.value] != nil }) else { return text }
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      scalars.append(pairs[scalar.value].flatMap(Unicode.Scalar.init) ?? scalar)
    }
    return String(scalars)
  }
}
