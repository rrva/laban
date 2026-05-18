import Foundation

/// Per-agent capability table. Single source of truth for everything
/// agent-specific: the binary names the descendant detector watches
/// for, the native resume adapter, and the session-id extractor that
/// turns an open `.jsonl` vnode path into a session identifier.
///
/// Adding a third agent later is a single entry — no detector
/// changes, no schema migration.
public struct AgentSupport {
  public let name: AgentName
  public let binaryBasenames: [String]
  public let resumeAdapter: any AgentResumeAdapter
  /// Given the absolute path of an open `.jsonl` file held by an
  /// agent process, return the session id if (and only if) the path
  /// matches the agent's known on-disk layout AND the extracted stem
  /// passes the agent's session-id shape check (currently UUID for
  /// both Claude and Codex). Returns nil for unrelated `.jsonl`
  /// files (configs, caches, telemetry) that the agent may have
  /// open — those must not be misidentified as the session log or
  /// the resume invocation will fail with "session not found."
  public let extractSessionId: (String) -> String?

  public init(
    name: AgentName,
    binaryBasenames: [String],
    resumeAdapter: any AgentResumeAdapter,
    extractSessionId: @escaping (String) -> String?
  ) {
    self.name = name
    self.binaryBasenames = binaryBasenames
    self.resumeAdapter = resumeAdapter
    self.extractSessionId = extractSessionId
  }

  public func resumeCommand(sessionId: String, context: AgentLaunchContext) -> String {
    resumeAdapter.resumeCommand(sessionId: sessionId, context: context)
  }

  public func resumeCommand(_ sessionId: String) -> String {
    resumeCommand(
      sessionId: sessionId,
      context: AgentLaunchContext(cwd: "", argv: [], env: [:]))
  }
}

public protocol AgentResumeAdapter {
  var name: AgentName { get }
  func resumeCommand(sessionId: String, context: AgentLaunchContext) -> String
}

public struct AgentLaunchContext: Equatable {
  public var cwd: String
  public var argv: [String]
  public var env: [String: String]

  public init(cwd: String, argv: [String], env: [String: String]) {
    self.cwd = cwd
    self.argv = argv
    self.env = env
  }
}

public enum ShellCommand {
  public static func render(_ args: [String]) -> String {
    args.map(quote).joined(separator: " ")
  }

  public static func quote(_ arg: String) -> String {
    if arg.isEmpty { return "''" }
    let safeScalars = CharacterSet(charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+-./:=,@%")
    if arg.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
      return arg
    }
    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public enum AgentEnvironmentSanitizer {
  private static let allowlist: Set<String> = [
    "TERM",
    "COLORTERM",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "CLAUDE_CONFIG_DIR",
    "CODEX_HOME",
  ]

  private static let secretNameFragments: [String] = [
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASS",
    "KEY",
    "AUTH",
    "COOKIE",
    "AWS_",
    "GITHUB_",
    "OPENAI_",
    "ANTHROPIC_",
  ]

  private static let secretValueFragments: [String] = [
    "TOKEN=",
    "SECRET=",
    "PASSWORD=",
    "PASS=",
    "KEY=",
    "AUTH=",
    "COOKIE=",
    "AWS_",
    "GITHUB_",
    "OPENAI_",
    "ANTHROPIC_",
  ]

  public static func sanitize(_ env: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    for (name, value) in env {
      guard allowlist.contains(name) else { continue }
      guard !looksSecretName(name) else { continue }
      guard !looksSecretValue(value) else { continue }
      result[name] = value
    }
    return result
  }

  public static func looksSecretName(_ name: String) -> Bool {
    let upper = name.uppercased()
    return secretNameFragments.contains { upper.contains($0) }
  }

  public static func looksSecretValue(_ value: String) -> Bool {
    let upper = value.uppercased()
    return secretValueFragments.contains { upper.contains($0) }
  }
}

public struct ClaudeResumeAdapter: AgentResumeAdapter {
  public let name: AgentName = .claude

  public init() {}

  public func resumeCommand(sessionId: String, context: AgentLaunchContext) -> String {
    ShellCommand.render(["claude", "--resume", sessionId] + preservedArguments(from: context.argv))
  }

  private func preservedArguments(from argv: [String]) -> [String] {
    let tokens = ResumeArgParser.dropProgramName(argv, basenames: ["claude"])
    var preserved: [String] = []
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      if token == "--" { break }

      if let value = ResumeArgParser.value(for: "--model", token: token, tokens: tokens, index: &i) {
        if !value.isEmpty { preserved += ["--model", value] }
        i += 1
        continue
      }
      if let value = ResumeArgParser.value(for: "--effort", token: token, tokens: tokens, index: &i) {
        if ["low", "medium", "high", "xhigh", "max"].contains(value) {
          preserved += ["--effort", value]
        }
        i += 1
        continue
      }
      if let value = ResumeArgParser.value(
        for: "--permission-mode", token: token, tokens: tokens, index: &i)
      {
        if ["default", "acceptEdits", "auto", "bypassPermissions", "dontAsk", "plan"].contains(
          value)
        {
          preserved += ["--permission-mode", value]
        }
        i += 1
        continue
      }
      if token == "--add-dir" {
        i += 1
        while i < tokens.count && !ResumeArgParser.isOption(tokens[i]) {
          if !tokens[i].isEmpty { preserved += ["--add-dir", tokens[i]] }
          i += 1
        }
        continue
      }
      if let value = ResumeArgParser.inlineValue(for: "--add-dir", token: token) {
        if !value.isEmpty { preserved += ["--add-dir", value] }
        i += 1
        continue
      }
      if Self.preserveWithoutValue.contains(token) {
        preserved.append(token)
        i += 1
        continue
      }
      if token == "--dangerously-skip-permissions"
        || token == "--allow-dangerously-skip-permissions"
      {
        preserved.append(token)
        i += 1
        continue
      }

      if Self.dropWithoutValue.contains(token)
        || token.hasPrefix("--worktree=")
        || token.hasPrefix("-w=")
      {
        i += 1
        continue
      }
      if Self.dropWithOptionalValue.contains(token) {
        ResumeArgParser.skipFollowingValue(tokens: tokens, index: &i)
        i += 1
        continue
      }
      if Self.dropWithRequiredValue.contains(token) {
        ResumeArgParser.skipFollowingValue(tokens: tokens, index: &i)
        i += 1
        continue
      }
      if token.hasPrefix("-") {
        if Self.knownValueOptions.contains(token) {
          ResumeArgParser.skipFollowingValue(tokens: tokens, index: &i)
        }
        i += 1
        continue
      }
      i += 1
    }
    return preserved
  }

  private static let dropWithoutValue: Set<String> = [
    "--fork-session",
    "-c",
    "--continue",
    "-p",
    "--print",
  ]

  private static let preserveWithoutValue: Set<String> = [
    "--bare",
    "--brief",
    "--chrome",
    "--ide",
    "--no-chrome",
    "--strict-mcp-config",
    "--verbose",
  ]

  private static let dropWithOptionalValue: Set<String> = [
    "-w",
    "--worktree",
    "-r",
    "--resume",
    "--tmux",
  ]

  private static let dropWithRequiredValue: Set<String> = [
    "--session-id"
  ]

  private static let knownValueOptions: Set<String> = [
    "--agent",
    "--agents",
    "--allowedTools",
    "--allowed-tools",
    "--append-system-prompt",
    "--betas",
    "-d",
    "--debug",
    "--debug-file",
    "--disallowedTools",
    "--disallowed-tools",
    "--fallback-model",
    "--file",
    "--from-pr",
    "--input-format",
    "--json-schema",
    "--max-budget-usd",
    "--mcp-config",
    "-n",
    "--name",
    "--output-format",
    "--plugin-dir",
    "--plugin-url",
    "--remote-control",
    "--remote-control-session-name-prefix",
    "--setting-sources",
    "--settings",
    "--system-prompt",
    "--tools",
  ]
}

public struct CodexResumeAdapter: AgentResumeAdapter {
  public let name: AgentName = .codex

  public init() {}

  public func resumeCommand(sessionId: String, context: AgentLaunchContext) -> String {
    var command = ["codex", "resume", sessionId]
    if !context.cwd.isEmpty {
      command += ["-C", context.cwd]
    }
    command += preservedArguments(from: context.argv)
    return ShellCommand.render(command)
  }

  private func preservedArguments(from argv: [String]) -> [String] {
    let tokens = ResumeArgParser.dropProgramName(argv, basenames: ["codex"])
    var preserved: [String] = []
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      if token == "--" { break }

      if let value = ResumeArgParser.value(
        for: "--model", short: "-m", token: token, tokens: tokens, index: &i)
      {
        if !value.isEmpty { preserved += ["--model", value] }
        i += 1
        continue
      }
      if let value = ResumeArgParser.value(
        for: "--profile", short: "-p", token: token, tokens: tokens, index: &i)
      {
        if !value.isEmpty { preserved += ["--profile", value] }
        i += 1
        continue
      }
      if let value = ResumeArgParser.value(
        for: "--sandbox", short: "-s", token: token, tokens: tokens, index: &i)
      {
        if ["read-only", "workspace-write", "danger-full-access"].contains(value) {
          preserved += ["--sandbox", value]
        }
        i += 1
        continue
      }
      if let value = ResumeArgParser.value(
        for: "--ask-for-approval", short: "-a", token: token, tokens: tokens, index: &i)
      {
        if ["untrusted", "on-request", "never"].contains(value) {
          preserved += ["--ask-for-approval", value]
        }
        i += 1
        continue
      }
      if let value = ResumeArgParser.value(
        for: "--add-dir", token: token, tokens: tokens, index: &i)
      {
        if !value.isEmpty { preserved += ["--add-dir", value] }
        i += 1
        continue
      }
      if token == "--search" || token == "--no-alt-screen" {
        preserved.append(token)
        i += 1
        continue
      }
      if token == "--dangerously-bypass-approvals-and-sandbox" {
        preserved.append(token)
        i += 1
        continue
      }

      if Self.dropWithoutValue.contains(token) {
        i += 1
        continue
      }
      if Self.dropWithValue.contains(token) {
        ResumeArgParser.skipFollowingValue(tokens: tokens, index: &i)
        i += 1
        continue
      }
      if token.hasPrefix("--remote=")
        || token.hasPrefix("--remote-auth-token-env=")
        || token.hasPrefix("--local-provider=")
        || token.hasPrefix("--sandbox=")
        || token.hasPrefix("--ask-for-approval=")
        || token.hasPrefix("--cd=")
        || token.hasPrefix("--config=")
      {
        i += 1
        continue
      }
      if Self.subcommands.contains(token) {
        i += 1
        continue
      }
      if token.hasPrefix("-") {
        if Self.knownValueOptions.contains(token) {
          ResumeArgParser.skipFollowingValue(tokens: tokens, index: &i)
        }
        i += 1
        continue
      }
      i += 1
    }
    return preserved
  }

  private static let subcommands: Set<String> = [
    "resume",
    "fork",
    "exec",
    "review",
  ]

  private static let dropWithoutValue: Set<String> = [
    "--last",
    "--all",
    "--include-non-interactive",
    "--oss",
  ]

  private static let dropWithValue: Set<String> = [
    "-C",
    "--cd",
    "-c",
    "--config",
    "--enable",
    "--disable",
    "--remote",
    "--remote-auth-token-env",
    "--local-provider",
    "-i",
    "--image",
  ]

  private static let knownValueOptions: Set<String> = dropWithValue
}

private enum ResumeArgParser {
  static func dropProgramName(_ argv: [String], basenames: Set<String>) -> [String] {
    guard let first = argv.first else { return [] }
    let basename = URL(fileURLWithPath: first).lastPathComponent
    if basenames.contains(basename) {
      return Array(argv.dropFirst())
    }
    return argv
  }

  static func isOption(_ token: String) -> Bool {
    token.hasPrefix("-") && token != "-"
  }

  static func inlineValue(for long: String, token: String) -> String? {
    let prefix = "\(long)="
    guard token.hasPrefix(prefix) else { return nil }
    return String(token.dropFirst(prefix.count))
  }

  static func value(
    for long: String,
    short: String? = nil,
    token: String,
    tokens: [String],
    index: inout Int
  ) -> String? {
    if let inline = inlineValue(for: long, token: token) {
      return inline
    }
    if token == long || token == short {
      guard index + 1 < tokens.count else { return nil }
      index += 1
      return tokens[index]
    }
    return nil
  }

  static func skipFollowingValue(tokens: [String], index: inout Int) {
    guard index + 1 < tokens.count else { return }
    guard !isOption(tokens[index + 1]) else { return }
    index += 1
  }
}

public enum AgentRegistry {
  /// Built-in agents. New agents append entries here.
  public static let supported: [AgentSupport] = [
    .claude(),
    .codex(),
  ]

  /// Look up a support entry by name.
  public static func entry(for name: AgentName) -> AgentSupport? {
    supported.first { $0.name == name }
  }

  /// Find the agent whose `binaryBasenames` contains the given
  /// executable basename. Returns nil for non-agent processes.
  public static func agent(forBinaryBasename basename: String) -> AgentSupport? {
    supported.first { $0.binaryBasenames.contains(basename) }
  }

  /// Find the agent for a process using both the executable path
  /// basename and argv[0]. Claude's native launcher execs a versioned
  /// binary such as `.../versions/2.1.143`, while argv[0] still
  /// presents the user-facing `claude` invocation.
  public static func agent(forBinaryBasename basename: String, arguments: [String]) -> AgentSupport? {
    if let support = agent(forBinaryBasename: basename) {
      return support
    }
    guard let first = arguments.first else { return nil }
    let invocationBasename = URL(fileURLWithPath: first).lastPathComponent
    return agent(forBinaryBasename: invocationBasename)
  }

  /// Union of every supported agent's binary basenames. The
  /// descendant detector matches against this set on every tick.
  public static var allBinaryBasenames: Set<String> {
    Set(supported.flatMap { $0.binaryBasenames })
  }
}

extension AgentSupport {

  /// Claude (`claude --resume <id>`). Session JSONLs live under
  /// `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. Honors a
  /// `CLAUDE_CONFIG_DIR` env override so the extractor still
  /// matches when a user has relocated the projects directory.
  public static func claude() -> AgentSupport {
    AgentSupport(
      name: .claude,
      binaryBasenames: ["claude"],
      resumeAdapter: ClaudeResumeAdapter(),
      extractSessionId: { vnodePath in
        Self.matchClaudeStem(vnodePath)
      }
    )
  }

  /// Codex (`codex resume <id>`). Session JSONLs live under
  /// `~/.codex/sessions/YYYY/MM/DD/rollout-{ISO-date}-{uuid}.jsonl`.
  /// The session id is the UUID embedded at the end of the filename,
  /// NOT the full filename stem (verified against the upstream
  /// `codex-rs/rollout/src/recorder.rs`). Honors `CODEX_HOME` for
  /// users who have relocated the sessions directory.
  public static func codex() -> AgentSupport {
    AgentSupport(
      name: .codex,
      binaryBasenames: ["codex"],
      resumeAdapter: CodexResumeAdapter(),
      extractSessionId: { vnodePath in
        Self.matchCodexStem(vnodePath)
      }
    )
  }

  // MARK: - Extractors

  /// Read `name` from Laban's own environment. Used by the
  /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` overrides — since the agent
  /// is a grandchild of Laban it inherits Laban's env, so Laban's
  /// values are the right source. Returned values are stripped of
  /// trailing slashes so the suffix matching below works
  /// uniformly.
  static func envOverride(_ name: String) -> String? {
    guard let raw = ProcessInfo.processInfo.environment[name],
      !raw.isEmpty
    else { return nil }
    if raw.hasSuffix("/") {
      return String(raw.dropLast())
    }
    return raw
  }

  static func matchClaudeStem(_ vnodePath: String) -> String? {
    // Default layout: `/.claude/projects/<some-dir>/<uuid>.jsonl`.
    let defaultPattern = #"(?:^|/)\.claude/projects/[^/]+/([0-9a-fA-F-]{36})\.jsonl$"#
    if let id = Self.firstUUIDMatch(in: vnodePath, regex: defaultPattern) {
      return id
    }
    // CLAUDE_CONFIG_DIR override: when set, claude puts JSONLs at
    // `$CLAUDE_CONFIG_DIR/projects/<dir>/<uuid>.jsonl`. Match an
    // absolute-prefix variant rooted at the override path.
    guard let prefix = envOverride("CLAUDE_CONFIG_DIR") else { return nil }
    return firstOverrideUUIDMatch(
      in: vnodePath,
      prefix: prefix,
      suffixPattern: #"/projects/[^/]+/([0-9a-fA-F-]{36})\.jsonl$"#)
  }

  static func matchCodexStem(_ vnodePath: String) -> String? {
    // Default layout:
    // `/.codex/sessions/YYYY/MM/DD/rollout-<ISO>-<uuid>.jsonl`
    let defaultPattern =
      #"(?:^|/)\.codex/sessions/\d{4}/\d{2}/\d{2}/rollout-[0-9T:\-]+-([0-9a-fA-F-]{36})\.jsonl$"#
    if let id = Self.firstUUIDMatch(in: vnodePath, regex: defaultPattern) {
      return id
    }
    // CODEX_HOME override: when set, codex puts rollouts at
    // `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-...-<uuid>.jsonl`.
    guard let prefix = envOverride("CODEX_HOME") else { return nil }
    return firstOverrideUUIDMatch(
      in: vnodePath,
      prefix: prefix,
      suffixPattern:
        #"/sessions/\d{4}/\d{2}/\d{2}/rollout-[0-9T:\-]+-([0-9a-fA-F-]{36})\.jsonl$"#)
  }

  /// Apply a regex with one capture group; the capture must be a
  /// UUID. Returns the lowercase UUID string on success.
  private static func firstOverrideUUIDMatch(
    in input: String,
    prefix: String,
    suffixPattern: String
  ) -> String? {
    for candidate in overridePrefixes(prefix) {
      let escaped = NSRegularExpression.escapedPattern(for: candidate)
      if let id = firstUUIDMatch(in: input, regex: "^\(escaped)\(suffixPattern)") {
        return id
      }
    }
    return nil
  }

  private static func overridePrefixes(_ prefix: String) -> [String] {
    let resolved = URL(fileURLWithPath: prefix)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    var prefixes = [prefix]
    if resolved != prefix {
      prefixes.append(resolved)
    }
    if prefix.hasPrefix("/var/") {
      prefixes.append("/private\(prefix)")
    }
    if prefix.hasPrefix("/private/var/") {
      prefixes.append(String(prefix.dropFirst("/private".count)))
    }
    return Array(Set(prefixes))
  }

  private static func firstUUIDMatch(in input: String, regex pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    guard let match = regex.firstMatch(in: input, options: [], range: range),
      match.numberOfRanges >= 2,
      let captureRange = Range(match.range(at: 1), in: input)
    else { return nil }
    let candidate = String(input[captureRange])
    return AgentSupport.isUUID(candidate) ? candidate.lowercased() : nil
  }

  static func isUUID(_ candidate: String) -> Bool {
    // Lightweight check matching `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
    guard candidate.count == 36 else { return false }
    let parts = candidate.split(separator: "-")
    guard parts.count == 5 else { return false }
    let expected = [8, 4, 4, 4, 12]
    for (i, part) in parts.enumerated() {
      if part.count != expected[i] { return false }
      if !part.allSatisfy({ $0.isHexDigit }) { return false }
    }
    return true
  }
}
