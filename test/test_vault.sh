#!/usr/bin/env bash
# Test suite for vault.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
VAULT_SCRIPT="$ROOT_DIR/src/vault.sh"
FAILURES=0
TESTS_RUN=0

report_fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES+1))
}

assert_equals() {
  local got="$1"; local expected="$2"; local msg="$3"
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$got" != "$expected" ]; then
    report_fail "$msg (expected='$expected' got='$got')"
  fi
}

assert_file_exists() {
  local f="$1"; local msg="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  if [ ! -f "$f" ]; then
    report_fail "$msg (missing file $f)"
  fi
}

assert_file_not_exists() {
  local f="$1"; local msg="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  if [ -f "$f" ]; then
    report_fail "$msg (file should not exist $f)"
  fi
}

# Use isolated HOME so we don't touch the real user config
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
GITTOOL_CONFIG_DIR="$HOME/.gittool"
export GITTOOL_CONFIG_DIR

VAULT_DIR="$GITTOOL_CONFIG_DIR/vault"
CFG_ROOT="$HOME/.config/gittool"
CFG_FILE="$CFG_ROOT/config"

clean_vault() {
  rm -rf "$VAULT_DIR" || true
  rm -rf "$CFG_ROOT" || true
}

run_init_with_empty() {
  clean_vault
  # Two empty lines to simulate user just pressing Enter twice
  printf '\n\n' | bash "$VAULT_SCRIPT" init >/dev/null 2>&1
}

read_master() {
  bash "$VAULT_SCRIPT" show-master 2>/dev/null || true
}

######## Tests ########

# --- Test 1: init with empty input (non-interactive) should auto-generate password ---
run_init_with_empty
MASTER2="$(read_master)"
TESTS_RUN=$((TESTS_RUN+1))
if [ -z "$MASTER2" ]; then
  report_fail "vault init with empty input should generate a non-empty password"
fi
clean_vault

# --- Test 2: re-init should be idempotent (second init does nothing) ---
run_init_with_empty
FIRST_FILE="$(ls "$VAULT_DIR"/vault-*.gpg 2>/dev/null | head -n 1 || true)"
TESTS_RUN=$((TESTS_RUN+1))
if [ -z "$FIRST_FILE" ]; then
  report_fail "vault init should create a vault-*.gpg file"
fi
# Second init should not create a new file
printf '\n\n' | bash "$VAULT_SCRIPT" init >/dev/null 2>&1 || true
SECOND_FILE_COUNT="$(ls "$VAULT_DIR"/vault-*.gpg 2>/dev/null | wc -l | tr -d ' ')"
TESTS_RUN=$((TESTS_RUN+1))
if [ "$SECOND_FILE_COUNT" != "1" ]; then
  report_fail "second vault init should not create additional vault files"
fi
clean_vault

# --- Test 3: init should auto-create a GPG key when none exists ---
clean_vault
# Ensure no GPG keys in this HOME
rm -rf "$HOME/.gnupg" || true
run_init_with_empty
# Check that key params file exists and that at least one public key is present
PARAMS_FILE="$VAULT_DIR/gpg-key-params.txt"
assert_file_exists "$PARAMS_FILE" "vault init should create GPG key params file when generating key"
KEY_COUNT="$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^pub/ {count++} END {print count+0}')"
TESTS_RUN=$((TESTS_RUN+1))
if [ "$KEY_COUNT" -lt 1 ]; then
  report_fail "vault init should generate at least one GPG public key when none exists"
fi

# --- Test 4: init should write/update local provider config ---
clean_vault
run_init_with_empty
TESTS_RUN=$((TESTS_RUN+1))
if [ ! -f "$CFG_FILE" ]; then
  report_fail "vault init should create ~/.config/gittool/config with [vault] provider"
else
  # There should be exactly one [vault] block and a matching path line
  vault_count="$(grep -c '^[[]vault[]]' "$CFG_FILE" 2>/dev/null || echo 0)"
  if [ "$vault_count" -ne 1 ]; then
    report_fail "vault config should contain exactly one [vault] section (got $vault_count)"
  fi
  path_line="$(grep '^path=' "$CFG_FILE" 2>/dev/null || true)"
  if [ -z "$path_line" ]; then
    report_fail "vault config should contain a path= line for the local provider"
  else
    vault_file="${path_line#path=}"
    if [ ! -f "$vault_file" ]; then
      report_fail "vault config path should point to an existing vault file ($vault_file)"
    fi
  fi
fi
clean_vault

# --- Test 5: ssh_hosts line should be preserved inside [vault] across re-init ---
clean_vault
# Simulate an existing config created by ssh integration, before vault init runs
mkdir -p "$(dirname "$CFG_FILE")"
{
  printf '%s\n' "[vault]"
  printf '%s\n' "provider=local"
  printf '%s\n' "path=/tmp/dummy"
  printf '%s\n' "ssh_hosts=empresa-ssh,pessoal-ssh"
} >"$CFG_FILE"
FIRST_CONTENT="$(cat "$CFG_FILE")"
TESTS_RUN=$((TESTS_RUN+1))
if ! echo "$FIRST_CONTENT" | grep -q '^ssh_hosts=empresa-ssh,pessoal-ssh'; then
  report_fail "ssh_hosts line should be present after manual insertion in [vault] section"
fi

# Run init (which rewrites [vault]) and ensure ssh_hosts line is still present
printf '\n\n' | bash "$VAULT_SCRIPT" init >/dev/null 2>&1
SECOND_CONTENT="$(cat "$CFG_FILE")"
TESTS_RUN=$((TESTS_RUN+1))
if ! echo "$SECOND_CONTENT" | grep -q '^ssh_hosts=empresa-ssh,pessoal-ssh'; then
  report_fail "vault init should preserve existing ssh_hosts mapping in [vault] section"
fi
clean_vault

# --- Test 6 (skipped for now): init with --password should store and show same master ---
# NOTE: Disabled because in some environments gpg/pinentry may still
# require interaction even when a password is passed via --password.
# This would cause the CI to hang. Re-enable once gpg can be fully
# driven non-interativamente in tests.
# clean_vault
# MASTER_PLAIN="my-super-secret-123"
# TESTS_RUN=$((TESTS_RUN+1))
# if ! GITTOOL_CONFIG_DIR="$GITTOOL_CONFIG_DIR" bash "$VAULT_SCRIPT" init --password "$MASTER_PLAIN" >/dev/null 2>&1; then
#   report_fail "vault init --password should succeed in non-interactive mode"
# else
#   SHOWN_MASTER="$(bash "$VAULT_SCRIPT" show-master 2>/dev/null || true)"
#   if [ "$SHOWN_MASTER" != "$MASTER_PLAIN" ]; then
#     report_fail "vault show-master should return the same value set by --password (expected '$MASTER_PLAIN' got '$SHOWN_MASTER')"
#   fi
# fi
# clean_vault

# --- Test 7: show-master should fail when vault is not initialized ---
clean_vault
TESTS_RUN=$((TESTS_RUN+1))
if bash "$VAULT_SCRIPT" show-master >/dev/null 2>&1; then
  report_fail "vault show-master should fail when no vault-*.gpg exists"
fi

# --- Test 8: init should fail cleanly when gpg is missing ---
clean_vault
TESTS_RUN=$((TESTS_RUN+1))
# Use a PATH that almost certainly lacks gpg to simulate missing binary
if env PATH="/usr/bin:/bin" HOME="$HOME" bash "$VAULT_SCRIPT" init >/dev/null 2>&1; then
  report_fail "vault init should fail when gpg is not installed or not found in PATH"
fi

# Final summary
if [ "$FAILURES" -ne 0 ]; then
  echo "vault.sh tests: $FAILURES failures out of $TESTS_RUN checks" >&2
  exit 1
fi

echo "vault.sh tests: all $TESTS_RUN checks passed" >&2
exit 0
