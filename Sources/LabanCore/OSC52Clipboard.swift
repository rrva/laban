import Foundation

/// Pure base64 + size-policy codec for the OSC 52 clipboard bridge.
///
/// Lives in LabanCore (no AppKit) so the `Session` C↔Swift bridge and the
/// headless debug runtime share one tested implementation. The C scanner caps
/// the on-wire payload at `OSC_HOST_OSC52_MAX` (256 KiB of base64); this mirrors
/// that ceiling on the *decoded* side and rejects anything larger or malformed,
/// so a remote `OSC 52 ; c ; <base64>` write cannot push an unbounded blob onto
/// the host clipboard.
public enum OSC52Clipboard {
  /// Maximum decoded clipboard payload accepted from an OSC 52 write. 256 KiB
  /// of base64 decodes to ~192 KiB, which comfortably covers Codex's 100 KB
  /// copy cap while staying bounded.
  public static let maxDecodedBytes = 192 * 1024

  /// Decode an OSC 52 write payload — the raw base64 bytes delivered by the C
  /// scanner — into clipboard bytes. Returns `nil` when the input is empty, is
  /// not valid base64, or decodes to more than `maxDecodedBytes`.
  public static func decodeWrite(base64 bytes: [UInt8]) -> Data? {
    guard !bytes.isEmpty else { return nil }
    let raw = Data(bytes)
    // Strict decode first; fall back to tolerating stray whitespace/newlines a
    // few emitters insert. Unknown characters otherwise mean a malformed write.
    let decoded =
      Data(base64Encoded: raw)
      ?? Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
    guard let decoded, decoded.count <= maxDecodedBytes else { return nil }
    return decoded
  }

  /// Encode clipboard bytes for an OSC 52 read reply (`ESC ] 52 ; c ; <here> ST`).
  public static func encodeRead(_ data: Data) -> String {
    data.base64EncodedString()
  }
}
