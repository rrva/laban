import Foundation

public enum AgentRestoreWarningCode: String, Codable, Equatable, Sendable {
  case cwdMissing
  case repoFingerprintMismatch
}

public struct AgentRestoreWarning: Codable, Equatable, Sendable {
  public var code: AgentRestoreWarningCode
  public var message: String

  public init(code: AgentRestoreWarningCode, message: String) {
    self.code = code
    self.message = message
  }
}

public struct AgentRestoreCandidate: Codable, Equatable, Sendable {
  public var tabId: String
  public var agentName: AgentName
  public var sessionId: String
  public var command: String
  public var cwd: String
  public var launchCwd: String
  public var lastActiveAt: Date
  public var ageSeconds: Int
  public var checkedByDefault: Bool
  public var warnings: [AgentRestoreWarning]

  public init(
    tabId: String,
    agentName: AgentName,
    sessionId: String,
    command: String,
    cwd: String,
    launchCwd: String,
    lastActiveAt: Date,
    ageSeconds: Int,
    checkedByDefault: Bool,
    warnings: [AgentRestoreWarning]
  ) {
    self.tabId = tabId
    self.agentName = agentName
    self.sessionId = sessionId
    self.command = command
    self.cwd = cwd
    self.launchCwd = launchCwd
    self.lastActiveAt = lastActiveAt
    self.ageSeconds = ageSeconds
    self.checkedByDefault = checkedByDefault
    self.warnings = warnings
  }
}

public struct AgentRestorePickerState: Codable, Equatable, Sendable {
  public var pending: Bool
  public var candidates: [AgentRestoreCandidate]

  public init(candidates: [AgentRestoreCandidate]) {
    self.pending = !candidates.isEmpty
    self.candidates = candidates
  }
}

public enum AgentRestorePicker {
  public static func candidates(
    from state: WorkspaceState,
    now: Date = Date(),
    cwdExists: (String) -> Bool = { path in
      var isDir: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        && isDir.boolValue
    },
    repoFingerprint: (String) -> String? = RepoFingerprint.fingerprint(cwd:)
  ) -> [AgentRestoreCandidate] {
    guard let window = state.windows.first else { return [] }
    return window.tabs.compactMap { tab in
      candidate(
        for: tab,
        now: now,
        cwdExists: cwdExists,
        repoFingerprint: repoFingerprint)
    }
  }

  public static func candidate(
    for tab: TabState,
    now: Date = Date(),
    cwdExists: (String) -> Bool = { path in
      var isDir: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        && isDir.boolValue
    },
    repoFingerprint: (String) -> String? = RepoFingerprint.fingerprint(cwd:)
  ) -> AgentRestoreCandidate? {
    guard let agent = tab.agent,
      let support = AgentRegistry.entry(for: agent.name)
    else { return nil }

    let persistedCwd = agent.cwd ?? tab.cwd
    let launchCwd = cwdExists(persistedCwd)
      ? persistedCwd
      : FileManager.default.homeDirectoryForCurrentUser.path
    let context = AgentLaunchContext(
      cwd: launchCwd,
      argv: agent.argv ?? [],
      env: agent.env ?? [:])
    let command = support.resumeCommand(sessionId: agent.sessionId, context: context)
    var warnings: [AgentRestoreWarning] = []

    if !cwdExists(persistedCwd) {
      warnings.append(
        AgentRestoreWarning(
          code: .cwdMissing,
          message:
            "The saved working directory no longer exists; restore will start in \(launchCwd)."))
    }
    if let persisted = tab.repoFingerprint,
      repoFingerprint(persistedCwd) != persisted
    {
      warnings.append(
        AgentRestoreWarning(
          code: .repoFingerprintMismatch,
          message: "The repository at the saved working directory no longer matches the saved tab."))
    }

    return AgentRestoreCandidate(
      tabId: tab.id,
      agentName: agent.name,
      sessionId: agent.sessionId,
      command: command,
      cwd: persistedCwd,
      launchCwd: launchCwd,
      lastActiveAt: tab.lastActiveAt,
      ageSeconds: max(0, Int(now.timeIntervalSince(tab.lastActiveAt))),
      checkedByDefault: false,
      warnings: warnings
    )
  }
}
