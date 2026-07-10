import Foundation

/// How a CLI command maps onto `IntentCatalog`. Commands backed by a fixed
/// route name the exact catalog intent id(s) they call, so a drift test can
/// confirm each id still exists in `IntentCatalog.all`. `.rawEscape` commands
/// forward a caller-specified method and path and are intentionally not
/// pinned to one intent. `.clientOnly` commands never reach the control
/// plane at all.
enum CLICatalogBacking: Equatable {
  case intent(String)
  case intents([String])
  case rawEscape
  case clientOnly
}

/// Maps every `LabanCommand` case, by stable label, to its catalog backing.
/// This table exists because the CLI is handwritten for ergonomic command
/// grouping rather than generated 1:1 from `IntentCatalog` (see the Decision
/// Log in `execplans/active/agent-control-production-broker-and-cli.md`), so
/// drift between the two is caught by a test instead of by construction.
enum LabanCLICatalog {
  static let commandBacking: [String: CLICatalogBacking] = [
    "discover": .intent("debug.discovery"),
    "status": .intent("app.state"),
    "health": .intent("debug.health"),
    "capabilities": .intent("debug.capabilities"),
    "request": .rawEscape,
    "completions": .clientOnly,
    "install-cli": .clientOnly,
    "agent run": .clientOnly,
    "session state": .intent("app.state"),
    "session request": .rawEscape,
    "session scroll": .intent("terminal.scrollViewport"),
    "session proxy": .rawEscape,
    "session current": .intents(["session.detail", "shellIntegration.state"]),
    "session get-text": .intent("terminal.getText"),
    "context": .intents(["session.detail", "shellIntegration.state", "terminal.getText"]),
    "wait prompt": .intent("shellIntegration.state"),
    "wait command-finished": .intent("shellIntegration.state"),
    "propose": .intent("command.propose"),
    "help": .clientOnly,
  ]

  /// Stable label for a command case, used to key `commandBacking`. This
  /// switch is exhaustive on purpose: the compiler fails the build if a new
  /// `LabanCommand` case is added without a case here, forcing whoever adds
  /// the command to also decide its catalog backing.
  static func label(for command: LabanCommand) -> String {
    switch command {
    case .discover: return "discover"
    case .status: return "status"
    case .health: return "health"
    case .capabilities: return "capabilities"
    case .request: return "request"
    case .completions: return "completions"
    case .installCLI: return "install-cli"
    case .agentRun: return "agent run"
    case .sessionState: return "session state"
    case .sessionRequest: return "session request"
    case .sessionScroll: return "session scroll"
    case .sessionProxy: return "session proxy"
    case .sessionCurrent: return "session current"
    case .sessionGetText: return "session get-text"
    case .context: return "context"
    case .waitPrompt: return "wait prompt"
    case .waitCommandFinished: return "wait command-finished"
    case .propose: return "propose"
    case .help: return "help"
    }
  }

  /// One representative instance of every `LabanCommand` case, used only so
  /// the drift test can iterate "one of every case." Associated-value
  /// contents are arbitrary placeholders; only the case matters here.
  static let oneOfEachCommand: [LabanCommand] = [
    .discover(json: false),
    .status(json: false),
    .health(json: false),
    .capabilities(json: false),
    .request(method: "GET", path: "/debug/state", body: nil, json: false),
    .completions(shell: "zsh"),
    .installCLI(prefix: nil, dryRun: false),
    .agentRun(command: ["true"]),
    .sessionState(json: false),
    .sessionRequest(method: "GET", path: "/debug/state", body: nil, json: false),
    .sessionScroll(rows: 0, json: false),
    .sessionProxy,
    .sessionCurrent(json: false),
    .sessionGetText(source: "screen", startLine: nil, endLine: nil, maxLines: nil, json: false),
    .context(json: false, maxLines: 40),
    .waitPrompt(timeoutSeconds: 30, json: false),
    .waitCommandFinished(timeoutSeconds: 30, json: false),
    .propose(purpose: "test", command: ["true"]),
    .help,
  ]
}
