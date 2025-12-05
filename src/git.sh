#!/usr/bin/env bash
set -euo pipefail

SSH_CONFIG="$HOME/.ssh/config"
SSH_HELP_SCRIPT="$(dirname "$0")/ssh.sh"

# Default options to render fzf inline in the current terminal. Can be
# overridden by exporting FZF_INLINE_OPTS in the environment.
FZF_INLINE_OPTS="--height=40% --layout=reverse --border"

GT_DISPATCHER="$(dirname "$0")/gt.sh"

# --- Email extraction helpers (duplicated from ssh.sh to avoid sourcing execution) ---
get_identity_file_for_alias() {
  local alias="$1"
  [ -f "$SSH_CONFIG" ] || return 1
  local identity
  identity="$(awk -v target="$alias" '
    /^Host[[:space:]]+/ { in_block = ($2 == target); next }
    in_block && /^[[:space:]]*IdentityFile[[:space:]]+/ { print $2; exit }
  ' "$SSH_CONFIG" || true)"
  if [ -z "$identity" ]; then
    local fallback="$HOME/.ssh/id_ed25519_${alias}"
    [ -f "$fallback" ] && identity="$fallback"
  fi
  [ -n "$identity" ] && printf '%s' "$identity"
}

extract_email_from_pub() {
  local pub_file="$1"
  [ -f "$pub_file" ] || return 1
  local line email
  line="$(head -n1 "$pub_file" || true)"
  email="$(echo "$line" | grep -E -o '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | head -n1 || true)"
  if [ -n "$email" ]; then
    printf '%s' "$email"
    return 0
  fi
  return 1
}

set_git_email_in_repo() {
  local alias="$1" repo_dir="$2"
  [ -d "$repo_dir/.git" ] || { echo "Directory '$repo_dir' does not appear to be a git repository"; return 1; }
  local identity_file email pub_file
  identity_file="$(get_identity_file_for_alias "$alias" || true)"
  if [ -z "$identity_file" ]; then echo "Could not obtain IdentityFile for alias '$alias'"; return 1; fi
  pub_file="${identity_file}.pub"
  if email="$(extract_email_from_pub "$pub_file" 2>/dev/null)"; then
    echo "Email extracted: $email"
  else
    read -p "Email not found in public key. Enter email for this repository: " email
    [ -z "$email" ] && { echo "Empty email provided. Aborting."; return 1; }
  fi
  (
    cd "$repo_dir" && git config user.email "$email" && echo "Git user.email set to '$email' in '$repo_dir'"
  ) || return 1
}

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
    printf '%s\n' "${aliases[@]}" | fzf ${FZF_INLINE_OPTS} --prompt="HostAlias> "
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

unlock_alias_if_possible() {
  local alias="$1"
  [ -n "$alias" ] || return 0
  if [ -x "$GT_DISPATCHER" ]; then
    "$GT_DISPATCHER" ssh unlock "$alias" >/dev/null 2>&1 || true
  fi
}

get_origin_alias() {
  # Determine HostAlias from origin URL (expects git@<alias>:...)
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi
  local origin
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [ -z "$origin" ]; then
    return 1
  fi
  echo "$origin" | sed -n 's#git@\([^:]*\):.*#\1#p'
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
  # Attempt to unlock key via vault, if configured
  echo "Attempting to unlock SSH key '$chosen_alias' via vault..."
  unlock_alias_if_possible "$chosen_alias"
  git clone "$new_link"
    # Derive repository directory name
    local repo_dir
    repo_dir="$(basename "${new_link%.git}")"
    if [ -d "$repo_dir/.git" ]; then
      set_git_email_in_repo "$chosen_alias" "$repo_dir" || true
    fi
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

  # For other git commands, try to unlock the current repo alias first
  if [ "$#" -ge 1 ]; then
    case "$1" in
      fetch|pull|push|submodule)
        local alias
        alias="$(get_origin_alias || true)"
        if [ -n "$alias" ]; then
          unlock_alias_if_possible "$alias"
        fi
        ;;
    esac
    git "$@"
    exit $?
  fi

  echo "Usage: $0 clone <SSH_Link> | <git_command> [args...]"
  exit 1
}

main "$@"
