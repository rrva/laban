import Foundation
import LabanTerminalCore

public enum WorkspaceSchema {
  public static let currentVersion: Int = 1
}

public struct WorkspaceState: Codable, Equatable {
  public var schemaVersion: Int
  public var windows: [WindowState]

  public init(schemaVersion: Int = WorkspaceSchema.currentVersion, windows: [WindowState]) {
    self.schemaVersion = schemaVersion
    self.windows = windows
  }
}

public struct WindowState: Codable, Equatable {
  public var id: String
  public var selectedTabId: String?
  public var tabs: [TabState]
  public var sidebarVisible: Bool?

  public init(
    id: String,
    selectedTabId: String? = nil,
    tabs: [TabState] = [],
    sidebarVisible: Bool? = nil
  ) {
    self.id = id
    self.selectedTabId = selectedTabId
    self.tabs = tabs
    self.sidebarVisible = sidebarVisible
  }
}

public enum PersistedProcessStatus: String, Codable, Equatable {
  case running
  case exitedClean
  case exitedError
  case neverStarted
}

public enum AgentName: String, Codable, Equatable, Sendable {
  case claude
  case codex
}

public struct AgentInfo: Codable, Equatable {
  public var name: AgentName
  public var sessionId: String
  public var jsonlPath: String
  public var wasRunningAtQuit: Bool
  public var argv: [String]?
  public var env: [String: String]?
  public var cwd: String?

  public init(
    name: AgentName,
    sessionId: String,
    jsonlPath: String,
    wasRunningAtQuit: Bool,
    argv: [String]? = nil,
    env: [String: String]? = nil,
    cwd: String? = nil
  ) {
    self.name = name
    self.sessionId = sessionId
    self.jsonlPath = jsonlPath
    self.wasRunningAtQuit = wasRunningAtQuit
    self.argv = argv
    self.env = env
    self.cwd = cwd
  }
}

/// Restoration-time spec passed to `AppModel.restoredDeferredSessionFactory`.
/// Production wires the factory to build a deferred-spawn Session and
/// call `Session.startSpawn(overrideCwd:)` in the restored cwd. The
/// `transcriptURL` is retained for explicit diagnostic inspection;
/// automatic restore must not replay historical transcript bytes into
/// the live terminal.
public struct RestoredSessionSpec {
  public let size: LabanTerminalSize
  public let tabId: String
  public let cwd: String
  public let cwdFallbackApplied: Bool
  public let transcriptURL: URL?
  public let altBufferAtQuit: Bool
  /// Raw persisted agent metadata, forwarded so the restore factory can
  /// run `RestoreLaunchPlanner` and decide whether to launch the shell
  /// with an injected resume command (`.executeNow`). `nil` for tabs
  /// that carried no agent.
  public let agent: AgentInfo?
  /// Shell pid observed at the previous quit, used by the planner's
  /// activity check to avoid auto-resuming a session another Laban
  /// instance still owns.
  public let shellPid: Int?

  public init(
    size: LabanTerminalSize,
    tabId: String,
    cwd: String,
    cwdFallbackApplied: Bool,
    transcriptURL: URL?,
    altBufferAtQuit: Bool,
    agent: AgentInfo? = nil,
    shellPid: Int? = nil
  ) {
    self.size = size
    self.tabId = tabId
    self.cwd = cwd
    self.cwdFallbackApplied = cwdFallbackApplied
    self.transcriptURL = transcriptURL
    self.altBufferAtQuit = altBufferAtQuit
    self.agent = agent
    self.shellPid = shellPid
  }
}

public struct TabState: Codable, Equatable {
  public var id: String
  public var cwd: String
  public var launchCommand: String
  public var lastActiveAt: Date
  public var transcriptPath: String?
  public var altBufferAtQuit: Bool?
  public var cwdFallbackApplied: Bool?
  public var repoFingerprint: String?
  public var processStatus: PersistedProcessStatus?
  public var exitCode: Int?
  /// Shell process id observed when the workspace snapshot was written.
  /// Used only as a best-effort restore-time guard: if another Laban
  /// instance still owns this shell and the same agent session is live
  /// below it, the new instance must not auto-resume a duplicate
  /// Claude/Codex process.
  public var shellPid: Int?
  public var agent: AgentInfo?

  public init(
    id: String,
    cwd: String,
    launchCommand: String,
    lastActiveAt: Date,
    transcriptPath: String? = nil,
    altBufferAtQuit: Bool? = nil,
    cwdFallbackApplied: Bool? = nil,
    repoFingerprint: String? = nil,
    processStatus: PersistedProcessStatus? = nil,
    exitCode: Int? = nil,
    shellPid: Int? = nil,
    agent: AgentInfo? = nil
  ) {
    self.id = id
    self.cwd = cwd
    self.launchCommand = launchCommand
    self.lastActiveAt = lastActiveAt
    self.transcriptPath = transcriptPath
    self.altBufferAtQuit = altBufferAtQuit
    self.cwdFallbackApplied = cwdFallbackApplied
    self.repoFingerprint = repoFingerprint
    self.processStatus = processStatus
    self.exitCode = exitCode
    self.shellPid = shellPid
    self.agent = agent
  }
}
