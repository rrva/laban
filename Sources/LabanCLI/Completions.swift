import Foundation

func completionsScript(for shell: String) throws -> String {
  switch shell {
  case "zsh": return zshCompletions
  case "bash": return bashCompletions
  case "fish": return fishCompletions
  default: throw LabanCLIError.unknownShell(shell)
  }
}

private let zshCompletions = """
  #compdef laban

  _laban() {
    local -a commands
    commands=(
      'discover:Discover the local Laban control plane'
      'status:Show redacted app status'
      'health:Check Laban process health'
      'capabilities:List control capabilities'
      'request:Send a raw app-observe request'
      'completions:Print shell completions'
      'install-cli:Install the laban command shim'
      'session:Session-scoped commands via the agent proxy'
      'context:Print a compact bound-session context bundle'
      'wait:Block until a bound-session condition is true'
      'propose:Propose a command for user review'
      'proposal:List, inspect, or cancel command proposals'
    )
    _describe -t commands 'laban command' commands
  }

  _laban "$@"
  """

private let bashCompletions = """
  _laban() {
    local cur prev words cword
    _init_completion || return

    local commands="discover status health capabilities request completions install-cli session context wait propose proposal"

    if [ "$COMP_CWORD" -eq 1 ]; then
      COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
      return
    fi

    case "${words[1]}" in
      discover|status|health|capabilities)
        COMPREPLY=( $(compgen -W "--json" -- "$cur") )
        ;;
      request)
        COMPREPLY=( $(compgen -W "--body --json" -- "$cur") )
        ;;
      install-cli)
        COMPREPLY=( $(compgen -W "--prefix --dry-run" -- "$cur") )
        ;;
      completions)
        COMPREPLY=( $(compgen -W "zsh bash fish" -- "$cur") )
        ;;
      context)
        COMPREPLY=( $(compgen -W "--json --max-lines" -- "$cur") )
        ;;
      wait)
        if [ "$COMP_CWORD" -eq 2 ]; then
          COMPREPLY=( $(compgen -W "prompt command-finished" -- "$cur") )
        else
          COMPREPLY=( $(compgen -W "--timeout --json" -- "$cur") )
        fi
        ;;
      session)
        if [ "$COMP_CWORD" -eq 2 ]; then
          COMPREPLY=( $(compgen -W "state request scroll proxy current get-text" -- "$cur") )
        else
          case "${words[2]}" in
            get-text)
              COMPREPLY=( $(compgen -W "--screen --scrollback --start-line --end-line --max-lines --json" -- "$cur") )
              ;;
            current)
              COMPREPLY=( $(compgen -W "--json" -- "$cur") )
              ;;
          esac
        fi
        ;;
    esac
  }

  complete -F _laban laban
  """

private let fishCompletions = """
  complete -c laban -n '__fish_use_subcommand' -a 'discover' -d 'Discover the local Laban control plane'
  complete -c laban -n '__fish_use_subcommand' -a 'status' -d 'Show redacted app status'
  complete -c laban -n '__fish_use_subcommand' -a 'health' -d 'Check Laban process health'
  complete -c laban -n '__fish_use_subcommand' -a 'capabilities' -d 'List control capabilities'
  complete -c laban -n '__fish_use_subcommand' -a 'request' -d 'Send a raw app-observe request'
  complete -c laban -n '__fish_use_subcommand' -a 'completions' -d 'Print shell completions'
  complete -c laban -n '__fish_use_subcommand' -a 'install-cli' -d 'Install the laban command shim'
  complete -c laban -n '__fish_use_subcommand' -a 'session' -d 'Session-scoped commands via the agent proxy'
  complete -c laban -n '__fish_use_subcommand' -a 'context' -d 'Print a compact bound-session context bundle'
  complete -c laban -n '__fish_use_subcommand' -a 'wait' -d 'Block until a bound-session condition is true'
  complete -c laban -n '__fish_use_subcommand' -a 'propose' -d 'Propose a command for user review'
  complete -c laban -n '__fish_use_subcommand' -a 'proposal' -d 'List, inspect, or cancel command proposals'

  complete -c laban -n '__fish_seen_subcommand_from discover status health capabilities' -l json
  complete -c laban -n '__fish_seen_subcommand_from request' -l body -r
  complete -c laban -n '__fish_seen_subcommand_from request' -l json
  complete -c laban -n '__fish_seen_subcommand_from install-cli' -l prefix -r
  complete -c laban -n '__fish_seen_subcommand_from install-cli' -l dry-run
  complete -c laban -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
  complete -c laban -n '__fish_seen_subcommand_from context' -l json
  complete -c laban -n '__fish_seen_subcommand_from context' -l max-lines -r
  complete -c laban -n '__fish_seen_subcommand_from wait' -a 'prompt command-finished'
  complete -c laban -n '__fish_seen_subcommand_from wait' -l timeout -r
  complete -c laban -n '__fish_seen_subcommand_from wait' -l json
  complete -c laban -n '__fish_seen_subcommand_from session' -a 'state request scroll proxy current get-text'
  complete -c laban -n '__fish_seen_subcommand_from session' -l json
  complete -c laban -n '__fish_seen_subcommand_from session' -l screen
  complete -c laban -n '__fish_seen_subcommand_from session' -l scrollback
  complete -c laban -n '__fish_seen_subcommand_from session' -l start-line -r
  complete -c laban -n '__fish_seen_subcommand_from session' -l end-line -r
  complete -c laban -n '__fish_seen_subcommand_from session' -l max-lines -r
  """
