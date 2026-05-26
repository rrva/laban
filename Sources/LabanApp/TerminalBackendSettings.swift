import Foundation
import LabanCore

enum TerminalBackendLaunchSource: Equatable {
  case commandLine
  case environment
  case legacyDisableFlag
  case userDefault
  case automatic

  var isOverride: Bool {
    switch self {
    case .commandLine, .environment, .legacyDisableFlag:
      return true
    case .userDefault, .automatic:
      return false
    }
  }
}

struct TerminalBackendLaunchConfiguration: Equatable {
  var backend: TerminalSessionBackend
  var source: TerminalBackendLaunchSource
}

enum TerminalBackendSettings {
  static let defaultsKey = "LabanTerminalSessionBackend"

  static func persisted(defaults: UserDefaults = .standard) -> TerminalSessionBackend? {
    guard let raw = defaults.string(forKey: defaultsKey), !raw.isEmpty else {
      return nil
    }
    return try? TerminalSessionBackend.parse(raw)
  }

  static func set(_ backend: TerminalSessionBackend, defaults: UserDefaults = .standard) {
    defaults.set(backend.rawValue, forKey: defaultsKey)
  }

  static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    defaults: UserDefaults = .standard,
    automaticBackend: TerminalSessionBackend
  ) throws -> TerminalBackendLaunchConfiguration {
    if let backend = try commandLineBackend(arguments: arguments) {
      return TerminalBackendLaunchConfiguration(backend: backend, source: .commandLine)
    }
    if let raw = environment["LABAN_TERMINAL_BACKEND"], !raw.isEmpty {
      return TerminalBackendLaunchConfiguration(
        backend: try TerminalSessionBackend.parse(raw),
        source: .environment)
    }
    if environment["LABAN_DISABLE_PRODUCT_LABAND"] == "1" {
      return TerminalBackendLaunchConfiguration(backend: .inProcess, source: .legacyDisableFlag)
    }
    if let backend = persisted(defaults: defaults) {
      return TerminalBackendLaunchConfiguration(backend: backend, source: .userDefault)
    }
    return TerminalBackendLaunchConfiguration(backend: automaticBackend, source: .automatic)
  }

  private static func commandLineBackend(arguments: [String]) throws -> TerminalSessionBackend? {
    var index = 1
    while index < arguments.count {
      let arg = arguments[index]
      switch arg {
      case "--local-sessions":
        return .inProcess
      case "--laband-sessions":
        return .laband
      case "--terminal-backend":
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
          throw TerminalSessionClientError.protocolError(
            "--terminal-backend requires in-process or laband")
        }
        return try TerminalSessionBackend.parse(arguments[valueIndex])
      default:
        if arg.hasPrefix("--terminal-backend=") {
          let value = String(arg.dropFirst("--terminal-backend=".count))
          return try TerminalSessionBackend.parse(value)
        }
      }
      index += 1
    }
    return nil
  }
}
