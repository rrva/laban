import Darwin
import Foundation
import LabanCore

// labpty-dump: connect to a running labpty daemon, list its sessions, and
// stream a chosen session's byte-ring output to stdout. Designed as a
// passive observer for debugging — does not write to the PTY, does not
// disturb other clients. Two output formats:
//
//   --format hex    (default) — line-buffered hex+ASCII chunks with
//                                relative timestamps, one block per
//                                ring poll that returned bytes.
//   --format raw    — raw bytes only, suitable for `> capture.bin`
//                      then replaying via `laban_session_replay_pty_output`.

struct Args {
  var socketPath: String =
    NSString(string: "~/Library/Application Support/Laban/labpty/labpty.sock")
      .expandingTildeInPath
  var sessionId: String?
  var format: String = "hex"
  var listOnly = false
  var pollMs: Int = 4
  var fromStart = false
}

func usage() -> Never {
  FileHandle.standardError.write(Data("""
  labpty-dump — passive labpty byte-ring observer

  USAGE:
    labpty-dump [--socket PATH] --list
    labpty-dump [--socket PATH] --session ID [--format hex|raw] [--poll-ms N]

  OPTIONS:
    --socket PATH        labpty unix socket (default: ~/Library/Application Support/Laban/labpty/labpty.sock)
    --list               list sessions and exit
    --session ID         logical session id (UUID) to attach to
    --format hex|raw     output format (default: hex)
    --poll-ms N          ring poll interval (default: 4)

  """.utf8))
  exit(2)
}

func parseArgs() -> Args {
  var args = Args()
  var it = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = it.next() {
    switch arg {
    case "--socket":
      guard let v = it.next() else { usage() }
      args.socketPath = v
    case "--session":
      guard let v = it.next() else { usage() }
      args.sessionId = v
    case "--format":
      guard let v = it.next() else { usage() }
      args.format = v
    case "--poll-ms":
      guard let v = it.next(), let n = Int(v) else { usage() }
      args.pollMs = max(1, n)
    case "--list":
      args.listOnly = true
    case "--from-start":
      args.fromStart = true
    case "-h", "--help":
      usage()
    default:
      FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
      usage()
    }
  }
  return args
}

let args = parseArgs()

let client: LabptyTerminalSessionClient
do {
  client = try LabptyTerminalSessionClient(socketPath: args.socketPath)
} catch {
  FileHandle.standardError.write(Data("connect \(args.socketPath): \(error)\n".utf8))
  exit(1)
}

do {
  _ = try client.hello()
} catch {
  FileHandle.standardError.write(Data("hello: \(error)\n".utf8))
  exit(1)
}

let sessions: [LabptySessionDescriptor]
do {
  sessions = try client.listLabptySessions()
} catch {
  FileHandle.standardError.write(Data("listSessions: \(error)\n".utf8))
  exit(1)
}

if args.listOnly || args.sessionId == nil {
  for s in sessions {
    let alive = s.alive ? "alive" : "dead"
    print(
      "\(s.logicalSessionId)  pid=\(s.childPid)  \(s.rows)x\(s.cols)  \(alive)  ring=\(s.byteRingShmPath)"
    )
  }
  if args.sessionId == nil && !args.listOnly {
    FileHandle.standardError.write(Data("(pass --session ID to attach)\n".utf8))
  }
  exit(0)
}

guard let target = sessions.first(where: { $0.logicalSessionId == args.sessionId }) else {
  FileHandle.standardError.write(Data("session \(args.sessionId!) not found\n".utf8))
  exit(1)
}

let reader: LabptyByteRingReader
do {
  reader = try LabptyByteRingReader(path: target.byteRingShmPath)
} catch {
  FileHandle.standardError.write(Data("open ring \(target.byteRingShmPath): \(error)\n".utf8))
  exit(1)
}

// Default: start from the live tail (debug tap, not replay).
// With --from-start, attempt to read from offset 0 — the ring is
// capped, so this returns the oldest bytes still held plus an
// "overflowed" marker if the session is older than the ring.
var lastOffset: UInt64 = args.fromStart ? 0 : reader.outputWriteOffset()
let started = Date()

func ts() -> String {
  let elapsed = Date().timeIntervalSince(started)
  return String(format: "%8.3f", elapsed)
}

func hexDump(_ data: Data, prefix: String) {
  // Annotate ESC sequences inline. Print 32 bytes per row with hex on
  // the left and a quoted ASCII rendering on the right. Non-printable
  // bytes shown as . (dot) in the ASCII column; ESC shown as ⎋ in the
  // annotated representation below the row.
  let bytes = [UInt8](data)
  var line = prefix
  var ascii = ""
  for (idx, b) in bytes.enumerated() {
    if idx > 0 && idx % 32 == 0 {
      line += "  \(ascii)"
      print(line)
      line = String(repeating: " ", count: prefix.count)
      ascii = ""
    }
    line += String(format: "%02x ", b)
    if b == 0x1B {
      ascii += "⎋"
    } else if b == 0x0A {
      ascii += "␤"
    } else if b == 0x0D {
      ascii += "␍"
    } else if b >= 0x20 && b < 0x7F {
      ascii += String(UnicodeScalar(b))
    } else {
      ascii += "."
    }
  }
  if !line.isEmpty {
    let used = bytes.count % 32
    if used != 0 {
      line += String(repeating: "   ", count: 32 - used)
    }
    line += "  \(ascii)"
    print(line)
  }
}

func annotate(_ data: Data) {
  // Walk the data and emit one-line annotations for ANSI/CSI/OSC/paste
  // markers — these are the bytes the eye wants to find first.
  let bytes = [UInt8](data)
  var i = 0
  while i < bytes.count {
    if bytes[i] == 0x1B && i + 1 < bytes.count {
      let next = bytes[i + 1]
      var end = i + 2
      var label = "ESC \(Character(UnicodeScalar(next)))"
      if next == UInt8(ascii: "[") {
        // CSI: parameters then a final byte in 0x40..0x7E.
        var j = i + 2
        while j < bytes.count && bytes[j] < 0x40 {
          j += 1
        }
        if j < bytes.count {
          let final = Character(UnicodeScalar(bytes[j]))
          let params = String(
            data: Data(bytes[(i + 2)..<j]),
            encoding: .ascii) ?? "?"
          label = "CSI \(params)\(final)"
          if params == "200~" {
            label += "  ← bracketed-paste START"
          } else if params == "201~" {
            label += "  ← bracketed-paste END"
          } else if params == "?2004h" {
            label += "  ← enable bracketed paste"
          } else if params == "?2004l" {
            label += "  ← disable bracketed paste"
          }
          end = j + 1
        }
      } else if next == UInt8(ascii: "]") {
        // OSC: terminated by BEL or ST.
        var j = i + 2
        while j < bytes.count && bytes[j] != 0x07 {
          if bytes[j] == 0x1B && j + 1 < bytes.count && bytes[j + 1] == UInt8(ascii: "\\") {
            j += 1
            break
          }
          j += 1
        }
        let body = String(
          data: Data(bytes[(i + 2)..<min(j, bytes.count)]),
          encoding: .ascii) ?? "?"
        label = "OSC \(body)"
        end = j + 1
      }
      print("    \(label)")
      i = end
    } else {
      i += 1
    }
  }
}

FileHandle.standardError.write(Data(
  "attached  session=\(target.logicalSessionId)  pid=\(target.childPid)  size=\(target.rows)x\(target.cols)  starting at offset \(lastOffset)\n".utf8))

let pollNs = UInt32(args.pollMs * 1_000_000)
while true {
  let result = reader.readSince(lastOffset)
  if !result.bytes.isEmpty {
    if args.format == "raw" {
      FileHandle.standardOutput.write(result.bytes)
    } else {
      let prefix = "[\(ts())] +\(result.bytes.count)B "
      hexDump(result.bytes, prefix: prefix)
      annotate(result.bytes)
      if result.overflowed {
        print("    ⚠ RING OVERFLOWED")
      }
      // Flush per block: SIGTERM / a killed downstream reader would
      // otherwise leave bytes stuck in stdio buffers, which is exactly
      // the failure mode that just truncated a paste-rendering capture.
      fflush(stdout)
    }
  }
  lastOffset = result.newOffset
  usleep(pollNs)
}
