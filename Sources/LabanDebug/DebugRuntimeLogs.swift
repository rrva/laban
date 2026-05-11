import Foundation
import LabanCore

struct EventEntry {
  var seq: Int = 0
  var kind: String
  var tabId: String?
  var sessionId: String?
  var frame: Int?
  var width: Int?
  var height: Int?
  var text: String?
  var path: String?
  var action: String?
  var deltaRows: Int?
  var error: String?
}

struct TerminalLogEntry {
  var seq: Int = 0
  var sessionId: String?
  var direction: String
  var escaped: String
  var frame: Int?
}

struct DebugErrorEntry {
  var seq: Int = 0
  var level: String
  var kind: String
  var message: String
  var sessionId: String?
  var tabId: String?
}

struct DebugTerminalByteCounts {
  var input: Int = 0
  var output: Int = 0
  var terminalResponse: Int = 0
}

struct DebugRuntimeLogStore {
  private var eventLog: [EventEntry] = []
  private var inputLog: [InputEventEnvelope] = []
  private var terminalLog: [TerminalLogEntry] = []
  private var errorLog: [DebugErrorEntry] = []

  private(set) var eventSeq: Int = 0
  private(set) var inputLogSeq: Int = 0
  private(set) var terminalLogSeq: Int = 0
  private(set) var errorSeq: Int = 0
  private(set) var terminalBytes = DebugTerminalByteCounts()

  mutating func appendEvent(_ entry: EventEntry) {
    var entry = entry
    entry.seq = eventSeq
    eventSeq += 1
    eventLog.append(entry)
    if eventLog.count > 2000 {
      eventLog.removeFirst(eventLog.count - 2000)
    }
  }

  mutating func appendInputEnvelope(_ envelope: InputEventEnvelope) -> InputEventEnvelope {
    var envelope = envelope
    envelope.seq = inputLogSeq
    inputLogSeq += 1
    inputLog.append(envelope)
    if inputLog.count > 512 {
      inputLog.removeFirst(inputLog.count - 512)
    }
    return envelope
  }

  mutating func appendTerminalLog(
    sessionId: String?,
    direction: String,
    bytes: [UInt8],
    frame: Int
  ) {
    guard !bytes.isEmpty else { return }
    switch direction {
    case "input":
      terminalBytes.input += bytes.count
    case "output":
      terminalBytes.output += bytes.count
    case "terminal-response", "terminalResponse":
      terminalBytes.terminalResponse += bytes.count
    default:
      break
    }
    appendTerminalLog(
      TerminalLogEntry(
        sessionId: sessionId,
        direction: direction,
        escaped: Self.escapedPreview(bytes),
        frame: frame
      ))
  }

  mutating func appendError(
    level: String = "error",
    kind: String,
    message: String,
    sessionId: String? = nil,
    tabId: String? = nil
  ) {
    var entry = DebugErrorEntry(
      level: level,
      kind: kind,
      message: message,
      sessionId: sessionId,
      tabId: tabId
    )
    entry.seq = errorSeq
    errorSeq += 1
    errorLog.append(entry)
    if errorLog.count > 512 {
      errorLog.removeFirst(errorLog.count - 512)
    }
  }

  func containsEvent(kind: String) -> Bool {
    eventLog.contains { $0.kind == kind }
  }

  func eventsResponse(since: Int) -> EventsResponse {
    EventsResponse(events: eventResponses(since: since), next: eventSeq)
  }

  func inputLogResponse(since: Int) -> InputLogResponse {
    InputLogResponse(events: inputLog.filter { $0.seq >= since }, next: inputLogSeq)
  }

  func errorsResponse(since: Int) -> DebugErrorsResponse {
    DebugErrorsResponse(
      errors: errorLog.filter { $0.seq >= since }.map { entry in
        DebugErrorEntryResponse(
          seq: entry.seq,
          level: entry.level,
          kind: entry.kind,
          message: entry.message,
          sessionId: entry.sessionId,
          tabId: entry.tabId
        )
      },
      next: errorSeq
    )
  }

  func terminalLogResponse(
    query: [String: String],
    defaultSessionId: String?
  ) -> TerminalLogResponse {
    let since = query["since"].flatMap { Int($0) } ?? 0
    let limit = min(query["limit"].flatMap { Int($0) } ?? 200, 1000)
    let requestedSessionId = query["sessionId"] ?? defaultSessionId ?? ""
    var entries: [TerminalLogEntryResponse] = []
    var truncated = false

    for entry in terminalLog where entry.seq >= since {
      if let sid = entry.sessionId, !requestedSessionId.isEmpty, sid != requestedSessionId {
        continue
      }
      if entries.count >= limit {
        truncated = true
        break
      }
      entries.append(
        TerminalLogEntryResponse(
          seq: entry.seq,
          direction: entry.direction,
          escaped: entry.escaped,
          sessionId: entry.sessionId,
          frame: entry.frame
        ))
    }

    return TerminalLogResponse(
      sessionId: requestedSessionId,
      events: entries,
      next: terminalLogSeq,
      truncated: truncated
    )
  }

  private mutating func appendTerminalLog(_ entry: TerminalLogEntry) {
    var entry = entry
    entry.seq = terminalLogSeq
    terminalLogSeq += 1
    terminalLog.append(entry)
    if terminalLog.count > 1024 {
      terminalLog.removeFirst(terminalLog.count - 1024)
    }
  }

  private func eventResponses(since: Int) -> [EventResponse] {
    eventLog.filter { $0.seq >= since }.map { entry in
      EventResponse(
        seq: entry.seq,
        kind: entry.kind,
        tabId: entry.tabId,
        sessionId: entry.sessionId,
        frame: entry.frame,
        width: entry.width,
        height: entry.height,
        text: entry.text,
        path: entry.path,
        action: entry.action,
        deltaRows: entry.deltaRows,
        error: entry.error
      )
    }
  }

  private static func escapedPreview(_ bytes: [UInt8], limit: Int = 512) -> String {
    var out = ""
    var count = 0
    for byte in bytes {
      if count >= limit {
        out += "..."
        break
      }
      count += 1
      switch byte {
      case 0x09: out += "\\t"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x1B: out += "\\e"
      case 0x20...0x7E:
        out.append(Character(UnicodeScalar(byte)))
      default:
        out += String(format: "\\x%02x", byte)
      }
    }
    return out
  }
}
