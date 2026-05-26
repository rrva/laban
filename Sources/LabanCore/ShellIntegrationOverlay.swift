import Foundation

/// How to launch a shell so it emits OSC 133 markers: environment overrides
/// merged onto the spawn environment, plus an optional explicit argv (for
/// shells whose injection cannot be expressed through env alone).
public struct ShellIntegrationLaunch: Equatable {
  /// Env overrides applied on top of the inherited environment. Empty when
  /// the shell has no overlay (or none is needed).
  public var environmentOverrides: [String: String]
  /// Full argv to spawn (argv[0] is the executable path), or `nil` to keep
  /// Laban's default login-shell argv. Only bash needs this.
  public var argv: [String]?

  public init(environmentOverrides: [String: String] = [:], argv: [String]? = nil) {
    self.environmentOverrides = environmentOverrides
    self.argv = argv
  }

  /// A launch that changes nothing — used for shells without an overlay.
  public static let passthrough = ShellIntegrationLaunch()

  /// The trailing-`exec` args a resumed agent shell needs to stay
  /// instrumented, or nil to keep the default login-interactive `-l -i`.
  /// Only argv-based integration (bash's `--rcfile <overlay> -i`) needs this;
  /// env-based shells (zsh/fish) return nil because the exec inherits their
  /// `ZDOTDIR`/`XDG_DATA_DIRS` overrides.
  public var resumeExecArgs: [String]? {
    guard let argv, argv.count > 1 else { return nil }
    return Array(argv.dropFirst())
  }
}

/// Generates a shell rc-overlay that makes the user's shell emit OSC 133
/// ("semantic prompt") markers without the user editing their dotfiles. See
/// `docs/product/spec.md` §7 and the parser side in `ShellIntegrationState`.
///
/// Each shell loads startup files differently, so each gets its own strategy:
/// - **zsh**: point `ZDOTDIR` at an overlay whose `.zshenv` restores the real
///   `ZDOTDIR`, sources the user's config, then installs `precmd`/`preexec`
///   hooks.
/// - **bash**: launch `bash --rcfile <overlay> -i` (interactive, non-login);
///   the overlay sources the user's login profile (preserving PATH-style
///   state) then installs a `PROMPT_COMMAND` + `DEBUG`-trap hook.
/// - **fish**: prepend a directory to `XDG_DATA_DIRS` holding
///   `fish/vendor_conf.d/laban-integration.fish`; fish auto-loads vendor
///   conf.d snippets before `config.fish`, additively, without touching the
///   user's own config.
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

  // MARK: - Hook scripts (pure content)

  /// zsh OSC 133 hooks. Emits `A` (fresh prompt) every `precmd`, `D;<exit>`
  /// for the just-finished command before the next prompt, and `C` on
  /// `preexec`. `B` is intentionally omitted (it needs PS1 surgery and `A`
  /// already drives the `atPrompt` phase). Guarded against re-sourcing.
  public static let zshHookScript = """
    # Laban OSC 133 shell integration (zsh). Auto-generated; do not edit.
    if (( ${+functions[_laban_osc133_precmd]} )); then
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

  /// bash OSC 133 hooks via `PROMPT_COMMAND` only. Emits `A` (fresh prompt)
  /// every prompt and `D;<exit>` for the just-finished command (captured from
  /// `$?` at the top of the function, which runs first because it is
  /// prepended to any existing `PROMPT_COMMAND`). The first prompt emits only
  /// `A` (no command has run yet).
  ///
  /// bash does NOT get a `C` (command-start / "running") marker. The only
  /// bash mechanism for preexec is a `DEBUG` trap, which is too coarse to use
  /// safely: it fires for every simple command — including the components of
  /// a user's own multi-statement `PROMPT_COMMAND` and even the lines of this
  /// hook script itself — producing spurious `C` markers, and installing one
  /// would clobber a user's existing `DEBUG` trap (bash-preexec, atuin,
  /// command timers). So the bash indicator shows the red failure dot
  /// (driven by the exit code in `D`) but not the blue running dot. zsh and
  /// fish keep `C` because their preexec hooks (`add-zsh-hook`,
  /// `--on-event fish_preexec`) are additive and conflict-free.
  ///
  /// Works on macOS bash 3.2 (string `PROMPT_COMMAND`, no array). Guarded
  /// against re-sourcing.
  public static let bashHookScript = """
    # Laban OSC 133 shell integration (bash). Auto-generated; do not edit.
    if declare -F _laban_osc133_prompt >/dev/null 2>&1; then
      return 0 2>/dev/null
    fi
    export LABAN_SHELL_INTEGRATION=1
    _laban_osc133_started=""
    _laban_osc133_prompt() {
      local ec=$?
      if [ -n "$_laban_osc133_started" ]; then
        printf '\\033]133;D;%d\\007' "$ec"
      fi
      _laban_osc133_started=1
      printf '\\033]133;A\\007'
    }
    case ";${PROMPT_COMMAND-};" in
      *";_laban_osc133_prompt;"*) ;;
      *) PROMPT_COMMAND="_laban_osc133_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
    """

  /// fish OSC 133 hooks using fish's event functions: `fish_prompt` -> A,
  /// `fish_preexec` -> C, `fish_postexec` -> D with `$status`. Guarded
  /// against re-loading.
  public static let fishHookScript = """
    # Laban OSC 133 shell integration (fish). Auto-generated; do not edit.
    if not functions -q _laban_osc133_prompt
        set -gx LABAN_SHELL_INTEGRATION 1
        function _laban_osc133_prompt --on-event fish_prompt
            printf '\\033]133;A\\007'
        end
        function _laban_osc133_preexec --on-event fish_preexec
            printf '\\033]133;C\\007'
        end
        function _laban_osc133_postexec --on-event fish_postexec
            printf '\\033]133;D;%d\\007' $status
        end
    end
    """

  /// The overlay `.zshenv`. Restores the user's real `ZDOTDIR`, sources their
  /// real `.zshenv`, then installs Laban's hooks from `hookScriptPath`.
  public static func zshEnvFile(hookScriptPath: String) -> String {
    """
    # Laban shell integration overlay (zsh). Auto-generated; do not edit.
    if [[ -n "${LABAN_REAL_ZDOTDIR-}" ]]; then
      export ZDOTDIR="$LABAN_REAL_ZDOTDIR"
    else
      unset ZDOTDIR
    fi
    if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
      source "${ZDOTDIR:-$HOME}/.zshenv"
    fi
    source \(shellSingleQuote(hookScriptPath))
    """
  }

  /// The overlay bash rcfile passed via `--rcfile`. `--rcfile` suppresses
  /// bash's own startup-file lookup, so the overlay must reproduce it.
  /// Sources `/etc/profile` then the first existing of `~/.bash_profile` /
  /// `~/.bash_login` / `~/.profile` (which by convention pulls in
  /// `~/.bashrc`); if none of those exist, falls back to sourcing
  /// `~/.bashrc` directly so a user who keeps all interactive config there
  /// still gets it. Then installs the hooks.
  public static func bashRcFile(hookScriptPath: String) -> String {
    """
    # Laban shell integration overlay (bash). Auto-generated; do not edit.
    if [ -f /etc/profile ]; then . /etc/profile; fi
    _laban_sourced=""
    for _laban_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -r "$_laban_f" ]; then . "$_laban_f"; _laban_sourced=1; break; fi
    done
    if [ -z "$_laban_sourced" ] && [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
    unset _laban_f _laban_sourced
    . \(shellSingleQuote(hookScriptPath))
    """
  }

  // MARK: - Installation

  /// Write the overlay for `shellPath` under `baseDirectory` and return how
  /// to launch the shell. Returns `.passthrough` for shells without an
  /// overlay (`other`), so the caller can apply the result unconditionally.
  ///
  /// `environment` is the environment the shell would otherwise launch with;
  /// the user's real `ZDOTDIR` and `XDG_DATA_DIRS` are read from it.
  /// Idempotent: re-writing the same `baseDirectory` overwrites the files.
  @discardableResult
  public static func install(
    shellPath: String,
    baseDirectory: URL,
    environment: [String: String]
  ) throws -> ShellIntegrationLaunch {
    switch Shell.classify(path: shellPath) {
    case .zsh:
      return try installZsh(baseDirectory: baseDirectory, environment: environment)
    case .bash:
      return try installBash(shellPath: shellPath, baseDirectory: baseDirectory)
    case .fish:
      return try installFish(baseDirectory: baseDirectory, environment: environment)
    case .other:
      return .passthrough
    }
  }

  private static func installZsh(
    baseDirectory: URL, environment: [String: String]
  ) throws -> ShellIntegrationLaunch {
    let dir = baseDirectory.appendingPathComponent("zsh", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let hookPath = dir.appendingPathComponent("laban-integration.zsh")
    try zshHookScript.write(to: hookPath, atomically: true, encoding: .utf8)
    try zshEnvFile(hookScriptPath: hookPath.path)
      .write(to: dir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)

    var env = ["ZDOTDIR": dir.path]
    if let real = environment["ZDOTDIR"], !real.isEmpty {
      env["LABAN_REAL_ZDOTDIR"] = real
    }
    return ShellIntegrationLaunch(environmentOverrides: env, argv: nil)
  }

  private static func installBash(
    shellPath: String, baseDirectory: URL
  ) throws -> ShellIntegrationLaunch {
    let dir = baseDirectory.appendingPathComponent("bash", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let hookPath = dir.appendingPathComponent("laban-integration.bash")
    try bashHookScript.write(to: hookPath, atomically: true, encoding: .utf8)
    let rcPath = dir.appendingPathComponent("rcfile.bash")
    try bashRcFile(hookScriptPath: hookPath.path)
      .write(to: rcPath, atomically: true, encoding: .utf8)
    // Interactive, non-login: --rcfile takes effect and the overlay sources
    // the login profile to compensate.
    return ShellIntegrationLaunch(
      environmentOverrides: [:],
      argv: [shellPath, "--rcfile", rcPath.path, "-i"])
  }

  private static func installFish(
    baseDirectory: URL, environment: [String: String]
  ) throws -> ShellIntegrationLaunch {
    // fish auto-loads $XDG_DATA_DIRS/<entry>/fish/vendor_conf.d/*.fish before
    // config.fish. Prepend our data dir so the snippet loads without touching
    // the user's own config.
    let dataDir = baseDirectory.appendingPathComponent("fish-data", isDirectory: true)
    let vendorDir = dataDir.appendingPathComponent("fish/vendor_conf.d", isDirectory: true)
    try FileManager.default.createDirectory(at: vendorDir, withIntermediateDirectories: true)
    try fishHookScript.write(
      to: vendorDir.appendingPathComponent("laban-integration.fish"),
      atomically: true, encoding: .utf8)

    let existing =
      environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "/usr/local/share:/usr/share"
    return ShellIntegrationLaunch(
      environmentOverrides: ["XDG_DATA_DIRS": "\(dataDir.path):\(existing)"],
      argv: nil)
  }

  /// Single-quote a path for safe inclusion in a POSIX-shell `source`
  /// command, escaping embedded single quotes.
  private static func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
