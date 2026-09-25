import Foundation
import LabanTerminalCore

/// Sends the capability probes programs actually use to a throwaway terminal
/// session (no PTY, no child process) and checks each reply against its
/// documented form. This proves what Laban answers on this machine, with this
/// build, rather than what it is supposed to answer.
///
/// The session is created like any other, so process-wide settings apply:
/// with Kitty graphics disabled the graphics probe reports `.disabled`.
public enum TerminalCapabilitySelfTest {
  public enum Status: String, Sendable, Equatable {
    case passed
    case failed
    /// The capability is switched off by a setting; no reply is correct.
    case disabled
  }

  public struct Result: Sendable, Equatable {
    public let name: String
    /// What a program learns from this probe.
    public let purpose: String
    public let status: Status
    /// The reply with control characters spelled out (`ESC`, `BEL`), or "no
    /// reply".
    public let reply: String
  }

  struct Probe {
    let name: String
    let purpose: String
    let query: String
    /// Returns whether the reply is well formed.
    let accepts: (String) -> Bool
    /// When non-nil and false, the capability is disabled and silence is the
    /// correct answer.
    var enabled: Bool? = nil
  }

  static func probes(kittyGraphicsEnabled: Bool) -> [Probe] {
    [
      Probe(
        name: "Primary device attributes (DA1)",
        purpose: "Programs detect a VT-compatible terminal and wait on this reply.",
        query: "\u{1b}[c",
        accepts: { $0.hasPrefix("\u{1b}[?") && $0.hasSuffix("c") }),
      Probe(
        name: "Terminal name and version (XTVERSION)",
        purpose: "Programs identify the terminal without trusting TERM_PROGRAM.",
        query: "\u{1b}[>q",
        accepts: { $0.hasPrefix("\u{1b}P>|") && $0.hasSuffix("\u{1b}\\") }),
      Probe(
        name: "Cursor position, DEC form (DECXCPR)",
        purpose: "Unambiguous cursor reports that cannot be mistaken for key input.",
        query: "\u{1b}[?6n",
        accepts: { $0 == "\u{1b}[?1;1R" }),
      Probe(
        name: "Kitty keyboard protocol",
        purpose: "Editors and TUIs enable unambiguous key reporting.",
        query: "\u{1b}[?u",
        accepts: { $0.hasPrefix("\u{1b}[?") && $0.hasSuffix("u") }),
      Probe(
        name: "Background color (OSC 11)",
        purpose: "Programs match their theme to the terminal.",
        query: "\u{1b}]11;?\u{1b}\\",
        accepts: { $0.hasPrefix("\u{1b}]11;rgb:") }),
      Probe(
        name: "Palette color (OSC 4)",
        purpose: "Multiplexers such as herdr adapt to the host palette.",
        query: "\u{1b}]4;1;?\u{1b}\\",
        accepts: { $0.hasPrefix("\u{1b}]4;1;rgb:") }),
      Probe(
        name: "Light/dark color scheme",
        purpose: "Programs follow the system appearance live.",
        query: "\u{1b}[?996n",
        accepts: { $0 == "\u{1b}[?997;1n" || $0 == "\u{1b}[?997;2n" }),
      Probe(
        name: "Synchronized output (mode 2026)",
        purpose: "Programs draw whole frames without tearing.",
        query: "\u{1b}[?2026$p",
        accepts: { $0 == "\u{1b}[?2026;1$y" || $0 == "\u{1b}[?2026;2$y" }),
      Probe(
        name: "Bracketed paste (mode 2004)",
        purpose: "Shells tell pasted text from typed commands.",
        query: "\u{1b}[?2004$p",
        accepts: { $0 == "\u{1b}[?2004;1$y" || $0 == "\u{1b}[?2004;2$y" }),
      Probe(
        name: "Kitty graphics",
        purpose: "Programs show inline images instead of text art.",
        query: "\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\",
        accepts: { $0 == "\u{1b}_Gi=31;OK\u{1b}\\" },
        enabled: kittyGraphicsEnabled),
    ]
  }

  /// Runs every probe in a fresh session. Returns nil only when the session
  /// cannot be created.
  public static func run() -> [Result]? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    size.cell_width = 8
    size.cell_height = 16
    var created: OpaquePointer?
    guard laban_session_create(&config, size, &created) == 0, let session = created else {
      return nil
    }
    defer { laban_session_destroy(session) }

    return probes(kittyGraphicsEnabled: laban_kitty_graphics_enabled()).map { probe in
      _ = drain(session)
      write(session, probe.query)
      let reply = drain(session)
      let status: Status
      if probe.enabled == false {
        status = reply.isEmpty ? .disabled : .failed
      } else {
        status = !reply.isEmpty && probe.accepts(reply) ? .passed : .failed
      }
      return Result(
        name: probe.name, purpose: probe.purpose, status: status,
        reply: reply.isEmpty ? "no reply" : visible(reply))
    }
  }

  /// Spells out control characters so a reply reads in a label.
  public static func visible(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x1B: out += "ESC "
      case 0x07: out += " BEL"
      case 0..<0x20, 0x7F: out += String(format: "^%02X", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out.replacingOccurrences(of: "ESC \\", with: " ESC \\")
  }

  private static func write(_ session: OpaquePointer, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { buffer in
      _ = laban_session_write(
        session, buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  private static func drain(_ session: OpaquePointer) -> String {
    var buffer = [UInt8](repeating: 0, count: 1024)
    var length: size_t = 0
    guard laban_session_drain_response(session, &buffer, buffer.count, &length) == 0 else {
      return ""
    }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }
}
