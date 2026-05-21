import Foundation
import LabanTerminalCore

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

  /// Build ANSI bytes that repaint the full visible terminal grid
  /// from a `LabanSnapshot`. This is used as the first event in a
  /// bounded recent export so cursor-addressed deltas have a base
  /// screen to apply to, even when the terminal app did not redraw
  /// the whole screen during the exported window.
  public static func fullFrameSnapshotBytes(
    from snap: UnsafePointer<LabanSnapshot>
  ) -> [UInt8] {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard rows > 0, cols > 0 else { return [] }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(rows * cols * 2 + rows * 24 + 64)

    func append(_ string: String) {
      bytes.append(contentsOf: string.utf8)
    }

    append("\u{1B}[0m\u{1B}[?25l\u{1B}[H\u{1B}[2J")

    var currentStyle: SnapshotCellStyle? = nil
    if let cells = snapshot.cells {
      for row in 0..<rows {
        append("\u{1B}[\(row + 1);1H")
        let rowStart = row * cols
        for col in 0..<cols {
          let cell = cells[rowStart + col]
          if cell.wide == UInt8(LABAN_CELL_WIDE_SPACER_TAIL) {
            continue
          }

          let style = SnapshotCellStyle(cell: cell)
          if style != currentStyle {
            append(sgrSequence(for: style))
            currentStyle = style
          }
          append(snapshotCellText(cell, storage: snapshot.utf8_storage))
        }
      }
    }

    append("\u{1B}[0m")
    let cursorRow = min(max(Int(snapshot.cursor_row), 0), rows - 1) + 1
    let cursorCol = min(max(Int(snapshot.cursor_col), 0), cols - 1) + 1
    append("\u{1B}[\(cursorRow);\(cursorCol)H")
    append(snapshot.cursor_visible != 0 ? "\u{1B}[?25h" : "\u{1B}[?25l")

    return bytes
  }

  /// Reconstruct the visible terminal state produced by retained
  /// bytes before a bounded export window, then return ANSI bytes for
  /// that full frame. Returns an empty seed if replay cannot produce
  /// a snapshot.
  public static func fullFrameSnapshotBytes(
    replaying entries: [RecentByteRing.Entry],
    cols: Int,
    rows: Int
  ) -> [UInt8] {
    guard !entries.isEmpty else { return [] }
    var size = LabanTerminalSize()
    size.cols = Int32(max(cols, 1))
    size.rows = Int32(max(rows, 1))
    guard let session = try? Session.fixture(size: size) else { return [] }

    for entry in entries {
      guard session.replayPtyOutput(entry.bytes) == 0 else { return [] }
    }
    guard let snap = session.snapshot() else { return [] }
    defer { laban_snapshot_destroy(snap) }
    return fullFrameSnapshotBytes(from: UnsafePointer(snap))
  }

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
  ///   - initialFrameBytes: optional ANSI bytes emitted as the first
  ///     event at t=0 before recorded PTY output. Callers pass a
  ///     synthesized full-frame snapshot so a bounded export is
  ///     self-contained instead of depending on earlier terminal
  ///     output outside the window.
  ///   - timelineBaseNanos: optional monotonic timestamp used as the
  ///     t=0 base for recorded entries. Recent-window exports pass
  ///     the window cutoff when they also emit `initialFrameBytes` so
  ///     delayed deltas keep their position in the window.
  public static func encode(
    entries: [RecentByteRing.Entry],
    cols: Int,
    rows: Int,
    title: String? = nil,
    startedAtUnixSeconds: TimeInterval,
    env: [String: String] = AsciinemaCast.defaultEnv(),
    initialFrameBytes: [UInt8] = [],
    timelineBaseNanos: UInt64? = nil
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

    if !initialFrameBytes.isEmpty {
      try appendEvent(
        to: &output,
        delta: 0,
        payload: String(decoding: initialFrameBytes, as: UTF8.self)
      )
    }

    guard let first = entries.first else { return output }
    let baseNanos = timelineBaseNanos ?? first.timestampNanos

    var pendingTrailingBytes: [UInt8] = []
    for entry in entries {
      let delta = deltaSeconds(timestampNanos: entry.timestampNanos, baseNanos: baseNanos)

      // Prepend any incomplete UTF-8 bytes deferred from the
      // previous chunk so a multi-byte sequence that straddled a
      // boundary decodes cleanly.
      var combined = pendingTrailingBytes
      combined.append(contentsOf: entry.bytes)
      pendingTrailingBytes.removeAll(keepingCapacity: true)

      let (decoded, trailing) = AsciinemaCast.decodeWithTrailing(bytes: combined)
      pendingTrailingBytes = trailing

      if decoded.isEmpty { continue }

      try appendEvent(to: &output, delta: delta, payload: decoded)
    }

    // Anything still trailing at the end is genuinely incomplete —
    // emit as U+FFFD so it doesn't get silently lost.
    if !pendingTrailingBytes.isEmpty {
      let replacement = String(repeating: "\u{FFFD}", count: pendingTrailingBytes.count)
      let delta = deltaSeconds(
        timestampNanos: entries.last?.timestampNanos ?? baseNanos,
        baseNanos: baseNanos)
      try appendEvent(to: &output, delta: delta, payload: replacement)
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
      if b & 0xE0 == 0xC0 {
        needed = 2
      } else if b & 0xF0 == 0xE0 {
        needed = 3
      } else if b & 0xF8 == 0xF0 {
        needed = 4
      } else {
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

  private static func appendEvent(
    to output: inout Data,
    delta: TimeInterval,
    payload: String
  ) throws {
    // Each event line: [time, "o", "<string>"]. JSONSerialization
    // handles the string escaping (control chars, quotes,
    // backslashes, non-BMP) per JSON spec.
    let event: [Any] = [delta, "o", payload]
    let eventData = try JSONSerialization.data(
      withJSONObject: event,
      options: [.fragmentsAllowed])
    output.append(eventData)
    output.append(0x0A)
  }

  private static func deltaSeconds(timestampNanos: UInt64, baseNanos: UInt64) -> TimeInterval {
    guard timestampNanos >= baseNanos else { return 0 }
    return TimeInterval(timestampNanos - baseNanos) / 1_000_000_000.0
  }

  private struct SnapshotCellStyle: Equatable {
    var foreground: UInt32
    var background: UInt32
    var bold: Bool
    var italic: Bool
    var faint: Bool
    var underline: Bool
    var underlineStyle: UInt8
    var strikethrough: Bool
    var overline: Bool
    var blink: Bool

    init(cell: LabanCell) {
      foreground = cell.foreground_rgba
      background = cell.background_rgba
      bold = (cell.flags & UInt16(LABAN_CELL_FLAG_BOLD)) != 0
      italic = (cell.flags & UInt16(LABAN_CELL_FLAG_ITALIC)) != 0
      faint = (cell.flags & UInt16(LABAN_CELL_FLAG_FAINT)) != 0
      underline =
        (cell.flags & UInt16(LABAN_CELL_FLAG_UNDERLINE)) != 0
        || cell.underline_style != UInt8(LABAN_UNDERLINE_NONE)
      underlineStyle = cell.underline_style
      strikethrough = (cell.flags & UInt16(LABAN_CELL_FLAG_STRIKETHROUGH)) != 0
      overline = (cell.flags & UInt16(LABAN_CELL_FLAG_OVERLINE)) != 0
      blink = (cell.flags & UInt16(LABAN_CELL_FLAG_BLINK)) != 0
    }
  }

  private static func sgrSequence(for style: SnapshotCellStyle) -> String {
    let fg = rgbComponents(style.foreground)
    let bg = rgbComponents(style.background)
    var params = ["0"]
    if style.bold { params.append("1") }
    if style.faint { params.append("2") }
    if style.italic { params.append("3") }
    if style.underline {
      params.append(style.underlineStyle == UInt8(LABAN_UNDERLINE_DOUBLE) ? "21" : "4")
    }
    if style.blink { params.append("5") }
    if style.strikethrough { params.append("9") }
    if style.overline { params.append("53") }
    params.append("38;2;\(fg.red);\(fg.green);\(fg.blue)")
    params.append("48;2;\(bg.red);\(bg.green);\(bg.blue)")
    return "\u{1B}[\(params.joined(separator: ";"))m"
  }

  private static func snapshotCellText(
    _ cell: LabanCell,
    storage: UnsafePointer<CChar>?
  ) -> String {
    if (cell.flags & UInt16(LABAN_CELL_FLAG_INVISIBLE)) != 0 {
      return " "
    }
    guard cell.utf8_length > 0, let storage else { return " " }
    let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
    let buf = UnsafeBufferPointer<UInt8>(
      start: ptr.assumingMemoryBound(to: UInt8.self),
      count: Int(cell.utf8_length)
    )
    let text = String(bytes: buf, encoding: .utf8) ?? " "
    return text.isEmpty ? " " : text
  }

  private static func rgbComponents(_ rgba: UInt32) -> (red: UInt32, green: UInt32, blue: UInt32) {
    (
      red: (rgba >> 24) & 0xFF,
      green: (rgba >> 16) & 0xFF,
      blue: (rgba >> 8) & 0xFF
    )
  }
}
