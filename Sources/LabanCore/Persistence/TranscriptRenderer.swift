import Foundation
import LabanTerminalCore

/// Restores a tab's scrollback from its persisted `<tab-id>.bin`
/// transcript. The render strategy is hybrid:
///   - The last ~1 MB of bytes are byte-replayed through libghostty-vt
///     so color, styling, and cursor position match what the user saw
///     before quit.
///   - Everything older is stripped of escape sequences and fed as
///     plain text so libghostty scrolls the lines into scrollback.
///   - If `altBufferAtQuit` is true, both passes are skipped: the tab
///     comes back as an empty terminal so we never paint half-finished
///     vim/htop/less state.
///
/// To avoid landing the byte-replay cutoff in the middle of an escape
/// sequence (which would produce garbage in the first replayed frame),
/// the renderer walks forward from the nominal `file_size - 1 MB`
/// offset to the next ASCII LF (0x0A). The byte-replay window starts
/// at the byte *after* that LF — LFs cannot appear inside VT escape
/// sequences and always mark a UTF-8-aligned position.
public enum TranscriptRenderer {

  public static let byteReplayWindow: Int = 1 * 1024 * 1024

  /// Render the persisted transcript into the given Session.
  ///
  /// - Parameters:
  ///   - fileURL: path to the `<tab-id>.bin` file. Missing or empty
  ///     files are no-ops.
  ///   - session: the deferred-spawn Session whose VT parser will
  ///     receive replayed bytes. Calling this before
  ///     `Session.start()` ensures replayed scrollback lands before
  ///     any live shell output.
  ///   - altBufferAtQuit: true when the tab was in alternate-screen
  ///     mode at quit. When true, no replay happens.
  public static func render(
    fileURL: URL,
    into session: Session,
    altBufferAtQuit: Bool
  ) {
    guard !altBufferAtQuit else { return }
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else { return }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      return
    }
    guard !data.isEmpty else { return }

    // Small file: byte-replay the whole thing. The text-strip
    // alternative mangles in-band PTY edits (backspace, CR, OSC
    // title) that libghostty's parser would otherwise handle
    // correctly. For a 518-byte transcript captured from a single
    // `echo hej` command, the on-wire bytes contain
    // `e \b echo hej` (zsh's predictive completion typed `e`,
    // backspaced, then wrote the full word). The stripper kept
    // both `e`s and dropped the `\b`, so the replay rendered as
    // `eecho hej`. Skipping the strip path entirely fixes this.
    if data.count <= byteReplayWindow {
      replayWithCleanHandoff(data: data, into: session)
      return
    }

    // Large file: drop the older head to bound replay cost. The
    // dropped prefix is NOT text-replayed because text-stripping
    // produces visible artefacts (see the small-file branch above);
    // for now the older-than-1MB portion is silently discarded. A
    // future revision can restore approximate-scrollback by using
    // a stripper that respects backspace and cursor moves.
    let nominal = data.count - byteReplayWindow
    let replayStart = safeReplayStart(in: data, nominal: nominal) ?? data.count
    let suffix: Data
    if replayStart < data.count {
      suffix = data.subdata(in: replayStart..<data.count)
    } else {
      suffix = Data()
    }
    if !suffix.isEmpty {
      replayWithCleanHandoff(data: suffix, into: session)
    }
  }

  /// Feed transcript bytes into libghostty without capturing them.
  /// The replacement shell's startup output is suppressed at the PTY
  /// boundary until first input, so the replayed cursor position is
  /// the position user input should continue from.
  private static func replayWithCleanHandoff(data: Data, into session: Session) {
    _ = session.replayPtyOutput([UInt8](data))
  }

  /// Walks forward from `nominal` to the first ASCII LF. Returns the
  /// byte index *after* that LF — that's the safe replay-start
  /// position. Returns `nil` when no LF exists between `nominal` and
  /// EOF (degenerate case; the caller text-strips the whole file).
  static func safeReplayStart(in data: Data, nominal: Int) -> Int? {
    guard nominal < data.count else { return nil }
    var idx = nominal
    while idx < data.count {
      if data[idx] == 0x0A {
        return idx + 1
      }
      idx += 1
    }
    return nil
  }
}

/// Small ANSI/VT escape stripper. Not intended to be perfect — it
/// handles the common cases that produce visible scrollback so older
/// transcript bytes can be fed back as plain text. CSI introducers
/// (`ESC [`), OSC introducers (`ESC ]`), SS2/SS3, and simple control
/// bytes outside `\t \n \r` are dropped. Bytes that survive stripping
/// are valid UTF-8 text plus newlines.
enum AnsiEscapeStripper {

  static func strip(_ input: Data) -> Data {
    var output = Data()
    output.reserveCapacity(input.count)
    var i = 0
    let bytes = [UInt8](input)
    while i < bytes.count {
      let b = bytes[i]
      switch b {
      case 0x1B:  // ESC
        i = skipEscape(bytes, from: i)
        continue
      case 0x07, 0x08, 0x0B, 0x0C, 0x0E, 0x0F:
        i += 1
        continue
      case 0x00...0x06, 0x10...0x1A, 0x1C...0x1F:
        // Drop most control bytes; keep \t (0x09), \n (0x0A), \r (0x0D).
        i += 1
        continue
      default:
        output.append(b)
        i += 1
      }
    }
    return output
  }

  private static func skipEscape(_ bytes: [UInt8], from start: Int) -> Int {
    // `bytes[start] == 0x1B`. Decide on the introducer.
    let next = start + 1
    guard next < bytes.count else { return next }
    let intro = bytes[next]
    switch intro {
    case 0x5B:  // CSI: ESC [ ... final-byte (0x40..0x7E)
      var j = next + 1
      while j < bytes.count {
        let c = bytes[j]
        if c >= 0x40 && c <= 0x7E { return j + 1 }
        j += 1
      }
      return j
    case 0x5D:  // OSC: ESC ] ... terminator (BEL 0x07 or ST = ESC \\ )
      var j = next + 1
      while j < bytes.count {
        let c = bytes[j]
        if c == 0x07 { return j + 1 }
        if c == 0x1B, j + 1 < bytes.count, bytes[j + 1] == 0x5C { return j + 2 }
        j += 1
      }
      return j
    case 0x4E, 0x4F:  // SS2 / SS3: ESC N / ESC O — single following byte
      return next + 2
    case 0x50, 0x58, 0x5E, 0x5F:
      // DCS / SOS / PM / APC — terminated by ST (ESC \\) or BEL
      var j = next + 1
      while j < bytes.count {
        let c = bytes[j]
        if c == 0x07 { return j + 1 }
        if c == 0x1B, j + 1 < bytes.count, bytes[j + 1] == 0x5C { return j + 2 }
        j += 1
      }
      return j
    default:
      // Two-byte ESC sequence (e.g., ESC = , ESC > , ESC c , etc.)
      return next + 1
    }
  }
}
