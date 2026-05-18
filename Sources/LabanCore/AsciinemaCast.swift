import Foundation

/// Emits an asciinema v2 cast file from a list of recorded byte
/// entries. The cast format is NDJSON: one header line followed by
/// one event line per recorded chunk. See
/// https://docs.asciinema.org/manual/asciicast/v2/ for the spec.
///
/// Event-time normalization: the first surviving entry becomes the
/// cast's t=0; later entries' times are deltas in seconds. The
/// header `timestamp` field carries the wall-clock seconds at the
/// moment of the first entry so a player can show when the
/// recording was made.
///
/// UTF-8 handling: PTY output is treated as a single byte stream
/// even though it arrives in chunks. A multi-byte UTF-8 sequence
/// that straddles a chunk boundary is decoded across boundaries so
/// the cast does not contain spurious U+FFFD replacement characters
/// at every prompt redraw with non-ASCII glyphs. Genuinely invalid
/// bytes are replaced with U+FFFD.
public enum AsciinemaCast {

  /// Encode the entries as a v2 cast and return the bytes ready to
  /// write to disk.
  ///
  /// - Parameters:
  ///   - entries: ordered chunks from `RecentByteRing.snapshot`.
  ///   - cols: terminal width in cells at export time.
  ///   - rows: terminal height in cells at export time.
  ///   - title: optional cast title (shown in player UI).
  ///   - startedAtUnixSeconds: wall-clock seconds for the cast
  ///     header. Convention: this is when the recording window
  ///     started, not when export was triggered, so the player's
  ///     "recorded at" string matches what the user saw.
  public static func encode(
    entries: [RecentByteRing.Entry],
    cols: Int,
    rows: Int,
    title: String? = nil,
    startedAtUnixSeconds: TimeInterval,
    env: [String: String] = AsciinemaCast.defaultEnv()
  ) throws -> Data {
    var output = Data()

    // Header line. Use sorted keys so the output is stable for
    // testing. The asciicast v2 spec says the header SHOULD carry
    // an `env` map containing at least TERM (and SHELL when known)
    // so players can pick the correct terminal-emulation model for
    // the recorded bytes — otherwise they guess.
    var header: [String: Any] = [
      "version": 2,
      "width": cols,
      "height": rows,
      "timestamp": Int(startedAtUnixSeconds),
    ]
    if let title, !title.isEmpty {
      header["title"] = title
    }
    if !env.isEmpty {
      header["env"] = env
    }
    let headerData = try JSONSerialization.data(
      withJSONObject: header,
      options: [.sortedKeys])
    output.append(headerData)
    output.append(0x0A)  // \n

    guard let first = entries.first else { return output }
    let baseNanos = first.timestampNanos

    var pendingTrailingBytes: [UInt8] = []
    for entry in entries {
      let delta = TimeInterval(entry.timestampNanos &- baseNanos) / 1_000_000_000.0

      // Prepend any incomplete UTF-8 bytes deferred from the
      // previous chunk so a multi-byte sequence that straddled a
      // boundary decodes cleanly.
      var combined = pendingTrailingBytes
      combined.append(contentsOf: entry.bytes)
      pendingTrailingBytes.removeAll(keepingCapacity: true)

      let (decoded, trailing) = AsciinemaCast.decodeWithTrailing(bytes: combined)
      pendingTrailingBytes = trailing

      if decoded.isEmpty { continue }

      // Each event line: [time, "o", "<string>"]. JSONSerialization
      // handles the string escaping (control chars, quotes,
      // backslashes, non-BMP) per JSON spec.
      let event: [Any] = [delta, "o", decoded]
      let eventData = try JSONSerialization.data(
        withJSONObject: event,
        options: [.fragmentsAllowed])
      output.append(eventData)
      output.append(0x0A)
    }

    // Anything still trailing at the end is genuinely incomplete —
    // emit as U+FFFD so it doesn't get silently lost.
    if !pendingTrailingBytes.isEmpty {
      let replacement = String(repeating: "\u{FFFD}", count: pendingTrailingBytes.count)
      let delta = TimeInterval(
        (entries.last?.timestampNanos ?? baseNanos) &- baseNanos
      ) / 1_000_000_000.0
      let event: [Any] = [delta, "o", replacement]
      let eventData = try JSONSerialization.data(
        withJSONObject: event,
        options: [.fragmentsAllowed])
      output.append(eventData)
      output.append(0x0A)
    }

    return output
  }

  /// Default `env` map for the v2 header. Carries the TERM that
  /// Laban advertises to every shell it spawns plus the user's
  /// login SHELL if `$SHELL` is set. Callers can override the whole
  /// map (e.g., tests) or merge in extra keys before encoding.
  public static func defaultEnv() -> [String: String] {
    var env: [String: String] = ["TERM": "xterm-256color"]
    if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
      env["SHELL"] = shell
    }
    return env
  }

  /// Decode a byte buffer as UTF-8. If the buffer ends mid-sequence,
  /// return the leading complete portion as a String and the trailing
  /// incomplete bytes for the caller to prepend to the next chunk.
  /// Invalid bytes inside the leading portion become U+FFFD.
  private static func decodeWithTrailing(bytes: [UInt8]) -> (String, [UInt8]) {
    if bytes.isEmpty { return ("", []) }
    // Walk backward from the end to find the start of the last
    // partial UTF-8 sequence (if any). A continuation byte is
    // 10xxxxxx (0x80..0xBF); a leading byte is anything else with
    // the high bit set or ASCII.
    var splitAt = bytes.count
    var lookback = 0
    while splitAt > 0 && lookback < 4 {
      let b = bytes[splitAt - 1]
      if b & 0x80 == 0 {
        // ASCII byte: complete on its own; nothing trailing.
        break
      }
      if b & 0xC0 == 0x80 {
        // Continuation byte; keep walking back.
        splitAt -= 1
        lookback += 1
        continue
      }
      // Leading byte. Determine expected length.
      let needed: Int
      if b & 0xE0 == 0xC0 { needed = 2 }
      else if b & 0xF0 == 0xE0 { needed = 3 }
      else if b & 0xF8 == 0xF0 { needed = 4 }
      else {
        // Invalid leading byte; treat as complete (will be replaced).
        break
      }
      let have = bytes.count - (splitAt - 1)
      if have < needed {
        splitAt -= 1
      }
      break
    }
    let leading = Array(bytes.prefix(splitAt))
    let trailing = Array(bytes.suffix(from: splitAt))
    let decoded = String(decoding: leading, as: UTF8.self)
    return (decoded, trailing)
  }
}
