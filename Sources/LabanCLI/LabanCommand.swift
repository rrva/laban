import Foundation

enum LabanCommand: Equatable {
  case discover(json: Bool)
  case status(json: Bool)
  case health(json: Bool)
  case capabilities(json: Bool)
  case request(method: String, path: String, body: String?, json: Bool)
  case completions(shell: String)
  case installCLI(prefix: String?, dryRun: Bool)
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
    default:
      return .failure(.unknownCommand(command))
    }
  }
}
