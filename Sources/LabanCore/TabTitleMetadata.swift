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
  /// Compact one-line summary used by single-row sidebar layouts.
  public var subtitle: String?
  /// Per-line breakdown for tall sidebar rows. Each entry is one rendered
  /// line below the title; consumer renders as many as fit. Order is
  /// stable: [cwd-or-repo, foreground command, status].
  public var infoLines: [String]
  public var statusBadge: String?

  public init(
    displayTitle: String,
    titleSource: TabTitleSource,
    subtitle: String? = nil,
    infoLines: [String] = [],
    statusBadge: String? = nil
  ) {
    self.displayTitle = displayTitle
    self.titleSource = titleSource
    self.subtitle = subtitle
    self.infoLines = infoLines
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
    let infoLines = breakdownLines(
      for: metadata,
      now: now,
      maxScalars: maxSubtitleScalars,
      skipMatching: title,
      titleSource: choice.source
    )
    return ResolvedTabTitle(
      displayTitle: title,
      titleSource: choice.source,
      subtitle: subtitle,
      infoLines: infoLines,
      statusBadge: statusBadge(for: metadata)
    )
  }

  /// Per-line breakdown shown under the title in tall sidebar layouts.
  /// Order, top-to-bottom: workspace path, full foreground command, status.
  /// Each line independently truncated; entries that duplicate the title or
  /// add no signal (idle shell, repeated cwd) are dropped so the rendered
  /// tab stays information-dense rather than visually padded.
  private static func breakdownLines(
    for metadata: TabTitleMetadata,
    now: Date,
    maxScalars: Int?,
    skipMatching title: String,
    titleSource: TabTitleSource
  ) -> [String] {
    func truncateMid(_ s: String) -> String {
      guard let max = maxScalars else { return s }
      return truncateMiddle(s, maxScalars: max)
    }
    // Paths: keep the tail. The meaningful identifier is usually the last
    // segment (worktree/repo/folder name) — middle-truncating loses it.
    func truncatePath(_ s: String) -> String {
      guard let max = maxScalars else { return s }
      return truncateLeft(s, maxScalars: max)
    }

    var lines: [String] = []

    // Line: workspace path (repo@worktree wins, then home-shortened cwd).
    if let repo = useful(metadata.workspace.repoName) {
      var line = repo
      if let worktree = useful(metadata.workspace.worktreeName), worktree != repo {
        line = "\(repo)@\(worktree)"
      }
      if let branch = useful(metadata.workspace.branch) {
        line += "  " + branch + (metadata.workspace.isDirty ? "*" : "")
      }
      if line != title { lines.append(truncateMid(line)) }
    } else if let cwd = useful(metadata.workspace.cwd) {
      let display = cwdDisplayName(cwd)
      if display != title { lines.append(truncatePath(display)) }
    }

    // Line: full foreground command — only when it's something more useful
    // than "the user's shell idling at a prompt" or "the binary that already
    // named the tab via OSC". A bare shell adds no signal; an OSC-set title
    // means the running process self-identified, so its argv is redundant.
    let processSelfNamed = titleSource == .terminal || titleSource == .agent
    if !processSelfNamed {
      if let cmd = useful(metadata.process.foregroundCommand),
        let runnable = commandName(cmd),
        !isShellProcess(runnable)
      {
        lines.append(truncateMid(cmd))
      } else if let proc = useful(metadata.process.foregroundProcess),
        !isShellProcess(proc)
      {
        lines.append(truncateMid(proc))
      }
    }

    // Line: status — only when the tab is in a state that warrants
    // attention (process exited, prompt waiting on input). Normally-running
    // tabs render no status line so the abnormal ones stand out by simply
    // having more text.
    _ = now
    switch metadata.activityState {
    case .exited:
      let status = metadata.exitStatus.map { "exited \($0)" } ?? "exited"
      lines.append(truncateMid(status))
    case .waiting:
      lines.append(truncateMid("waiting"))
    default:
      break
    }

    return lines
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

  /// Drop scalars from the front and prepend "...". Right for paths and
  /// other strings whose tail carries the identifying information.
  public static func truncateLeft(_ value: String, maxScalars: Int) -> String {
    guard maxScalars > 0 else { return "" }
    guard TerminalTitle.scalarCount(value) > maxScalars else { return value }
    if maxScalars <= 3 { return TerminalTitle.prefixScalars(value, maxScalars: maxScalars) }
    let keep = maxScalars - 3
    var suffix = ""
    suffix.reserveCapacity(keep)
    for scalar in value.unicodeScalars.suffix(keep) {
      suffix.unicodeScalars.append(scalar)
    }
    return "..." + suffix
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
    if let process = useful(metadata.process.foregroundProcess)
      ?? commandName(metadata.process.foregroundCommand),
      !isShellProcess(process)
    {
      if let terminal = useful(metadata.terminalTitle) {
        return (terminal, .terminal)
      }
      return (process, .process)
    }
    if let cwd = useful(metadata.workspace.cwd) {
      return (cwdDisplayName(cwd), .cwd)
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
      parts.append(truncateMiddle(cwdDisplayName(cwd), maxScalars: 32))
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

  private static func cwdDisplayName(_ path: String) -> String {
    let standardized = (path as NSString).standardizingPath
    let home = (NSHomeDirectory() as NSString).standardizingPath
    if standardized == home { return "~" }
    let prefix = home.hasSuffix("/") ? home : home + "/"
    if standardized.hasPrefix(prefix) {
      return "~/" + String(standardized.dropFirst(prefix.count))
    }
    return pathTail(standardized)
  }

  private static func commandName(_ command: String?) -> String? {
    guard let command = useful(command) else { return nil }
    let first = command.split(separator: " ").first.map(String.init) ?? command
    return pathTail(first)
  }

  private static func isShellProcess(_ process: String) -> Bool {
    let name = pathTail(process).lowercased()
    return ["sh", "bash", "dash", "fish", "ksh", "tcsh", "csh", "zsh"].contains(name)
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
