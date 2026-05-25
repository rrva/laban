import Foundation

public enum LabandProtocolVersion {
  public static let current = 1
}

public enum LabandRequestType: String, Codable, Sendable {
  case hello
  case createSession
  case listSessions
  case writeInput
  case snapshot
  case attachSnapshotRing
  case resizeSession
  case markRendered
  case terminateSession
  case shutdownWhenIdle
}

public enum LabandLifecycleState: String, Codable, Sendable {
  case running
  case exited
  case terminated
  case dead
}

public struct LabandRequest: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var requestId: String
  public var type: LabandRequestType

  public var executable: String?
  public var argv: [String]?
  public var cwd: String?
  public var environmentPatch: [String: String]?
  public var rows: Int?
  public var cols: Int?
  public var logicalSessionId: String?

  public var sessionId: String?
  public var text: String?
  public var bytesBase64: String?

  public init(
    protocolVersion: Int = LabandProtocolVersion.current,
    requestId: String,
    type: LabandRequestType,
    executable: String? = nil,
    argv: [String]? = nil,
    cwd: String? = nil,
    environmentPatch: [String: String]? = nil,
    rows: Int? = nil,
    cols: Int? = nil,
    logicalSessionId: String? = nil,
    sessionId: String? = nil,
    text: String? = nil,
    bytesBase64: String? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.requestId = requestId
    self.type = type
    self.executable = executable
    self.argv = argv
    self.cwd = cwd
    self.environmentPatch = environmentPatch
    self.rows = rows
    self.cols = cols
    self.logicalSessionId = logicalSessionId
    self.sessionId = sessionId
    self.text = text
    self.bytesBase64 = bytesBase64
  }
}

public struct LabandErrorResponse: Codable, Equatable, Sendable {
  public var code: String
  public var message: String
  public var retryable: Bool

  public init(code: String, message: String, retryable: Bool) {
    self.code = code
    self.message = message
    self.retryable = retryable
  }
}

public struct LabandHelloResponse: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var buildVersion: String
  public var capabilities: [String]

  public init(protocolVersion: Int, buildVersion: String, capabilities: [String]) {
    self.protocolVersion = protocolVersion
    self.buildVersion = buildVersion
    self.capabilities = capabilities
  }
}

public struct LabandSessionInfo: Codable, Equatable, Sendable {
  public var logicalSessionId: String
  public var incarnationId: String
  public var childPid: Int?
  public var foregroundPid: Int?
  public var daemonProcessPid: Int
  public var cwd: String
  public var commandDisplayName: String
  public var title: String
  public var rows: Int
  public var cols: Int
  public var lifecycleState: LabandLifecycleState
  public var attachedClientCount: Int
  public var leaseHolder: String?
  public var transportMode: String

  public init(
    logicalSessionId: String,
    incarnationId: String,
    childPid: Int?,
    foregroundPid: Int?,
    daemonProcessPid: Int,
    cwd: String,
    commandDisplayName: String,
    title: String,
    rows: Int,
    cols: Int,
    lifecycleState: LabandLifecycleState,
    attachedClientCount: Int,
    leaseHolder: String?,
    transportMode: String
  ) {
    self.logicalSessionId = logicalSessionId
    self.incarnationId = incarnationId
    self.childPid = childPid
    self.foregroundPid = foregroundPid
    self.daemonProcessPid = daemonProcessPid
    self.cwd = cwd
    self.commandDisplayName = commandDisplayName
    self.title = title
    self.rows = rows
    self.cols = cols
    self.lifecycleState = lifecycleState
    self.attachedClientCount = attachedClientCount
    self.leaseHolder = leaseHolder
    self.transportMode = transportMode
  }
}

public struct LabandSnapshotCell: Codable, Equatable, Sendable {
  public var row: Int
  public var col: Int
  public var text: String
  public var flags: UInt16
  public var foregroundRGBA: UInt32
  public var backgroundRGBA: UInt32

  public init(
    row: Int,
    col: Int,
    text: String,
    flags: UInt16,
    foregroundRGBA: UInt32,
    backgroundRGBA: UInt32
  ) {
    self.row = row
    self.col = col
    self.text = text
    self.flags = flags
    self.foregroundRGBA = foregroundRGBA
    self.backgroundRGBA = backgroundRGBA
  }
}

public struct LabandSnapshotResponse: Codable, Equatable, Sendable {
  public var logicalSessionId: String
  public var incarnationId: String
  public var rows: Int
  public var cols: Int
  public var cursorRow: Int
  public var cursorCol: Int
  public var cursorVisible: Bool
  public var title: String
  public var lifecycleState: LabandLifecycleState
  public var exitStatus: Int?
  public var dirty: Bool
  public var visibleText: String
  public var cells: [LabandSnapshotCell]

  public init(
    logicalSessionId: String,
    incarnationId: String,
    rows: Int,
    cols: Int,
    cursorRow: Int,
    cursorCol: Int,
    cursorVisible: Bool,
    title: String,
    lifecycleState: LabandLifecycleState,
    exitStatus: Int?,
    dirty: Bool,
    visibleText: String,
    cells: [LabandSnapshotCell]
  ) {
    self.logicalSessionId = logicalSessionId
    self.incarnationId = incarnationId
    self.rows = rows
    self.cols = cols
    self.cursorRow = cursorRow
    self.cursorCol = cursorCol
    self.cursorVisible = cursorVisible
    self.title = title
    self.lifecycleState = lifecycleState
    self.exitStatus = exitStatus
    self.dirty = dirty
    self.visibleText = visibleText
    self.cells = cells
  }
}

public struct LabandResponse: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var requestId: String
  public var type: LabandRequestType
  public var ok: Bool
  public var error: LabandErrorResponse?
  public var hello: LabandHelloResponse?
  public var session: LabandSessionInfo?
  public var sessions: [LabandSessionInfo]?
  public var snapshot: LabandSnapshotResponse?
  public var snapshotRing: LabandSnapshotRingAttachment?

  public init(
    protocolVersion: Int = LabandProtocolVersion.current,
    requestId: String,
    type: LabandRequestType,
    ok: Bool,
    error: LabandErrorResponse? = nil,
    hello: LabandHelloResponse? = nil,
    session: LabandSessionInfo? = nil,
    sessions: [LabandSessionInfo]? = nil,
    snapshot: LabandSnapshotResponse? = nil,
    snapshotRing: LabandSnapshotRingAttachment? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.requestId = requestId
    self.type = type
    self.ok = ok
    self.error = error
    self.hello = hello
    self.session = session
    self.sessions = sessions
    self.snapshot = snapshot
    self.snapshotRing = snapshotRing
  }

  public static func error(
    requestId: String,
    type: LabandRequestType,
    code: String,
    message: String,
    retryable: Bool = false
  ) -> LabandResponse {
    LabandResponse(
      requestId: requestId,
      type: type,
      ok: false,
      error: LabandErrorResponse(code: code, message: message, retryable: retryable)
    )
  }
}
