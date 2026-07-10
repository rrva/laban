import Foundation

enum LabanCommand: Equatable {
  case discover(json: Bool)
  case status(json: Bool)
  case health(json: Bool)
  case capabilities(json: Bool)
  case request(method: String, path: String, body: String?, json: Bool)
  case completions(shell: String)
  case installCLI(prefix: String?, dryRun: Bool)
  case agentRun(command: [String])
  case sessionState(json: Bool)
  case sessionRequest(method: String, path: String, body: String?, json: Bool)
  case sessionScroll(rows: Int, json: Bool)
  case sessionProxy
  case sessionCurrent(json: Bool)
  case sessionGetText(source: String, startLine: Int?, endLine: Int?, maxLines: Int?, json: Bool)
  case context(json: Bool, maxLines: Int)
  case propose(purpose: String, command: [String])
  case help
}

enum LabanArgumentError: Error, Equatable {
  case unknownCommand(String)
  case missingArgument(String)
}

struct LabanArgumentParser {
  static func parse(_ arguments: [String]) -> Result<LabanCommand, LabanArgumentError> {
    var args = Array(arguments)
    guard !args.isEmpty else { return .success(.help) }

    let command = args.removeFirst()
    if command == "--help" || command == "-h" {
      return .success(.help)
    }

    // `agent run -- ...` and `propose --purpose ... -- ...` have their own
    // parsing rules and must preserve every word after the `--` separator.
    switch command {
    case "agent":
      return parseAgent(args: args)
    case "propose":
      return parsePropose(args: args)
    default:
      break
    }

    var json = false
    var dryRun = false
    var body: String?
    var prefix: String?

    var i = 0
    while i < args.count {
      let arg = args[i]
      switch arg {
      case "--json":
        json = true
        args.remove(at: i)
      case "--dry-run":
        dryRun = true
        args.remove(at: i)
      case "--body":
        args.remove(at: i)
        guard i < args.count else {
          return .failure(.missingArgument("--body"))
        }
        body = args[i]
        args.remove(at: i)
      case let arg where arg.hasPrefix("--body="):
        body = String(arg.dropFirst("--body=".count))
        args.remove(at: i)
      case "--prefix":
        args.remove(at: i)
        guard i < args.count else {
          return .failure(.missingArgument("--prefix"))
        }
        prefix = args[i]
        args.remove(at: i)
      case let arg where arg.hasPrefix("--prefix="):
        prefix = String(arg.dropFirst("--prefix=".count))
        args.remove(at: i)
      case "--help", "-h":
        return .success(.help)
      default:
        i += 1
      }
    }

    switch command {
    case "discover":
      return .success(.discover(json: json))
    case "status":
      return .success(.status(json: json))
    case "health":
      return .success(.health(json: json))
    case "capabilities":
      return .success(.capabilities(json: json))
    case "request":
      guard args.count >= 2 else {
        return .failure(.missingArgument("METHOD PATH"))
      }
      return .success(.request(method: args[0], path: args[1], body: body, json: json))
    case "completions":
      guard let shell = args.first else {
        return .failure(.missingArgument("SHELL"))
      }
      return .success(.completions(shell: shell))
    case "install-cli":
      return .success(.installCLI(prefix: prefix, dryRun: dryRun))
    case "help":
      return .success(.help)
    case "session":
      return parseSession(args: args, json: json, body: body)
    case "context":
      return parseContext(args: args, json: json)
    default:
      return .failure(.unknownCommand(command))
    }
  }

  // MARK: - Subcommand parsers

  private static func parseAgent(
    args: [String]
  ) -> Result<LabanCommand, LabanArgumentError> {
    guard args.first == "run" else {
      return .failure(.unknownCommand("agent \(args.first ?? "")"))
    }
    let rest = Array(args.dropFirst())
    guard let separator = rest.firstIndex(of: "--") else {
      return .failure(.missingArgument("-- COMMAND"))
    }
    let command = Array(rest[(rest.index(after: separator))...])
    guard !command.isEmpty else {
      return .failure(.missingArgument("COMMAND"))
    }
    return .success(.agentRun(command: command))
  }

  private static func parseSession(
    args: [String],
    json: Bool,
    body: String?
  ) -> Result<LabanCommand, LabanArgumentError> {
    guard let subcommand = args.first else {
      return .failure(.missingArgument("session subcommand"))
    }
    let rest = Array(args.dropFirst())
    switch subcommand {
    case "state":
      return .success(.sessionState(json: json))
    case "request":
      guard rest.count >= 2 else {
        return .failure(.missingArgument("METHOD PATH"))
      }
      return .success(
        .sessionRequest(
          method: rest[0], path: rest[1], body: body, json: json))
    case "scroll":
      let (rows, remaining) = extractIntegerOption(
        named: "--rows",
        from: rest)
      guard let rows else {
        return .failure(.missingArgument("--rows"))
      }
      guard remaining.isEmpty else {
        return .failure(.unknownCommand("session scroll \(remaining.joined(separator: " "))"))
      }
      return .success(.sessionScroll(rows: rows, json: json))
    case "proxy":
      return .success(.sessionProxy)
    case "current":
      return .success(.sessionCurrent(json: json))
    case "get-text":
      return parseGetText(args: rest, json: json)
    default:
      return .failure(.unknownCommand("session \(subcommand)"))
    }
  }

  private static func parseGetText(
    args: [String],
    json: Bool
  ) -> Result<LabanCommand, LabanArgumentError> {
    var rest = args
    var source = "screen"
    var sawScreen = false
    var sawScrollback = false
    if let idx = rest.firstIndex(of: "--screen") {
      sawScreen = true
      rest.remove(at: idx)
    }
    if let idx = rest.firstIndex(of: "--scrollback") {
      sawScrollback = true
      rest.remove(at: idx)
    }
    guard !(sawScreen && sawScrollback) else {
      return .failure(.unknownCommand("session get-text --screen --scrollback"))
    }
    if sawScrollback { source = "scrollback" }

    let (startLine, afterStart) = extractIntegerOption(named: "--start-line", from: rest)
    rest = afterStart
    let (endLine, afterEnd) = extractIntegerOption(named: "--end-line", from: rest)
    rest = afterEnd
    let (maxLines, afterMax) = extractIntegerOption(named: "--max-lines", from: rest)
    rest = afterMax

    guard rest.isEmpty else {
      return .failure(.unknownCommand("session get-text \(rest.joined(separator: " "))"))
    }

    return .success(
      .sessionGetText(
        source: source,
        startLine: startLine,
        endLine: endLine,
        maxLines: maxLines,
        json: json))
  }

  private static func parseContext(
    args: [String],
    json: Bool
  ) -> Result<LabanCommand, LabanArgumentError> {
    let (maxLines, remaining) = extractIntegerOption(named: "--max-lines", from: args)
    guard remaining.isEmpty else {
      return .failure(.unknownCommand("context \(remaining.joined(separator: " "))"))
    }
    return .success(.context(json: json, maxLines: maxLines ?? 40))
  }

  private static func parsePropose(
    args: [String]
  ) -> Result<LabanCommand, LabanArgumentError> {
    guard let separator = args.firstIndex(of: "--") else {
      return .failure(.missingArgument("-- COMMAND"))
    }

    let optionPart = Array(args[..<separator])
    let commandPart = Array(args[(args.index(after: separator))...])
    guard !commandPart.isEmpty else {
      return .failure(.missingArgument("COMMAND"))
    }

    let purpose: String
    if let idx = optionPart.firstIndex(of: "--purpose") {
      let valueIndex = optionPart.index(after: idx)
      guard valueIndex < optionPart.count else {
        return .failure(.missingArgument("--purpose"))
      }
      purpose = optionPart[valueIndex]
    } else if let idx = optionPart.firstIndex(where: { $0.hasPrefix("--purpose=") }) {
      purpose = String(optionPart[idx].dropFirst("--purpose=".count))
    } else {
      return .failure(.missingArgument("--purpose"))
    }

    return .success(.propose(purpose: purpose, command: commandPart))
  }

  // MARK: - Helpers

  private static func extractIntegerOption(
    named option: String,
    from args: [String]
  ) -> (value: Int?, remaining: [String]) {
    var rest = args
    if let idx = rest.firstIndex(of: option) {
      rest.remove(at: idx)
      guard idx < rest.count,
        let value = Int(rest[idx])
      else {
        return (nil, rest)
      }
      rest.remove(at: idx)
      return (value, rest)
    }
    if let idx = rest.firstIndex(where: { $0.hasPrefix("\(option)=") }) {
      let arg = rest[idx]
      let raw = String(arg.dropFirst(option.count + 1))
      rest.remove(at: idx)
      return (Int(raw), rest)
    }
    return (nil, rest)
  }
}
