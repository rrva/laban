import Darwin
import Foundation

/// Resolves the user's login shell the same way the C session layer
/// does (`Sources/LabanTerminalCore/session_lifecycle.c`): the `SHELL`
/// environment variable wins, then the passwd entry, then `/bin/sh`.
/// Kept in sync deliberately so the shell Laban *injects* a resume
/// command into is the same shell it would otherwise have launched.
public enum LoginShell {
  public static func resolvePath(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    if let shell = environment["SHELL"], !shell.isEmpty {
      return shell
    }
    if let pw = getpwuid(getuid()), let raw = pw.pointee.pw_shell {
      let shell = String(cString: raw)
      if !shell.isEmpty {
        return shell
      }
    }
    return "/bin/sh"
  }
}

/// Turns an agent resume command (e.g. `command claude --resume <id>`)
/// into the argv that launches it as the restored tab's shell process:
///
///   `<shell> -l -i -c '<command>; exec <shell> -l -i'`
///
/// `-l` runs a *login* shell and `-i` an *interactive* one — the same
/// combination a normal Laban tab gets (its shell is spawned with an
/// argv[0] of `-zsh`, which is how a shell is told it is a login shell).
/// This matters on macOS, where users commonly set PATH and similar in
/// login-only files such as `.zprofile`; a non-login `-i -c` shell would
/// miss them and could fail to find `claude`/`codex` even though the old
/// typed-into-the-login-shell path found it. `-c` runs the resume
/// command directly, so nothing is typed into a live prompt and there is
/// no command echo to clean up. The trailing `exec <shell> -l -i`
/// replaces the process with a fresh login+interactive shell once the
/// agent exits, leaving the user at a normal prompt — matching the
/// pre-injection behavior where the agent ran inside an already-running
/// login shell.
///
/// `zsh`, `bash`, and `fish` all accept `-l -i -c '...'`, treat `;` as a
/// statement separator, and provide `exec`, so the same shape works for
/// each.
public struct RestoreShellInjection: Equatable {
  public let shellPath: String
  public let command: String

  public init(command: String, shellPath: String = LoginShell.resolvePath()) {
    self.command = command
    self.shellPath = shellPath
  }

  /// The shell payload passed to `-c`: run the resume command, then
  /// drop to a login+interactive shell regardless of how it exited.
  public var payload: String {
    "\(command); exec \(ShellCommand.quote(shellPath)) -l -i"
  }

  /// The full NULL-terminated-on-exec argv. `argv[0]` is the shell path
  /// with no login `-` prefix; login+interactive behavior comes from the
  /// explicit `-l` and `-i` flags.
  public var argv: [String] {
    [shellPath, "-l", "-i", "-c", payload]
  }
}

extension RestoreLaunchInstruction {
  /// The shell injection to spawn the restored tab with, or `nil` when
  /// restore should launch a plain login shell. Only `.executeNow`
  /// (agent was running at quit) maps to an injection; `.prefillPrompt`
  /// cannot — `-c` runs immediately and cannot sit at a prompt — so it
  /// stays a post-spawn typed-into-PTY write.
  public var spawnInjection: RestoreShellInjection? {
    guard case .executeNow(let command) = self else { return nil }
    return RestoreShellInjection(command: command)
  }
}
