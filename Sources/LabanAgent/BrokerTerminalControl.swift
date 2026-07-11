import Darwin
import Foundation

/// Job-control handoff for the broker's interactive child.
///
/// `laban agent run -- <agent>` spawns the agent into its own process group
/// (`POSIX_SPAWN_SETPGROUP`) so the broker can signal the whole subtree. But a
/// fresh process group is a *background* group for the controlling terminal:
/// the moment an interactive child (e.g. `claude`) reads the tty it takes
/// `SIGTTIN` and stops (process state `T`), which looks like "the agent ran but
/// produced no output and never took input". A shell avoids this by handing the
/// terminal's foreground to the child's group; the broker must do the same.
enum BrokerTerminalControl {
  /// Give the controlling terminal's foreground process group to `pgid`.
  ///
  /// Returns `false` and does nothing when `ttyFD` is not a terminal, so the
  /// non-interactive path (`laban agent run` under CI, pipes, `laban-agent`
  /// serve mode) is unchanged. `SIGTTOU` is ignored across the `tcsetpgrp`
  /// call so the handoff is safe even if the broker is not itself the current
  /// foreground group. A `SIGCONT` is sent to the target group afterward to
  /// resume the child if it already stopped on `SIGTTIN` in the small window
  /// between spawn and this call.
  @discardableResult
  static func takeForeground(pgid: pid_t, ttyFD: Int32 = STDIN_FILENO) -> Bool {
    guard isatty(ttyFD) != 0 else { return false }
    let previous = signal(SIGTTOU, SIG_IGN)
    defer { signal(SIGTTOU, previous) }
    guard tcsetpgrp(ttyFD, pgid) == 0 else { return false }
    _ = killpg(pgid, SIGCONT)
    return true
  }

  /// Reclaim the controlling terminal's foreground for the broker's own group,
  /// called when the child exits so the launching shell inherits a clean
  /// terminal state. No-op off a tty.
  static func reclaimForeground(ttyFD: Int32 = STDIN_FILENO) {
    guard isatty(ttyFD) != 0 else { return }
    let previous = signal(SIGTTOU, SIG_IGN)
    defer { signal(SIGTTOU, previous) }
    _ = tcsetpgrp(ttyFD, getpgrp())
  }
}
