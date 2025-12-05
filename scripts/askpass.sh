#!/usr/bin/env bash
set -euo pipefail

# Simple SSH_ASKPASS helper for gittool: prints vault master passphrase
# Requires the usual gittool config env vars or defaults.

GITTOOL_CFG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/gittool"
GITTOOL_CFG_FILE="$GITTOOL_CFG_ROOT/vault"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VAULT_SH="${SCRIPT_DIR%/scripts}/src/vault.sh"

if [ ! -x "$VAULT_SH" ]; then
  echo "gittool-askpass: vault.sh not found or not executable" >&2
  exit 1
fi

master="$(GITTOOL_CFG_ROOT="$GITTOOL_CFG_ROOT" GITTOOL_CFG_FILE="$GITTOOL_CFG_FILE" "$VAULT_SH" -m 2>/dev/null || true)"

if [ -z "$master" ]; then
  echo "gittool-askpass: failed to obtain vault master" >&2
  exit 1
fi

# ssh-askpass expects the passphrase on stdout only
printf '%s' "$master"
