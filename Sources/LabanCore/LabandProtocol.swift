import Foundation

public enum LabandProtocolVersion {
  public static let current = 1
  public static let minimumCompatible = 1
}

public enum LabandRequestType: String, Codable, Sendable {
  case hello
  case attachSession
  case detachSession
  case createSession
  case listSessions
  case writeInput
  case snapshot
  case attachSnapshotRing
  case applyTheme
  case scrollViewport
  case resizeSession
  case markRendered
  case transferLease
  case renewLease
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
  public var clientId: String?

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
  public var colorScheme: String?
  public var deltaRows: Int?
  public var leaseHolder: String?
  public var leaseId: String?
  public var leaseEpoch: UInt64?

  public init(
    protocolVersion: Int = LabandProtocolVersion.current,
    requestId: String,
    type: LabandRequestType,
    clientId: String? = nil,
    executable: String? = nil,
    argv: [String]? = nil,
    cwd: String? = nil,
    environmentPatch: [String: String]? = nil,
    rows: Int? = nil,
    cols: Int? = nil,
    logicalSessionId: String? = nil,
    sessionId: String? = nil,
    text: String? = nil,
    bytesBase64: String? = nil,
    colorScheme: String? = nil,
    deltaRows: Int? = nil,
    leaseHolder: String? = nil,
    leaseId: String? = nil,
    leaseEpoch: UInt64? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.requestId = requestId
    self.type = type
    self.clientId = clientId
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
    self.colorScheme = colorScheme
    self.deltaRows = deltaRows
    self.leaseHolder = leaseHolder
    self.leaseId = leaseId
    self.leaseEpoch = leaseEpoch
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
  public var minimumProtocolVersion: Int?
  public var buildVersion: String
  public var capabilities: [String]

  public init(
    protocolVersion: Int,
    minimumProtocolVersion: Int? = LabandProtocolVersion.minimumCompatible,
    buildVersion: String,
    capabilities: [String]
  ) {
    self.protocolVersion = protocolVersion
    self.minimumProtocolVersion = minimumProtocolVersion
    self.buildVersion = buildVersion
    self.capabilities = capabilities
  }
}

public struct LabandLeaseHistoryEntry: Codable, Equatable, Sendable {
  public var leaseHolder: String
  public var grantedAtMonoNs: UInt64
  public var leaseId: String?
  public var epoch: UInt64?
  public var expiresAtMonoNs: UInt64?

  public init(
    leaseHolder: String,
    grantedAtMonoNs: UInt64,
    leaseId: String? = nil,
    epoch: UInt64? = nil,
    expiresAtMonoNs: UInt64? = nil
  ) {
    self.leaseHolder = leaseHolder
    self.grantedAtMonoNs = grantedAtMonoNs
    self.leaseId = leaseId
    self.epoch = epoch
    self.expiresAtMonoNs = expiresAtMonoNs
  }
}

public struct LabandLeaseInfo: Codable, Equatable, Sendable {
  public var leaseId: String
  public var sessionId: String
  public var holderClientId: String
  public var epoch: UInt64
  public var grantedAtMonoNs: UInt64
  public var expiresAtMonoNs: UInt64

  public init(
    leaseId: String,
    sessionId: String,
    holderClientId: String,
    epoch: UInt64,
    grantedAtMonoNs: UInt64,
    expiresAtMonoNs: UInt64
  ) {
    self.leaseId = leaseId
    self.sessionId = sessionId
    self.holderClientId = holderClientId
    self.epoch = epoch
    self.grantedAtMonoNs = grantedAtMonoNs
    self.expiresAtMonoNs = expiresAtMonoNs
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
  public var lease: LabandLeaseInfo?
  public var leaseHistory: [LabandLeaseHistoryEntry]
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
    lease: LabandLeaseInfo? = nil,
    leaseHistory: [LabandLeaseHistoryEntry] = [],
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
    self.lease = lease
    self.leaseHistory = leaseHistory
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
