import Foundation
import LabanTerminalCore

public enum WorkspaceSchema {
  public static let currentVersion: Int = 2
}

public struct WorkspaceState: Codable, Equatable {
  public var schemaVersion: Int
  public var windows: [WindowState]

  public init(schemaVersion: Int = WorkspaceSchema.currentVersion, windows: [WindowState]) {
    self.schemaVersion = schemaVersion
    self.windows = windows
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    windows = try container.decode([WindowState].self, forKey: .windows)
    var sessions = Set<String>()
    var tabs = Set<String>()
    for tab in windows.flatMap(\.tabs) {
      guard tabs.insert(tab.id).inserted,
        tab.resolvedPanes.leafSessionIds().allSatisfy({ sessions.insert($0).inserted })
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .windows, in: container,
          debugDescription: "A session or tab identity occurs in more than one tab")
      }
    }
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
  public let sessionId: String
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
    sessionId: String? = nil,
    cwd: String,
    cwdFallbackApplied: Bool,
    transcriptURL: URL?,
    altBufferAtQuit: Bool,
    agent: AgentInfo? = nil,
    shellPid: Int? = nil
  ) {
    self.size = size
    self.tabId = tabId
    self.sessionId = sessionId ?? tabId
    self.cwd = cwd
    self.cwdFallbackApplied = cwdFallbackApplied
    self.transcriptURL = transcriptURL
    self.altBufferAtQuit = altBufferAtQuit
    self.agent = agent
    self.shellPid = shellPid
  }
}

public struct TabState: Codable, Equatable {
  public var panes: PaneTree?
  public var focusedSessionId: String?
  public var paneStates: [PaneState]?
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
    agent: AgentInfo? = nil,
    panes: PaneTree? = nil,
    focusedSessionId: String? = nil,
    paneStates: [PaneState]? = nil
  ) {
    self.panes = panes
    self.focusedSessionId = focusedSessionId
    self.paneStates = paneStates
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

  public var resolvedPanes: PaneTree { panes ?? .leaf(sessionId: id) }
  public var resolvedFocusedSessionId: String { focusedSessionId ?? id }
  public var resolvedPaneStates: [PaneState] { paneStates ?? [flatPaneState] }
  /// Flat per-session views for the pre-existing agent restore planner.
  public var sessionRestoreStates: [TabState] {
    resolvedPaneStates.map { pane in
      TabState(
        id: pane.sessionId, cwd: pane.cwd, launchCommand: pane.launchCommand,
        lastActiveAt: lastActiveAt, transcriptPath: pane.transcriptPath,
        altBufferAtQuit: pane.altBufferAtQuit, cwdFallbackApplied: pane.cwdFallbackApplied,
        repoFingerprint: pane.repoFingerprint, processStatus: pane.processStatus,
        exitCode: pane.exitCode, shellPid: pane.shellPid, agent: pane.agent)
    }
  }

  private var flatPaneState: PaneState {
    PaneState(
      sessionId: id, cwd: cwd, launchCommand: launchCommand,
      transcriptPath: transcriptPath, altBufferAtQuit: altBufferAtQuit,
      cwdFallbackApplied: cwdFallbackApplied, repoFingerprint: repoFingerprint,
      processStatus: processStatus, exitCode: exitCode, shellPid: shellPid, agent: agent)
  }

  // Version-one values and their decoded single-pane representation are equivalent.
  public static func == (lhs: TabState, rhs: TabState) -> Bool {
    lhs.id == rhs.id
      && lhs.cwd == rhs.cwd
      && lhs.launchCommand == rhs.launchCommand
      && lhs.lastActiveAt == rhs.lastActiveAt
      && lhs.transcriptPath == rhs.transcriptPath
      && lhs.altBufferAtQuit == rhs.altBufferAtQuit
      && lhs.cwdFallbackApplied == rhs.cwdFallbackApplied
      && lhs.repoFingerprint == rhs.repoFingerprint
      && lhs.processStatus == rhs.processStatus
      && lhs.exitCode == rhs.exitCode
      && lhs.shellPid == rhs.shellPid
      && lhs.agent == rhs.agent
      && lhs.resolvedPanes == rhs.resolvedPanes
      && lhs.resolvedFocusedSessionId == rhs.resolvedFocusedSessionId
      && lhs.resolvedPaneStates == rhs.resolvedPaneStates
  }

  private enum CodingKeys: String, CodingKey {
    case panes, focusedSessionId, paneStates
    case id, cwd, launchCommand, lastActiveAt, transcriptPath, altBufferAtQuit, cwdFallbackApplied,
      repoFingerprint, processStatus, exitCode, shellPid, agent
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    cwd = try c.decode(String.self, forKey: .cwd)
    launchCommand = try c.decode(String.self, forKey: .launchCommand)
    lastActiveAt = try c.decode(Date.self, forKey: .lastActiveAt)
    transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
    altBufferAtQuit = try c.decodeIfPresent(Bool.self, forKey: .altBufferAtQuit)
    cwdFallbackApplied = try c.decodeIfPresent(Bool.self, forKey: .cwdFallbackApplied)
    repoFingerprint = try c.decodeIfPresent(String.self, forKey: .repoFingerprint)
    processStatus = try c.decodeIfPresent(PersistedProcessStatus.self, forKey: .processStatus)
    exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
    shellPid = try c.decodeIfPresent(Int.self, forKey: .shellPid)
    agent = try c.decodeIfPresent(AgentInfo.self, forKey: .agent)
    panes = nil
    focusedSessionId = nil
    paneStates = nil
    do {
      if let tree = try c.decodeIfPresent(PaneTree.self, forKey: .panes) {
        let states = try c.decode([PaneState].self, forKey: .paneStates)
        let focus = try c.decode(String.self, forKey: .focusedSessionId)
        let ids = tree.leafSessionIds()
        guard !ids.isEmpty, Set(ids).count == ids.count, !ids.contains(""),
          Set(states.map(\.sessionId)) == Set(ids), states.count == ids.count, tree.contains(focus)
        else {
          throw DecodingError.dataCorruptedError(
            forKey: .panes, in: c, debugDescription: "invalid pane identities")
        }
        panes = tree
        focusedSessionId = focus
        paneStates = states
      }
    } catch {
      NSLog(
        "Invalid pane layout for tab \(id); restoring its first session: \(String(describing: error))"
      )
    }
    if panes == nil {
      panes = .leaf(sessionId: id)
      focusedSessionId = id
      paneStates = [flatPaneState]
    }
  }
}

public struct PaneState: Codable, Equatable {
  public var sessionId: String
  public var cwd: String
  public var launchCommand: String
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
    sessionId: String,
    cwd: String,
    launchCommand: String,
    transcriptPath: String? = nil,
    altBufferAtQuit: Bool? = nil,
    cwdFallbackApplied: Bool? = nil,
    repoFingerprint: String? = nil,
    processStatus: PersistedProcessStatus? = nil,
    exitCode: Int? = nil,
    shellPid: Int? = nil,
    agent: AgentInfo? = nil
  ) {
    self.sessionId = sessionId
    self.cwd = cwd
    self.launchCommand = launchCommand
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
