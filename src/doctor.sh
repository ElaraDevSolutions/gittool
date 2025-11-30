#!/usr/bin/env bash
set -euo pipefail

STATUS_OVERALL="OK"
WARN_COUNT=0
ERROR_COUNT=0

note_warn() {
  echo "  [WARN] $1"
  STATUS_OVERALL="WARN"
  WARN_COUNT=$((WARN_COUNT+1))
}

note_error() {
  echo "  [ERROR] $1"
  STATUS_OVERALL="ERROR"
  ERROR_COUNT=$((ERROR_COUNT+1))
}

note_ok() {
  echo "  [OK] $1"
}

note_info() {
  echo "  [INFO] $1"
}

check_env() {
  echo "Environment:"
  if command -v git >/dev/null 2>&1; then
    note_ok "git found: $(command -v git)"
  else
    note_error "git not found in PATH"
  fi
  if command -v ssh >/dev/null 2>&1; then
    note_ok "ssh found: $(command -v ssh)"
  else
    note_error "ssh not found in PATH"
  fi
  if command -v ssh-agent >/dev/null 2>&1; then
    note_ok "ssh-agent available"
  else
    note_warn "ssh-agent not found (ssh-add may fail)"
  fi
  if command -v fzf >/dev/null 2>&1; then
    note_ok "fzf found (enhanced interactive selection enabled)"
  else
    note_info "fzf not found (falling back to basic selection)"
  fi
  echo
}

check_ssh_config() {
  echo "SSH config:"
  local ssh_dir="$HOME/.ssh" config_file="$HOME/.ssh/config"
  if [ -d "$ssh_dir" ]; then
    note_ok "~/.ssh exists: $ssh_dir"
  else
    note_warn "~/.ssh directory does not exist"
  fi
  if [ -f "$config_file" ]; then
    note_ok "SSH config file exists: $config_file"
    local aliases
    aliases=$(grep -E '^Host[[:space:]]+[^ ]+$' "$config_file" 2>/dev/null | awk '{print $2}' || true)
    if [ -n "$aliases" ]; then
      local count
      count=$(printf '%s
' "$aliases" | wc -l | tr -d ' ')
      note_ok "Found $count Host aliases: $(printf '%s' "$aliases" | tr '\n' ' ' | sed 's/ $//')"
    else
      note_warn "No Host aliases found in SSH config"
    fi
  else
    note_warn "SSH config file not found at $config_file"
  fi
  echo
}

check_signing() {
  echo "SSH signing & Git config:"
  local allowed_file="$HOME/.config/git/allowed_signers"
  if [ -f "$allowed_file" ]; then
    note_ok "allowed_signers file exists: $allowed_file"
  else
    note_info "allowed_signers file not found (SSH commit signing may be disabled)"
  fi
  local cfg_allowed
  cfg_allowed="$(git config --global gpg.ssh.allowedSignersFile 2>/dev/null || true)"
  if [ -n "$cfg_allowed" ]; then
    if [ "$cfg_allowed" = "$allowed_file" ]; then
      note_ok "global gpg.ssh.allowedSignersFile points to allowed_signers"
    else
      note_warn "global gpg.ssh.allowedSignersFile points to a different file: $cfg_allowed"
    fi
  else
    note_info "global gpg.ssh.allowedSignersFile not set"
  fi
  local signing_key
  signing_key="$(git config --global user.signingkey 2>/dev/null || true)"
  if [ -n "$signing_key" ]; then
    if [ -f "$signing_key" ]; then
      note_ok "global user.signingkey set: $signing_key (file exists)"
    else
      note_warn "global user.signingkey set but file does not exist: $signing_key"
    fi
  else
    note_info "global user.signingkey not set"
  fi
  local global_email
  global_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$global_email" ]; then
    note_ok "global user.email: $global_email"
  else
    note_info "global user.email not set"
  fi
  echo
}

check_current_repo() {
  echo "Current repository:"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local root origin remote_host
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    origin="$(git remote get-url origin 2>/dev/null || true)"
    note_ok "inside git repo: $root"
    if [ -n "$origin" ]; then
      note_ok "origin remote: $origin"
      if echo "$origin" | grep -qE '^git@[^:]+:'; then
        remote_host="$(printf '%s' "$origin" | sed -n 's#git@\([^:]*\):.*#\1#p')"
        note_ok "origin uses SSH host: $remote_host"
      else
        note_warn "origin is not SSH format (expected git@host:path)"
      fi
    else
      note_info "origin remote not set"
    fi
    local local_email
    local_email="$(git config user.email 2>/dev/null || true)"
    if [ -n "$local_email" ]; then
      note_ok "local user.email: $local_email"
    else
      note_info "local user.email not set"
    fi
    local sign_flag
    sign_flag="$(git config --get commit.gpgsign 2>/dev/null || git config --global --get commit.gpgsign 2>/dev/null || true)"
    if [ "$sign_flag" = "true" ]; then
      note_ok "commit.gpgsign is enabled (local or global)"
    else
      note_info "commit.gpgsign not enabled"
    fi
  else
    note_info "not inside a git work tree"
  fi
  echo
}

main() {
  local MODE="all" ALIAS=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ssh-only) MODE="ssh"; shift ;;
      --git-only) MODE="git"; shift ;;
      --alias)
        shift
        ALIAS="${1:-}"
        [ -z "$ALIAS" ] && { echo "Usage: gt doctor [--ssh-only|--git-only] [--alias <HostAlias>]" >&2; exit 1; }
        shift
        ;;
      -h|--help)
        echo "Usage: gt doctor [--ssh-only|--git-only] [--alias <HostAlias>]";
        echo "  --ssh-only   Run only SSH-related checks";
        echo "  --git-only   Run only Git/repository checks";
        echo "  --alias NAME Highlight details for a specific SSH HostAlias (uses 'gt ssh show')";
        return 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Usage: gt doctor [--ssh-only|--git-only] [--alias <HostAlias>]" >&2
        return 1
        ;;
     esac
  done

  echo "gt doctor"
  echo "=========="
  echo
  if [ "$MODE" = "all" ] || [ "$MODE" = "ssh" ]; then
    check_env
    check_ssh_config
    check_signing
  fi
  if [ "$MODE" = "all" ] || [ "$MODE" = "git" ]; then
    check_current_repo
  fi

  if [ -n "$ALIAS" ]; then
    echo "Alias details (gt ssh show $ALIAS):"
    echo "----------------------------------"
    # Try to locate gt binary or fall back to src/gt.sh
    if command -v gt >/dev/null 2>&1; then
      gt ssh show "$ALIAS" || note_warn "gt ssh show $ALIAS failed"
    elif [ -x "$(dirname "$0")/gt.sh" ]; then
      "$(dirname "$0")/gt.sh" ssh show "$ALIAS" || note_warn "gt.sh ssh show $ALIAS failed"
    else
      note_warn "gt binary not found on PATH and gt.sh not found next to doctor.sh; cannot show alias details"
    fi
    echo
  fi

  echo "Summary:"
  echo "  Overall status: $STATUS_OVERALL (warnings: $WARN_COUNT, errors: $ERROR_COUNT)"
  if [ "$ERROR_COUNT" -gt 0 ]; then
    return 1
  else
    return 0
  fi
}

main "$@"
