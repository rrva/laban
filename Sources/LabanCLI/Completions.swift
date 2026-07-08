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
    )
    _describe -t commands 'laban command' commands
  }

  _laban "$@"
  """

private let bashCompletions = """
  _laban() {
    local cur prev words cword
    _init_completion || return

    local commands="discover status health capabilities request completions install-cli"

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

  complete -c laban -n '__fish_seen_subcommand_from discover status health capabilities' -l json
  complete -c laban -n '__fish_seen_subcommand_from request' -l body -r
  complete -c laban -n '__fish_seen_subcommand_from request' -l json
  complete -c laban -n '__fish_seen_subcommand_from install-cli' -l prefix -r
  complete -c laban -n '__fish_seen_subcommand_from install-cli' -l dry-run
  complete -c laban -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
  """
