import Foundation

public enum CaptureEventKind: String, Codable, Hashable, Sendable {
  case captureStarted = "capture.started"
  case captureFinished = "capture.finished"
  case appState = "app.state"
  case tabCreated = "tab.created"
  case tabSelected = "tab.selected"
  case tabClosed = "tab.closed"
  case sessionCreated = "session.created"
  case sessionResized = "session.resized"
  case sessionExited = "session.exited"
  case inputEvent = "input.event"
  case ptyInput = "pty.input"
  case ptyOutput = "pty.output"
  case terminalResponse = "terminal.response"
  case frameBegin = "frame.begin"
  case terminalSnapshot = "terminal.snapshot"
  case frameCommands = "frame.commands"
  case frameRendered = "frame.rendered"
  case screenshotCaptured = "screenshot.captured"
  case captureSnapshot = "capture.snapshot"
  case captureError = "capture.error"
}

public enum CaptureByteDirection: String, Codable, Hashable, Sendable {
  case ptyInput = "pty-input"
  case ptyOutput = "pty-output"
  case terminalResponse = "terminal-response"

  public var eventKind: CaptureEventKind {
    switch self {
    case .ptyInput: return .ptyInput
    case .ptyOutput: return .ptyOutput
    case .terminalResponse: return .terminalResponse
    }
  }

  public var streamFileName: String {
    switch self {
    case .ptyInput: return "pty-input.bin"
    case .ptyOutput: return "pty-output.bin"
    case .terminalResponse: return "terminal-response.bin"
    }
  }
}

public struct CaptureByteRef: Codable, Equatable, Sendable {
  public var stream: String
  public var path: String
  public var offset: Int
  public var length: Int
  public var sha256: String
  public var escapedPreview: String?

  public init(
    stream: String,
    path: String,
    offset: Int,
    length: Int,
    sha256: String,
    escapedPreview: String? = nil
  ) {
    self.stream = stream
    self.path = path
    self.offset = offset
    self.length = length
    self.sha256 = sha256
    self.escapedPreview = escapedPreview
  }
}

public struct CaptureFrameRef: Codable, Equatable, Sendable {
  public var path: String
  public var sha256: String
  public var commandCount: Int?
  public var pixelHash: String?

  public init(path: String, sha256: String, commandCount: Int? = nil, pixelHash: String? = nil) {
    self.path = path
    self.sha256 = sha256
    self.commandCount = commandCount
    self.pixelHash = pixelHash
  }
}

public struct InputEventEnvelope: Codable, Equatable, Sendable {
  public var inputId: String
  public var seq: Int
  public var source: String
  public var kind: String
  public var route: String
  public var frameBefore: Int
  public var tabId: String?
  public var sessionId: String?
  public var key: String?
  public var text: String?
  public var modifiers: [String]?
  public var consumedModifiers: [String]?
  public var command: String?
  public var encodedHex: String?
  public var encodedLength: Int?
  public var error: String?
  public var deltaRows: Int?
  public var anchorRow: Int?
  public var anchorCol: Int?
  public var focusRow: Int?
  public var focusCol: Int?

  public init(
    inputId: String,
    seq: Int = 0,
    source: String,
    kind: String,
    route: String,
    frameBefore: Int,
    tabId: String? = nil,
    sessionId: String? = nil,
    key: String? = nil,
    text: String? = nil,
    modifiers: [String]? = nil,
    consumedModifiers: [String]? = nil,
    command: String? = nil,
    encodedHex: String? = nil,
    encodedLength: Int? = nil,
    error: String? = nil,
    deltaRows: Int? = nil,
    anchorRow: Int? = nil,
    anchorCol: Int? = nil,
    focusRow: Int? = nil,
    focusCol: Int? = nil
  ) {
    self.inputId = inputId
    self.seq = seq
    self.source = source
    self.kind = kind
    self.route = route
    self.frameBefore = frameBefore
    self.tabId = tabId
    self.sessionId = sessionId
    self.key = key
    self.text = text
    self.modifiers = modifiers
    self.consumedModifiers = consumedModifiers
    self.command = command
    self.encodedHex = encodedHex
    self.encodedLength = encodedLength
    self.error = error
    self.deltaRows = deltaRows
    self.anchorRow = anchorRow
    self.anchorCol = anchorCol
    self.focusRow = focusRow
    self.focusCol = focusCol
  }
}

public struct CaptureTimelineEvent: Codable, Equatable, Sendable {
  public var seq: Int
  public var timeNs: UInt64
  public var kind: String
  public var frame: Int?
  public var tabId: String?
  public var sessionId: String?

  public var inputId: String?
  public var source: String?
  public var frameBefore: Int?
  public var inputKind: String?
  public var route: String?
  public var key: String?
  public var text: String?
  public var modifiers: [String]?
  public var consumedModifiers: [String]?
  public var command: String?
  public var encodedHex: String?
  public var encodedLength: Int?

  public var stream: String?
  public var offset: Int?
  public var length: Int?
  public var sha256: String?
  public var escapedPreview: String?

  public var path: String?
  public var commandCount: Int?
  public var rows: Int?
  public var cols: Int?
  public var cursorRow: Int?
  public var cursorCol: Int?
  public var cursorVisible: Bool?
  public var title: String?
  public var status: String?
  public var mouseTracking: Bool?
  public var focusReporting: Bool?
  public var dirty: Bool?
  public var visibleHash: String?

  public var width: Int?
  public var height: Int?
  public var pixelWidth: Int?
  public var pixelHeight: Int?
  public var cellWidth: Int?
  public var cellHeight: Int?
  public var scale: Double?
  public var backend: String?
  public var pixelHash: String?

  public var error: String?
  public var interrupted: Bool?
  public var deltaRows: Int?
  public var anchorRow: Int?
  public var anchorCol: Int?
  public var focusRow: Int?
  public var focusCol: Int?

  public init(
    seq: Int = -1,
    timeNs: UInt64 = CaptureClock.nowNs(),
    kind: CaptureEventKind,
    frame: Int? = nil,
    tabId: String? = nil,
    sessionId: String? = nil
  ) {
    self.seq = seq
    self.timeNs = timeNs
    self.kind = kind.rawValue
    self.frame = frame
    self.tabId = tabId
    self.sessionId = sessionId
  }

  public init(input envelope: InputEventEnvelope) {
    self.init(
      seq: -1,
      kind: .inputEvent,
      frame: envelope.frameBefore,
      tabId: envelope.tabId,
      sessionId: envelope.sessionId
    )
    self.inputId = envelope.inputId
    self.source = envelope.source
    self.frameBefore = envelope.frameBefore
    self.inputKind = envelope.kind
    self.route = envelope.route
    self.key = envelope.key
    self.text = envelope.text
    self.modifiers = envelope.modifiers
    self.consumedModifiers = envelope.consumedModifiers
    self.command = envelope.command
    self.encodedHex = envelope.encodedHex
    self.encodedLength = envelope.encodedLength
    self.error = envelope.error
    self.deltaRows = envelope.deltaRows
    self.anchorRow = envelope.anchorRow
    self.anchorCol = envelope.anchorCol
    self.focusRow = envelope.focusRow
    self.focusCol = envelope.focusCol
  }
}

public protocol CaptureSink: AnyObject {
  func nextSequence() -> Int
  func record(_ event: CaptureTimelineEvent)
  func recordBytes(
    direction: CaptureByteDirection,
    sessionId: Session.ID?,
    frame: Int,
    bytes: UnsafeRawBufferPointer,
    preview: String?
  ) -> CaptureByteRef?
}

public enum CaptureClock {
  public static func nowNs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
  }
}
