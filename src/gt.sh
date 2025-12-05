#!/usr/bin/env bash
set -euo pipefail

# Dispatcher for gittool helper scripts.
# Works both when run locally (from src/) or when installed via Homebrew.
# - Default: forwards everything to git.sh
# - If first arg is 'ssh' (or 'ssh.sh'), forwards to ssh.sh

# --- Find the directory where this script is located ---
# This works after installation via Homebrew (inside libexec)
# or when running directly from your repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Paths to helper scripts
GIT_SCRIPT="$SCRIPT_DIR/git.sh"
SSH_SCRIPT="$SCRIPT_DIR/ssh.sh"
VAULT_SCRIPT="$SCRIPT_DIR/vault.sh"

# --- Usage message ---
usage() {
  cat <<EOF
Usage:
  gt ssh <cmd> [args...]      # Call the SSH helper (ssh.sh)
  gt vault <cmd> [args...]    # Call the Vault helper (vault.sh)
  gt <git_command> [...]      # Call the Git helper (git.sh)
  gt help                     # Show this message
  gt -v | -version | --version  # Show gt version
EOF
}

# --- Entry point ---
if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

case "$1" in
  -v|-version|--version)
    config_version="${HOME}/.config/gittool/VERSION"
    if [ ! -f "$config_version" ] || [ ! -s "$config_version" ]; then
      echo "Error: VERSION file not found at $config_version" >&2
      exit 1
    fi
    ver="$(tr -d '\n' < "$config_version" 2>/dev/null || true)"
    if [ -z "$ver" ]; then
      echo "Error: VERSION file at $config_version is empty" >&2
      exit 1
    fi
    echo "$ver"
    exit 0
    ;;
  doctor)
    shift || true
    DOCTOR_SCRIPT="$SCRIPT_DIR/doctor.sh"
    if [ ! -x "$DOCTOR_SCRIPT" ]; then
      echo "Error: doctor.sh not found at $DOCTOR_SCRIPT" >&2
      exit 1
    fi
    exec bash "$DOCTOR_SCRIPT" "$@"
    ;;
  ssh|ssh.sh)
    shift || true
    if [ ! -x "$SSH_SCRIPT" ]; then
      echo "Error: ssh.sh not found at $SSH_SCRIPT" >&2
      exit 1
    fi
    exec bash "$SSH_SCRIPT" "$@"
    ;;
  vault|vault.sh)
    shift || true
    if [ ! -x "$VAULT_SCRIPT" ]; then
      echo "Error: vault.sh not found at $VAULT_SCRIPT" >&2
      exit 1
    fi
    exec bash "$VAULT_SCRIPT" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    if [ ! -x "$GIT_SCRIPT" ]; then
      echo "Error: git.sh not found at $GIT_SCRIPT" >&2
      exit 1
    fi
    exec bash "$GIT_SCRIPT" "$@"
    ;;
esac
