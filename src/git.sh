#!/usr/bin/env bash
set -euo pipefail

SSH_CONFIG="$HOME/.ssh/config"
SSH_HELP_SCRIPT="$(dirname "$0")/ssh.sh"

show_help_and_exit() {
  echo "Only SSH links are supported."
  echo "See below for SSH key setup:"
  bash "$SSH_HELP_SCRIPT" help
  exit 1
}

get_host_aliases() {
  grep -E '^Host[[:space:]]+[^ ]+$' "$SSH_CONFIG" | awk '{print $2}'
}

select_host_alias() {
  local aliases=("$@")
  if command -v fzf >/dev/null 2>&1; then
    echo "Select the SSH key to use:" >&2
    printf '%s\n' "${aliases[@]}" | fzf --prompt="HostAlias> "
  else
    echo "Select the SSH key to use:" >&2
    select alias in "${aliases[@]}"; do
      if [ -n "$alias" ]; then
        echo "$alias"
        break
      fi
    done
  fi
}

clone_with_ssh() {
  local link="$1"
  if [ ! -f "$SSH_CONFIG" ]; then
    echo "No SSH config found. Please add a key with ssh.sh first."
    bash "$SSH_HELP_SCRIPT" help
    exit 1
  fi
  local aliases=( $(get_host_aliases) )
  if [ ${#aliases[@]} -eq 0 ]; then
    echo "No SSH keys configured. Please add a key with ssh.sh first."
    bash "$SSH_HELP_SCRIPT" help
    exit 1
  fi
  local chosen_alias="${aliases[0]}"
  if [ ${#aliases[@]} -gt 1 ]; then
    chosen_alias=$(select_host_alias "${aliases[@]}")
  fi
  # Extract original host from link
  local orig_host
  orig_host=$(echo "$link" | sed -n 's#git@\([^:]*\):.*#\1#p')
  if [ -z "$orig_host" ]; then
    echo "Could not parse SSH host from link."
    exit 1
  fi
  # Replace host with chosen HostAlias
  local new_link
  new_link=$(echo "$link" | sed "s#git@${orig_host}:#git@${chosen_alias}:#")
  echo "Cloning with SSH key: $chosen_alias"
  git clone "$new_link"
}

main() {
  if [ "$#" -ge 2 ] && [ "$1" = "clone" ]; then
    local link="$2"
    if [[ ! "$link" =~ ^git@ ]]; then
      show_help_and_exit
    fi
    clone_with_ssh "$link"
    exit 0
  fi

  # For other git commands, just forward to git
  if [ "$#" -ge 1 ]; then
    git "$@"
    exit $?
  fi

  echo "Usage: $0 clone <SSH_Link> | <git_command> [args...]"
  exit 1
}

main "$@"
