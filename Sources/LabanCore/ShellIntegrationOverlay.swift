import Foundation

/// Generates a shell rc-overlay that makes the user's shell emit OSC 133
/// ("semantic prompt") markers without the user editing their dotfiles. See
/// `docs/product/spec.md` §7 and the parser side in `ShellIntegrationState`.
///
/// The overlay is a directory of startup files Laban writes. The shell is
/// pointed at it with an environment variable (`ZDOTDIR` for zsh); those
/// files source the user's *real* startup files and then install a
/// `precmd`/`preexec` snippet that prints the markers.
///
/// Milestone 2 implements zsh only. bash and fish (different overlay
/// strategies) are Milestone 3; `install` returns no overrides for them, so
/// the shell launches exactly as before.
public enum ShellIntegrationOverlay {
  public enum Shell: Equatable {
    case zsh
    case bash
    case fish
    case other

    /// Classify a shell by the basename of its executable path
    /// (`/bin/zsh` -> `.zsh`). Login shells spawn with an argv[0] of
    /// `-zsh`, so a leading dash is tolerated.
    public static func classify(path: String) -> Shell {
      var name = (path as NSString).lastPathComponent
      if name.hasPrefix("-") { name.removeFirst() }
      switch name {
      case "zsh": return .zsh
      case "bash": return .bash
      case "fish": return .fish
      default: return .other
      }
    }
  }

  /// The OSC 133 hook script sourced by the zsh overlay. Emits:
  /// - `A` (fresh prompt) on every `precmd`;
  /// - `D;<exit>` for the just-finished command, before the next prompt's A;
  /// - `C` (command started) on `preexec`.
  ///
  /// `B` (prompt-end / input-start) is intentionally omitted: emitting it
  /// reliably requires surgery on `PS1`, and `ShellIntegrationState` already
  /// reaches the `atPrompt` phase from `A`, so `B` adds no phase the UI
  /// needs. The guard variable makes re-sourcing a no-op.
  public static let zshHookScript = """
    # Laban OSC 133 shell integration (zsh). Auto-generated; do not edit.
    if [[ -n "${LABAN_SHELL_INTEGRATION-}" ]]; then
      return 0 2>/dev/null
    fi
    export LABAN_SHELL_INTEGRATION=1
    autoload -Uz add-zsh-hook
    typeset -g _laban_osc133_running=""
    _laban_osc133_precmd() {
      local exit=$?
      if [[ -n "$_laban_osc133_running" ]]; then
        printf '\\033]133;D;%d\\007' "$exit"
        _laban_osc133_running=""
      fi
      printf '\\033]133;A\\007'
    }
    _laban_osc133_preexec() {
      printf '\\033]133;C\\007'
      _laban_osc133_running=1
    }
    add-zsh-hook precmd _laban_osc133_precmd
    add-zsh-hook preexec _laban_osc133_preexec
    """

  /// The overlay `.zshenv`. zsh always sources `$ZDOTDIR/.zshenv` first; this
  /// one restores the user's real `ZDOTDIR` (so the rest of startup and any
  /// child shells use the user's own config), sources the user's real
  /// `.zshenv`, then installs Laban's hooks. `hookScriptPath` is the absolute
  /// path of the file holding `zshHookScript`.
  public static func zshEnvFile(hookScriptPath: String) -> String {
    let quotedHook = shellSingleQuote(hookScriptPath)
    return """
      # Laban shell integration overlay (zsh). Auto-generated; do not edit.
      if [[ -n "${LABAN_REAL_ZDOTDIR-}" ]]; then
        export ZDOTDIR="$LABAN_REAL_ZDOTDIR"
      else
        unset ZDOTDIR
      fi
      if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
        source "${ZDOTDIR:-$HOME}/.zshenv"
      fi
      source \(quotedHook)
      """
  }

  /// Write the overlay for `shellPath` under `baseDirectory` and return the
  /// environment overrides that activate it. Returns an empty dictionary for
  /// shells without an overlay yet (bash, fish, other), so the caller can
  /// pass the result through unconditionally.
  ///
  /// `environment` is the environment the shell would otherwise launch with;
  /// the user's real `ZDOTDIR` (or absence of one) is read from it.
  /// Idempotent: re-writing the same `baseDirectory` overwrites the files.
  @discardableResult
  public static func install(
    shellPath: String,
    baseDirectory: URL,
    environment: [String: String]
  ) throws -> [String: String] {
    guard Shell.classify(path: shellPath) == .zsh else { return [:] }

    let overlayDir = baseDirectory.appendingPathComponent("zsh", isDirectory: true)
    try FileManager.default.createDirectory(
      at: overlayDir, withIntermediateDirectories: true)

    let hookPath = overlayDir.appendingPathComponent("laban-integration.zsh")
    try zshHookScript.write(to: hookPath, atomically: true, encoding: .utf8)

    let zshenvPath = overlayDir.appendingPathComponent(".zshenv")
    try zshEnvFile(hookScriptPath: hookPath.path)
      .write(to: zshenvPath, atomically: true, encoding: .utf8)

    var overrides: [String: String] = ["ZDOTDIR": overlayDir.path]
    if let realZDOTDIR = environment["ZDOTDIR"], !realZDOTDIR.isEmpty {
      overrides["LABAN_REAL_ZDOTDIR"] = realZDOTDIR
    }
    return overrides
  }

  /// Single-quote a path for safe inclusion in a POSIX-shell `source`
  /// command, escaping embedded single quotes.
  private static func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
