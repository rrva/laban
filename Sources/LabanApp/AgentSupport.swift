import Foundation
import LabanCore

/// Per-agent capability table. Single source of truth for everything
/// agent-specific: the binary names the descendant detector watches
/// for, the resume command form (Claude uses a flag, Codex uses a
/// subcommand), and the session-id extractor that turns an open
/// `.jsonl` vnode path into a session identifier.
///
/// Adding a third agent later is a single entry — no detector
/// changes, no schema migration.
public struct AgentSupport {
  public let name: AgentName
  public let binaryBasenames: [String]
  public let resumeCommand: (String) -> String
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
    resumeCommand: @escaping (String) -> String,
    extractSessionId: @escaping (String) -> String?
  ) {
    self.name = name
    self.binaryBasenames = binaryBasenames
    self.resumeCommand = resumeCommand
    self.extractSessionId = extractSessionId
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
      resumeCommand: { id in "claude --resume \(id)" },
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
      resumeCommand: { id in "codex resume \(id)" },
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
    let escaped = NSRegularExpression.escapedPattern(for: prefix)
    let overridePattern =
      "^\(escaped)/projects/[^/]+/([0-9a-fA-F-]{36})\\.jsonl$"
    return Self.firstUUIDMatch(in: vnodePath, regex: overridePattern)
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
    let escaped = NSRegularExpression.escapedPattern(for: prefix)
    let overridePattern =
      "^\(escaped)/sessions/\\d{4}/\\d{2}/\\d{2}/rollout-[0-9T:\\-]+-([0-9a-fA-F-]{36})\\.jsonl$"
    return Self.firstUUIDMatch(in: vnodePath, regex: overridePattern)
  }

  /// Apply a regex with one capture group; the capture must be a
  /// UUID. Returns the lowercase UUID string on success.
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
