import Darwin
import Foundation
import LabanCore

/// Configuration for launching the agent child from the broker. This is separate
/// from `Process` so the launch can be unit-tested without mutating process
/// state and so the broker can use `posix_spawnp` for `$PATH` lookup.
struct ChildLaunchConfiguration: Equatable {
  let argv0: String
  let arguments: [String]
  let environment: [String: String]
}

enum ChildLauncherError: Error, Equatable {
  case emptyCommand
  case spawnFailed(Int32)
}

extension ChildLauncherError: CustomStringConvertible {
  var description: String {
    switch self {
    case .emptyCommand:
      return "--control-attach-run requires a command after --"
    case .spawnFailed(let code):
      return "posix_spawnp failed with errno \(code)"
    }
  }
}

/// A minimal POSIX child launcher used by `laban-agent --control-attach-run`.
///
/// - Uses `posix_spawnp` so command names like `env`, `git`, or `claude` are
///   resolved against `$PATH`.
/// - Puts the child in a new process group so signal forwarding can target the
///   whole tree.
/// - Inherits stdin/stdout/stderr by default; callers may pass file actions for
///   tests or redirection.
enum ChildLauncher {
  /// Builds the child environment and argv without mutating process state.
  static func prepareConfiguration(
    command: [String],
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    agentControlURL: String
  ) throws -> ChildLaunchConfiguration {
    guard let argv0 = command.first, !argv0.isEmpty else {
      throw ChildLauncherError.emptyCommand
    }

    var environment = inheritedEnvironment
    environment[ControlEnvironmentKeys.agentControlURL] = agentControlURL
    // The child must not inherit the one-shot C14 bootstrap or the opt-in flag.
    environment.removeValue(forKey: ControlEnvironmentKeys.sessionAttach)
    environment.removeValue(forKey: ControlEnvironmentKeys.attachEnvOptIn)
    // LABAN_CONTROL_URL is preserved so descendants can still reach the app
    // control plane for discovery/health if they choose to.

    return ChildLaunchConfiguration(
      argv0: argv0,
      arguments: Array(command.dropFirst()),
      environment: environment)
  }

  /// Derives the broker exit status from a `waitpid` result. This is a pure
  /// helper so unit tests can cover normal exit, signal death, and wait failure.
  static func exitStatus(waitResult: pid_t, status: Int32) -> Int32 {
    guard waitResult != -1 else { return 1 }
    if status & 0x7f == 0 {
      return (status >> 8) & 0xff
    }
    return 128 + (status & 0x7f)
  }

  /// Spawns the configured command and returns its pid. The caller is responsible
  /// for waiting on the returned pid.
  static func launch(
    _ configuration: ChildLaunchConfiguration,
    fileActions: posix_spawn_file_actions_t? = nil
  ) throws -> pid_t {
    var pid: pid_t = 0

    var argv: [UnsafeMutablePointer<CChar>?] = [
      configuration.argv0.withCString { strdup($0) }
    ]
    argv.append(
      contentsOf: configuration.arguments.map { arg in
        arg.withCString { strdup($0) }
      })
    argv.append(nil)

    let envArray = configuration.environment.map { "\($0)=\($1)" }
    var envp: [UnsafeMutablePointer<CChar>?] = envArray.map { pair in
      pair.withCString { strdup($0) }
    }
    envp.append(nil)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }

    let flags: Int16 = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    posix_spawnattr_setflags(&attr, flags)
    posix_spawnattr_setpgroup(&attr, 0)

    // POSIX_SPAWN_CLOEXEC_DEFAULT closes every fd not explicitly preserved by
    // file actions. In production we preserve stdin/stdout/stderr; tests may
    // supply their own file actions (e.g. to capture stdout) and are responsible
    // for preserving any other fds they need.
    var actions: posix_spawn_file_actions_t? = fileActions
    if actions == nil {
      posix_spawn_file_actions_init(&actions)
      posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO)
      posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDOUT_FILENO)
      posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO)
    }
    defer {
      if fileActions == nil {
        posix_spawn_file_actions_destroy(&actions)
      }
    }

    let result = withUnsafePointer(to: &actions) { actionsPtr in
      withUnsafePointer(to: &attr) { attrPtr in
        configuration.argv0.withCString { exe in
          posix_spawnp(&pid, exe, actionsPtr, attrPtr, argv, envp)
        }
      }
    }

    for ptr in argv { free(ptr) }
    for ptr in envp { free(ptr) }

    guard result == 0 else {
      throw ChildLauncherError.spawnFailed(result)
    }
    return pid
  }
}
