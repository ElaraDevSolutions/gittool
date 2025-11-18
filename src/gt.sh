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

# --- Usage message ---
usage() {
  cat <<EOF
Usage:
  gt ssh <cmd> [args...]      # Call the SSH helper (ssh.sh)
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
    # Try to determine version from git tags, VERSION file, or fallback
    if [ -d "${SCRIPT_DIR}/.." ] && [ -d "${SCRIPT_DIR}/../.git" ]; then
      # If git is available, prefer annotated tag or short commit
      if command -v git >/dev/null 2>&1; then
        ver="$(git -C "${SCRIPT_DIR}/.." describe --tags --abbrev=0 2>/dev/null || true)"
        if [ -z "$ver" ]; then
          ver="$(git -C "${SCRIPT_DIR}/.." rev-parse --short HEAD 2>/dev/null || true)"
        fi
      fi
    fi
    # If not found via git, try VERSION file
    if [ -z "${ver:-}" ] && [ -f "${SCRIPT_DIR}/../VERSION" ]; then
      ver="$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null || true)"
    fi
    # Default
    ver="${ver:-v0.0.0}"
    echo "$ver"
    exit 0
    ;;
  ssh|ssh.sh)
    shift || true
    if [ ! -x "$SSH_SCRIPT" ]; then
      echo "Error: ssh.sh not found at $SSH_SCRIPT" >&2
      exit 1
    fi
    exec bash "$SSH_SCRIPT" "$@"
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
