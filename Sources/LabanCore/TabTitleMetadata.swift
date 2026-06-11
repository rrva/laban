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

/// String fields are sanitized on every assignment — by the initializer and
/// by the `didSet` observers — so the render-time title resolver can treat
/// them as already clean instead of re-sanitizing each field per frame.
public struct TabWorkspaceMetadata: Codable, Equatable {
  public var cwd: String? { didSet { cwd = TerminalTitle.sanitize(cwd) } }
  public var repoName: String? { didSet { repoName = TerminalTitle.sanitize(repoName) } }
  public var repoRoot: String? { didSet { repoRoot = TerminalTitle.sanitize(repoRoot) } }
  public var worktreeName: String? {
    didSet { worktreeName = TerminalTitle.sanitize(worktreeName) }
  }
  public var branch: String? { didSet { branch = TerminalTitle.sanitize(branch) } }
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
  public var foregroundProcess: String? {
    didSet { foregroundProcess = TerminalTitle.sanitize(foregroundProcess) }
  }
  public var foregroundCommand: String? {
    didSet { foregroundCommand = TerminalTitle.sanitize(foregroundCommand) }
  }
  public var foregroundArguments: [String]? {
    didSet { foregroundArguments = Self.sanitizeArguments(foregroundArguments) }
  }
  public var pid: Int?

  public init(
    foregroundProcess: String? = nil,
    foregroundCommand: String? = nil,
    foregroundArguments: [String]? = nil,
    pid: Int? = nil
  ) {
    self.foregroundProcess = TerminalTitle.sanitize(foregroundProcess)
    self.foregroundCommand = TerminalTitle.sanitize(foregroundCommand)
    self.foregroundArguments = Self.sanitizeArguments(foregroundArguments)
    self.pid = pid
  }

  static func sanitizeArguments(_ arguments: [String]?) -> [String]? {
    let sanitized = arguments?.compactMap { TerminalTitle.sanitize($0) }
    return sanitized?.isEmpty == false ? sanitized : nil
  }
}

/// State pushed by an in-tab process via iTerm2's OSC 21337 sequence.
/// Two coupled signals: a small colored indicator dot for at-a-glance
/// recognition, and a short text label (Idle / Working… / Waiting) with
/// its own color.
public struct TabAgentStatus: Codable, Equatable, Sendable {
  /// Hex `#rrggbb` for the indicator dot, or nil when no agent has
  /// reported one yet (or the field has been cleared).
  public var indicatorColor: String?
  /// Short status label rendered as one of the sidebar info lines.
  public var statusText: String?
  /// Hex `#rrggbb` for the status text color. nil falls back to dim0.
  public var statusTextColor: String?

  public init(
    indicatorColor: String? = nil,
    statusText: String? = nil,
    statusTextColor: String? = nil
  ) {
    self.indicatorColor = indicatorColor
    self.statusText = statusText
    self.statusTextColor = statusTextColor
  }

  public var isEmpty: Bool {
    indicatorColor == nil && statusText == nil && statusTextColor == nil
  }
}

public struct TabAgentMetadata: Codable, Equatable {
  public var agentName: String? { didSet { agentName = TerminalTitle.sanitize(agentName) } }
  public var sessionName: String? { didSet { sessionName = TerminalTitle.sanitize(sessionName) } }
  public var sessionId: String? { didSet { sessionId = TerminalTitle.sanitize(sessionId) } }
  public var taskLabel: String? { didSet { taskLabel = TerminalTitle.sanitize(taskLabel) } }
  public var model: String? { didSet { model = TerminalTitle.sanitize(model) } }
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

/// A desktop notification an in-tab program emitted via OSC 9 (e.g. the Codex
/// agent signalling "turn complete" or "approval requested") that the user has
/// not yet seen. It is surfaced on the tab until the user opens that tab —
/// distinct from `bellAttention` (a transient bell) and `agentStatus` (live
/// status), following the per-tab attention conventions of iTerm2 / kitty /
/// Warp. `count` accumulates notifications that arrive before the tab is
/// viewed; `urgent` marks action-needed notifications (approval / edit / input
/// requests) for the urgent visual style.
public struct TabNotification: Codable, Equatable, Sendable {
  public var text: String
  public var urgent: Bool
  public var count: Int

  public init(text: String, urgent: Bool, count: Int = 1) {
    self.text = text
    self.urgent = urgent
    self.count = max(1, count)
  }
}

public struct TabTitleMetadata: Codable, Equatable {
  public var userTitle: String? { didSet { userTitle = TerminalTitle.sanitize(userTitle) } }
  public var titleFrozen: Bool
  public var terminalTitle: String? {
    didSet { terminalTitle = TerminalTitle.sanitize(terminalTitle) }
  }
  public var displayTitle: String {
    didSet { displayTitle = TerminalTitle.sanitize(displayTitle) ?? "" }
  }
  public var titleSource: TabTitleSource
  public var workspace: TabWorkspaceMetadata
  public var process: TabProcessMetadata
  public var agent: TabAgentMetadata
  public var agentStatus: TabAgentStatus
  public var activityState: TabActivityState
  public var unseenOutput: Bool
  public var bellAttention: Bool
  /// Unseen OSC 9 desktop notification for this tab, or nil when none is
  /// pending. Cleared when the user opens (or returns to) this tab.
  public var notification: TabNotification?
  public var exitStatus: Int?
  /// Live OSC 133 shell phase for this tab's session. Runtime UI state, not
  /// persisted: a restored tab's fresh shell re-emits its own markers.
  public var shellPhase: ShellIntegrationPhase
  /// Exit code of the last command the shell reported finished (OSC 133 `D`),
  /// or nil if none yet. Distinct from `exitStatus`, which is the *shell
  /// process* exit, not a command's.
  public var lastCommandExitCode: Int?

  public init(
    userTitle: String? = nil,
    titleFrozen: Bool = false,
    terminalTitle: String? = nil,
    displayTitle: String,
    titleSource: TabTitleSource,
    workspace: TabWorkspaceMetadata = TabWorkspaceMetadata(),
    process: TabProcessMetadata = TabProcessMetadata(),
    agent: TabAgentMetadata = TabAgentMetadata(),
    agentStatus: TabAgentStatus = TabAgentStatus(),
    activityState: TabActivityState = .running,
    unseenOutput: Bool = false,
    bellAttention: Bool = false,
    notification: TabNotification? = nil,
    exitStatus: Int? = nil,
    shellPhase: ShellIntegrationPhase = .idle,
    lastCommandExitCode: Int? = nil
  ) {
    self.userTitle = TerminalTitle.sanitize(userTitle)
    self.titleFrozen = titleFrozen
    self.terminalTitle = TerminalTitle.sanitize(terminalTitle)
    self.displayTitle = TerminalTitle.sanitize(displayTitle) ?? ""
    self.titleSource = titleSource
    self.workspace = workspace
    self.process = process
    self.agent = agent
    self.agentStatus = agentStatus
    self.activityState = activityState
    self.unseenOutput = unseenOutput
    self.bellAttention = bellAttention
    self.notification = notification
    self.exitStatus = exitStatus
    self.shellPhase = shellPhase
    self.lastCommandExitCode = lastCommandExitCode
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
    lastActivity: Date? = nil,
    maxTitleScalars: Int? = nil,
    maxSubtitleScalars: Int? = nil
  ) -> ResolvedTabTitle {
    let choice = titleChoice(metadata, fallbackPosition: fallbackPosition)
    let title =
      maxTitleScalars.map { truncateRight(choice.title, maxScalars: $0) } ?? choice.title
    let subtitle = secondaryLine(
      for: metadata,
      now: now,
      lastActivity: lastActivity,
      title: choice.title,
      titleSource: choice.source
    )
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
  /// Order, top-to-bottom: workspace path, compact foreground command detail, status.
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

    // Line 1: folder. Repo@worktree wins (only set by the headless debug
    // runtime today); otherwise the basename of cwd. Compared against the
    // title with leading decoration stripped, so an app that prefixes its OSC
    // title with a progress spinner (Codex's "⠴ laban") doesn't slip a second
    // copy of the project name past the redundancy guard.
    let bareTitle = titleSansDecoration(title)
    if let repo = useful(metadata.workspace.repoName) {
      var folder = repo
      if let worktree = useful(metadata.workspace.worktreeName), worktree != repo {
        folder = "\(repo)@\(worktree)"
      }
      if folder != bareTitle { lines.append(truncateMid(folder)) }
    } else if let cwd = useful(metadata.workspace.cwd) {
      let folder = cwdDisplayName(cwd)
      if folder != bareTitle { lines.append(truncatePath(folder)) }
    }

    // Line 2: git branch (with dirty marker when known). Strip the
    // `worktrees/` prefix Claude Code's worktree script uses — when
    // working in `.claude/worktrees/foo`, the namespace is implicit. If
    // the cleaned branch name matches the folder line we already
    // rendered, drop it entirely; rendering "foo" twice on top of each
    // other isn't useful.
    if let raw = useful(metadata.workspace.branch) {
      var branch = raw
      for prefix in ["worktrees/", "worktree/"] where branch.hasPrefix(prefix) {
        branch = String(branch.dropFirst(prefix.count))
      }
      let dirty = metadata.workspace.isDirty ? "*" : ""
      let alreadyShown = lines.contains(branch) || lines.contains(branch + dirty)
      if !alreadyShown {
        lines.append(truncateMid(branch + dirty))
      }
    }

    // Line 3: foreground command detail — only when it adds signal beyond
    // the title. The raw executable path is usually noise; argv can reveal
    // the script or package target behind generic launchers like node.
    if let detail = foregroundCommandDetail(
      for: metadata.process,
      title: title,
      titleSource: titleSource
    ) {
      lines.append(truncateMid(detail))
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
    fallbackPosition: Int
  ) -> TabTitleMetadata {
    // displayTitle and titleSource are the only resolved fields stored on
    // TabTitleMetadata, and both come straight from titleChoice. Routing
    // through the full resolve() recomputed secondaryLine, breakdownLines,
    // and statusBadge — the split/join/trim string work the sidebar already
    // does for itself — purely to discard them. On busy tabs this ran on
    // every output tick; titleChoice alone yields the identical result.
    var next = metadata
    let choice = titleChoice(metadata, fallbackPosition: fallbackPosition)
    next.displayTitle = choice.title
    next.titleSource = choice.source
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
    // A program-set OSC title is the most specific live signal a tab has.
    // It used to be gated on a non-shell foreground process, but foreground
    // detection regularly reports the login shell while the title's owner is
    // alive (agent tabs especially), which demoted rich titles to the bare
    // folder name. Staleness is an ownership question — the synchronizer
    // clears a title once its owner process is gone — so a present title is
    // a current title and outranks workspace- and process-derived names.
    if let terminal = useful(metadata.terminalTitle) {
      return (terminal, .terminal)
    }
    if let repo = useful(metadata.workspace.repoName) {
      if let worktree = useful(metadata.workspace.worktreeName), worktree != repo {
        return ("\(repo)@\(worktree)", .repo)
      }
      return (repo, .repo)
    }
    if let process = useful(metadata.process.foregroundProcess)
      ?? executableName(metadata.process.foregroundArguments)
      ?? commandName(metadata.process.foregroundCommand),
      !isShellProcess(process)
    {
      return (process, .process)
    }
    if let cwd = useful(metadata.workspace.cwd) {
      return (cwdDisplayName(cwd), .cwd)
    }
    if let process = useful(metadata.process.foregroundProcess)
      ?? executableName(metadata.process.foregroundArguments)
      ?? commandName(metadata.process.foregroundCommand)
    {
      return (process, .process)
    }
    return ("Tab \(fallbackPosition)", .fallback)
  }

  private static func secondaryLine(
    for metadata: TabTitleMetadata,
    now: Date,
    lastActivity: Date?,
    title: String,
    titleSource: TabTitleSource
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

    if let detail = foregroundCommandDetail(
      for: metadata.process,
      title: title,
      titleSource: titleSource
    ) {
      parts.append(detail)
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
      if let age = compactAge(from: lastActivity, now: now) {
        parts.append(age)
      }
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " | ")
  }

  private static func statusBadge(for metadata: TabTitleMetadata) -> String? {
    if metadata.activityState == .waiting || metadata.agent.awaitingInput { return "!" }
    if metadata.activityState == .exited, let status = metadata.exitStatus, status != 0 {
      return "!"
    }
    if metadata.bellAttention { return "•" }
    if metadata.activityState == .unseenOutput || metadata.unseenOutput { return "*" }
    return nil
  }

  private static func useful(_ value: String?) -> String? {
    // Title metadata is sanitized at every ingestion boundary (the metadata
    // initializers and their `didSet` observers), so the render path only
    // needs to drop empty values rather than re-sanitize each field per frame.
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  /// A title with any leading decoration stripped — a progress spinner glyph
  /// and the spaces around it, e.g. Codex's active OSC 0 title "⠴ laban" ->
  /// "laban". Used only to decide whether a folder/repo info line merely
  /// repeats the title (so it can be dropped); never to change what's shown.
  /// The exact-match guard alone misses this: "laban" != "⠴ laban", so without
  /// it the project name renders twice — once in the title, once below.
  private static func titleSansDecoration(_ title: String) -> String {
    var view = Substring(title)
    while let first = view.unicodeScalars.first,
      !CharacterSet.alphanumerics.contains(first)
    {
      view = view.dropFirst()
    }
    guard !view.isEmpty else { return title }
    return String(view)
  }

  private static func pathTail(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.isEmpty { return "/" }
    return String(trimmed.split(separator: "/").last ?? Substring(trimmed))
  }

  /// Compact label for a working directory: basename only. Worktree paths
  /// like `~/wrk/laban/.claude/worktrees/foo` collapse to `foo`, which is
  /// the identifying part — exactly what fits in a 200 px sidebar column.
  /// `~` for the home directory itself.
  private static func cwdDisplayName(_ path: String) -> String {
    if let cached = cwdDisplayNameCache.object(forKey: path as NSString) {
      return cached as String
    }
    let standardized = (path as NSString).standardizingPath
    let displayName = standardized == standardizedHomePath ? "~" : pathTail(standardized)
    cwdDisplayNameCache.setObject(displayName as NSString, forKey: path as NSString)
    return displayName
  }

  private static let standardizedHomePath = (NSHomeDirectory() as NSString).standardizingPath

  private static let cwdDisplayNameCache: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 512
    return cache
  }()

  private static func commandName(_ command: String?) -> String? {
    guard let command = useful(command) else { return nil }
    let first = command.split(separator: " ").first.map(String.init) ?? command
    return pathTail(first)
  }

  private static func executableName(_ arguments: [String]?) -> String? {
    guard let first = arguments?.compactMap({ useful($0) }).first else { return nil }
    return pathTail(first)
  }

  private static func foregroundCommandDetail(
    for process: TabProcessMetadata,
    title: String,
    titleSource: TabTitleSource
  ) -> String? {
    if let arguments = process.foregroundArguments,
      let detail = commandDetail(arguments: arguments, title: title, titleSource: titleSource)
    {
      return detail
    }

    if let command = useful(process.foregroundCommand) {
      let commandArguments = command.split(separator: " ").map(String.init)
      if commandArguments.count > 1,
        let detail = commandDetail(
          arguments: commandArguments, title: title, titleSource: titleSource)
      {
        return detail
      }
      if let runnable = commandName(command), !isShellProcess(runnable) {
        return titleSource == .process && runnable == title ? nil : runnable
      }
    }

    if let processName = useful(process.foregroundProcess), !isShellProcess(processName) {
      let runnable = pathTail(processName)
      return titleSource == .process && runnable == title ? nil : runnable
    }

    return nil
  }

  private static func commandDetail(
    arguments rawArguments: [String],
    title: String,
    titleSource: TabTitleSource
  ) -> String? {
    let arguments = rawArguments.compactMap { useful($0) }
    guard let executableArgument = arguments.first else { return nil }
    let executable = pathTail(executableArgument)
    guard !isShellProcess(executable) else { return nil }

    let rest = Array(arguments.dropFirst())
    let titleMatchesExecutable = titleSource == .process && executable == title
    guard !rest.isEmpty else {
      return titleMatchesExecutable ? nil : executable
    }

    if executable == "node", let detail = nodeCommandDetail(rest) {
      return detail
    }

    let displayedRest = rest.map(commandArgumentDisplay)
    if titleMatchesExecutable {
      let detail = displayedRest.prefix(3).joined(separator: " ")
      return detail.isEmpty ? nil : detail
    }

    return ([executable] + displayedRest).prefix(4).joined(separator: " ")
  }

  private static func nodeCommandDetail(_ arguments: [String]) -> String? {
    guard let first = arguments.first else { return nil }
    if let runner = nodePackageRunnerName(first) {
      return ([runner] + arguments.dropFirst().map(commandArgumentDisplay)).prefix(4)
        .joined(separator: " ")
    }

    if let scriptIndex = arguments.firstIndex(where: isJavaScriptEntrypoint) {
      return arguments[scriptIndex...].prefix(3).map(commandArgumentDisplay).joined(separator: " ")
    }

    let nonFlagArguments = arguments.drop(while: { $0.hasPrefix("-") })
    let detail = nonFlagArguments.prefix(3).map(commandArgumentDisplay).joined(separator: " ")
    return detail.isEmpty ? nil : detail
  }

  private static func nodePackageRunnerName(_ script: String) -> String? {
    let lowerPath = script.lowercased()
    let basename = pathTail(lowerPath)
    switch basename {
    case "npm-cli.js":
      return "npm"
    case "pnpm.cjs", "pnpm.js":
      return "pnpm"
    case "yarn.js":
      return "yarn"
    default:
      if lowerPath.contains("/tsx/") { return "tsx" }
      return nil
    }
  }

  private static func isJavaScriptEntrypoint(_ argument: String) -> Bool {
    let lower = argument.lowercased()
    return [".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"].contains {
      lower.hasSuffix($0)
    }
  }

  private static func commandArgumentDisplay(_ argument: String) -> String {
    guard argument.hasPrefix("/") else { return argument }
    return pathTail(argument)
  }

  private static func isShellProcess(_ process: String) -> Bool {
    var name = pathTail(process).lowercased()
    // A login shell presents argv[0] as "-zsh" / "-bash" (the leading-dash
    // convention), so tolerate it — otherwise the login shell is mistaken for
    // a running program and surfaced as the tab's title/detail. Mirrors the
    // dash-tolerant shell-kind parsing in ShellIntegrationOverlay.
    if name.hasPrefix("-") { name.removeFirst() }
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
