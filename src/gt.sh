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
    # Look for VERSION file in multiple locations (installed via Homebrew or in-repo)
    # Allow explicit override using GITTOOL_VERSION_PATH
    ver=""
    try_paths=()
    if [ -n "${GITTOOL_VERSION_PATH:-}" ]; then
      try_paths+=("${GITTOOL_VERSION_PATH}")
    fi
    # Typical layouts:
    # - running from repo: SCRIPT_DIR/../VERSION
    # - Homebrew install: SCRIPT_DIR/../libexec/.. or SCRIPT_DIR/../../VERSION depending on install layout
    try_paths+=("${SCRIPT_DIR}/../VERSION")
    try_paths+=("${SCRIPT_DIR}/../../VERSION")
    try_paths+=("/opt/homebrew/opt/gittool/VERSION")
    try_paths+=("/usr/local/opt/gittool/VERSION")
    # Try brew --prefix if available
    if command -v brew >/dev/null 2>&1; then
      brew_prefix=$(brew --prefix 2>/dev/null || true)
      if [ -n "$brew_prefix" ]; then
        try_paths+=("${brew_prefix}/opt/gittool/VERSION")
      fi
    fi
    for p in "${try_paths[@]}"; do
      if [ -f "$p" ] && [ -s "$p" ]; then
        ver="$(cat "$p" 2>/dev/null | tr -d '\n' || true)"
        break
      fi
    done
    # As a last attempt, traverse up from SCRIPT_DIR to find a VERSION file
    if [ -z "$ver" ]; then
      curdir="$SCRIPT_DIR"
      depth=0
      while [ "$depth" -lt 6 ]; do
        candidate="$curdir/VERSION"
        if [ -f "$candidate" ] && [ -s "$candidate" ]; then
          ver="$(cat "$candidate" 2>/dev/null | tr -d '\n' || true)"
          break
        fi
        curdir="$(dirname "$curdir")"
        depth=$((depth + 1))
      done
    fi
    # If not found in files, fall back to git detection
    if [ -z "$ver" ]; then
      if [ -d "${SCRIPT_DIR}/.." ] && [ -d "${SCRIPT_DIR}/../.git" ] && command -v git >/dev/null 2>&1; then
        ver="$(git -C "${SCRIPT_DIR}/.." describe --tags --abbrev=0 2>/dev/null || true)"
        if [ -z "$ver" ]; then
          ver="$(git -C "${SCRIPT_DIR}/.." rev-parse --short HEAD 2>/dev/null || true)"
        fi
      fi
    fi
    # Default fallback
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
