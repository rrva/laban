import Darwin
import Foundation
import LabanControl
import LabanCore

enum AgentLauncherError: Error, Equatable, CustomStringConvertible {
  case missingControlURL
  case missingSessionAttach
  case emptyCommand

  var description: String {
    switch self {
    case .missingControlURL:
      return "\(ControlEnvironmentKeys.controlURL) is not set"
    case .missingSessionAttach:
      return "\(ControlEnvironmentKeys.sessionAttach) is not set"
    case .emptyCommand:
      return "agent run requires a command after --"
    }
  }
}

enum AgentLauncher {
  /// Validates the environment, resolves the sibling `laban-agent` executable,
  /// and process-replaces the current `laban` process with it. Never returns on
  /// success.
  static func invoke(command: [String]) -> Never {
    do {
      let invocation = try prepareInvocation(command: command)
      exec(invocation: invocation)
    } catch let error as AgentLauncherError {
      let stderr = FileHandle(fileDescriptor: STDERR_FILENO)
      let message = """
        laban: agent run requires an eligible agent-attached Laban session \
        (\(error))
        """
      if let data = (message + "\n").data(using: .utf8) {
        stderr.write(data)
      }
      exit(3)
    } catch {
      let stderr = FileHandle(fileDescriptor: STDERR_FILENO)
      if let data = ("laban: agent run failed: \(error)\n").data(using: .utf8) {
        stderr.write(data)
      }
      exit(6)
    }
  }

  /// Returns the resolved helper path, argv, and environment for `execve`.
  /// This is the testable core of `invoke`; it never mutates process state.
  static func prepareInvocation(
    command: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    labanExecutablePath: String = liveLabanExecutablePath()
  ) throws -> (path: String, argv: [String], env: [String: String]) {
    guard !command.isEmpty else {
      throw AgentLauncherError.emptyCommand
    }
    guard environment[ControlEnvironmentKeys.controlURL] != nil else {
      throw AgentLauncherError.missingControlURL
    }
    guard environment[ControlEnvironmentKeys.sessionAttach] != nil else {
      throw AgentLauncherError.missingSessionAttach
    }

    let agentPath = siblingAgentPath(forLabanPath: labanExecutablePath)
    var argv: [String] = [
      "laban-agent",
      "--control-attach",
      "--control-attach-serve-cli",
      "--control-attach-run",
      "--",
    ]
    argv.append(contentsOf: command)

    return (path: agentPath, argv: argv, env: environment)
  }

  /// Resolves `.../laban-agent` from the realpath of the running `laban`
  /// executable. Never searches `$PATH`.
  static func siblingAgentPath(forLabanPath labanPath: String) -> String {
    let url = URL(fileURLWithPath: labanPath)
    let directory = url.deletingLastPathComponent()
    return directory.appendingPathComponent("laban-agent").path
  }

  /// Returns the realpath of the running `laban` executable using the kernel's
  /// view of the executable, not `argv[0]`.
  static func liveLabanExecutablePath() -> String {
    var size = UInt32(0)
    _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else {
      return CommandLine.arguments[0]
    }
    let url = URL(fileURLWithPath: String(cString: path))
    return url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  // MARK: - Private

  private static func exec(invocation: (path: String, argv: [String], env: [String: String]))
    -> Never
  {
    let pathChars = invocation.path.withCString { strdup($0) }
    var argvChars: [UnsafeMutablePointer<CChar>?] = invocation.argv.map {
      $0.withCString { strdup($0) }
    }
    argvChars.append(nil)

    let envArray = invocation.env.map { "\($0)=\($1)" }
    var envChars: [UnsafeMutablePointer<CChar>?] = envArray.map {
      $0.withCString { strdup($0) }
    }
    envChars.append(nil)

    Darwin.execve(pathChars, argvChars, envChars)

    // execve only returns on error.
    let stderr = FileHandle(fileDescriptor: STDERR_FILENO)
    let message = "laban: failed to exec \(invocation.path): \(errno)\n"
    if let data = message.data(using: .utf8) { stderr.write(data) }
    exit(6)
  }
}
