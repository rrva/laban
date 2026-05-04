import Foundation

public enum TabTitleSource: String, Codable, Equatable {
  case user
  case agent
  case repo
  case cwd
  case process
  case terminal
  case fallback
}

public enum TabActivityState: String, Codable, Equatable {
  case active
  case background
  case running
  case idle
  case unseenOutput
  case waiting
  case exited
}

public struct TabWorkspaceMetadata: Codable, Equatable {
  public var cwd: String?
  public var repoName: String?
  public var repoRoot: String?
  public var worktreeName: String?
  public var branch: String?
  public var isDirty: Bool

  public init(
    cwd: String? = nil,
    repoName: String? = nil,
    repoRoot: String? = nil,
    worktreeName: String? = nil,
    branch: String? = nil,
    isDirty: Bool = false
  ) {
    self.cwd = TerminalTitle.sanitize(cwd)
    self.repoName = TerminalTitle.sanitize(repoName)
    self.repoRoot = TerminalTitle.sanitize(repoRoot)
    self.worktreeName = TerminalTitle.sanitize(worktreeName)
    self.branch = TerminalTitle.sanitize(branch)
    self.isDirty = isDirty
  }
}

public struct TabProcessMetadata: Codable, Equatable {
  public var foregroundProcess: String?
  public var foregroundCommand: String?
  public var pid: Int?

  public init(
    foregroundProcess: String? = nil,
    foregroundCommand: String? = nil,
    pid: Int? = nil
  ) {
    self.foregroundProcess = TerminalTitle.sanitize(foregroundProcess)
    self.foregroundCommand = TerminalTitle.sanitize(foregroundCommand)
    self.pid = pid
  }
}

public struct TabAgentMetadata: Codable, Equatable {
  public var agentName: String?
  public var sessionName: String?
  public var sessionId: String?
  public var taskLabel: String?
  public var model: String?
  public var contextPercent: Int?
  public var awaitingInput: Bool

  public init(
    agentName: String? = nil,
    sessionName: String? = nil,
    sessionId: String? = nil,
    taskLabel: String? = nil,
    model: String? = nil,
    contextPercent: Int? = nil,
    awaitingInput: Bool = false
  ) {
    self.agentName = TerminalTitle.sanitize(agentName)
    self.sessionName = TerminalTitle.sanitize(sessionName)
    self.sessionId = TerminalTitle.sanitize(sessionId)
    self.taskLabel = TerminalTitle.sanitize(taskLabel)
    self.model = TerminalTitle.sanitize(model)
    self.contextPercent = contextPercent
    self.awaitingInput = awaitingInput
  }
}

public struct TabTitleMetadata: Codable, Equatable {
  public var userTitle: String?
  public var titleFrozen: Bool
  public var terminalTitle: String?
  public var displayTitle: String
  public var titleSource: TabTitleSource
  public var workspace: TabWorkspaceMetadata
  public var process: TabProcessMetadata
  public var agent: TabAgentMetadata
  public var activityState: TabActivityState
  public var lastActivityAt: Date?
  public var lastOutputAt: Date?
  public var unseenOutput: Bool
  public var exitStatus: Int?

  public init(
    userTitle: String? = nil,
    titleFrozen: Bool = false,
    terminalTitle: String? = nil,
    displayTitle: String,
    titleSource: TabTitleSource,
    workspace: TabWorkspaceMetadata = TabWorkspaceMetadata(),
    process: TabProcessMetadata = TabProcessMetadata(),
    agent: TabAgentMetadata = TabAgentMetadata(),
    activityState: TabActivityState = .running,
    lastActivityAt: Date? = nil,
    lastOutputAt: Date? = nil,
    unseenOutput: Bool = false,
    exitStatus: Int? = nil
  ) {
    self.userTitle = TerminalTitle.sanitize(userTitle)
    self.titleFrozen = titleFrozen
    self.terminalTitle = TerminalTitle.sanitize(terminalTitle)
    self.displayTitle =
      TerminalTitle.sanitize(displayTitle) ?? displayTitle.trimmingCharacters(in: .whitespaces)
    self.titleSource = titleSource
    self.workspace = workspace
    self.process = process
    self.agent = agent
    self.activityState = activityState
    self.lastActivityAt = lastActivityAt
    self.lastOutputAt = lastOutputAt
    self.unseenOutput = unseenOutput
    self.exitStatus = exitStatus
  }

  public static func fallback(position: Int, active: Bool = false) -> TabTitleMetadata {
    TabTitleMetadata(
      displayTitle: "Tab \(position)",
      titleSource: .fallback,
      activityState: active ? .active : .background
    )
  }
}

public struct ResolvedTabTitle: Equatable {
  public var displayTitle: String
  public var titleSource: TabTitleSource
  public var subtitle: String?
  public var statusBadge: String?

  public init(
    displayTitle: String,
    titleSource: TabTitleSource,
    subtitle: String? = nil,
    statusBadge: String? = nil
  ) {
    self.displayTitle = displayTitle
    self.titleSource = titleSource
    self.subtitle = subtitle
    self.statusBadge = statusBadge
  }
}

public enum TabTitleResolver {
  public static func resolve(
    _ metadata: TabTitleMetadata,
    fallbackPosition: Int,
    now: Date = Date(),
    maxTitleScalars: Int? = nil,
    maxSubtitleScalars: Int? = nil
  ) -> ResolvedTabTitle {
    let choice = titleChoice(metadata, fallbackPosition: fallbackPosition)
    let title =
      maxTitleScalars.map { truncateRight(choice.title, maxScalars: $0) } ?? choice.title
    let subtitle = secondaryLine(for: metadata, now: now)
      .flatMap { subtitleText in
        maxSubtitleScalars.map { limit in
          truncateMiddle(subtitleText, maxScalars: limit)
        } ?? subtitleText
      }
    return ResolvedTabTitle(
      displayTitle: title,
      titleSource: choice.source,
      subtitle: subtitle,
      statusBadge: statusBadge(for: metadata)
    )
  }

  public static func resolvedMetadata(
    _ metadata: TabTitleMetadata,
    fallbackPosition: Int,
    now: Date = Date()
  ) -> TabTitleMetadata {
    var next = metadata
    let resolved = resolve(metadata, fallbackPosition: fallbackPosition, now: now)
    next.displayTitle = resolved.displayTitle
    next.titleSource = resolved.titleSource
    return next
  }

  public static func truncateRight(_ value: String, maxScalars: Int) -> String {
    guard maxScalars > 0 else { return "" }
    guard TerminalTitle.scalarCount(value) > maxScalars else { return value }
    if maxScalars <= 3 { return TerminalTitle.prefixScalars(value, maxScalars: maxScalars) }
    return TerminalTitle.prefixScalars(value, maxScalars: maxScalars - 3) + "..."
  }

  public static func truncateMiddle(_ value: String, maxScalars: Int) -> String {
    guard maxScalars > 0 else { return "" }
    guard TerminalTitle.scalarCount(value) > maxScalars else { return value }
    if maxScalars <= 3 { return TerminalTitle.prefixScalars(value, maxScalars: maxScalars) }
    let keep = maxScalars - 3
    let left = max(1, keep / 2)
    let right = max(1, keep - left)
    let prefix = TerminalTitle.prefixScalars(value, maxScalars: left)
    var suffix = ""
    suffix.reserveCapacity(right)
    for scalar in value.unicodeScalars.suffix(right) {
      suffix.unicodeScalars.append(scalar)
    }
    return prefix + "..." + suffix
  }

  private static func titleChoice(
    _ metadata: TabTitleMetadata,
    fallbackPosition: Int
  ) -> (title: String, source: TabTitleSource) {
    if let title = useful(metadata.userTitle) {
      return (title, .user)
    }
    if metadata.titleFrozen, let title = useful(metadata.displayTitle) {
      return (title, .user)
    }
    if let title = useful(metadata.agent.taskLabel) ?? useful(metadata.agent.sessionName) {
      return (title, .agent)
    }
    if let repo = useful(metadata.workspace.repoName) {
      if let worktree = useful(metadata.workspace.worktreeName), worktree != repo {
        return ("\(repo)@\(worktree)", .repo)
      }
      return (repo, .repo)
    }
    if let cwd = useful(metadata.workspace.cwd) {
      return (pathTail(cwd), .cwd)
    }
    if let process = useful(metadata.process.foregroundProcess)
      ?? commandName(metadata.process.foregroundCommand)
    {
      return (process, .process)
    }
    if let terminal = useful(metadata.terminalTitle) {
      return (terminal, .terminal)
    }
    return ("Tab \(fallbackPosition)", .fallback)
  }

  private static func secondaryLine(
    for metadata: TabTitleMetadata,
    now: Date
  ) -> String? {
    var parts: [String] = []

    if let repo = useful(metadata.workspace.repoName) {
      if let worktree = useful(metadata.workspace.worktreeName), worktree != repo {
        parts.append("\(repo)@\(worktree)")
      } else {
        parts.append(repo)
      }
    } else if let cwd = useful(metadata.workspace.cwd) {
      parts.append(truncateMiddle(pathTail(cwd), maxScalars: 32))
    }

    if let branch = useful(metadata.workspace.branch) {
      parts.append(branch + (metadata.workspace.isDirty ? "*" : ""))
    }

    if let process = useful(metadata.process.foregroundProcess)
      ?? commandName(metadata.process.foregroundCommand)
    {
      parts.append(process)
    }

    switch metadata.activityState {
    case .exited:
      if let code = metadata.exitStatus {
        parts.append("exited \(code)")
      } else {
        parts.append("exited")
      }
    case .waiting:
      parts.append("waiting")
    default:
      if let age = compactAge(from: metadata.lastOutputAt ?? metadata.lastActivityAt, now: now) {
        parts.append(age)
      }
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " | ")
  }

  private static func statusBadge(for metadata: TabTitleMetadata) -> String? {
    if metadata.activityState == .waiting || metadata.agent.awaitingInput { return "!" }
    if metadata.activityState == .unseenOutput || metadata.unseenOutput { return "*" }
    if metadata.activityState == .exited, let status = metadata.exitStatus, status != 0 {
      return "!"
    }
    return nil
  }

  private static func useful(_ value: String?) -> String? {
    TerminalTitle.sanitize(value)
  }

  private static func pathTail(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.isEmpty { return "/" }
    return String(trimmed.split(separator: "/").last ?? Substring(trimmed))
  }

  private static func commandName(_ command: String?) -> String? {
    guard let command = useful(command) else { return nil }
    let first = command.split(separator: " ").first.map(String.init) ?? command
    return pathTail(first)
  }

  private static func compactAge(from date: Date?, now: Date) -> String? {
    guard let date else { return nil }
    let seconds = max(0, Int(now.timeIntervalSince(date).rounded(.down)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d"
  }
}
