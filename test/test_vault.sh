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

clean_vault() {
  rm -rf "$VAULT_DIR" || true
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
clean_vault

# Final summary
if [ "$FAILURES" -ne 0 ]; then
  echo "vault.sh tests: $FAILURES failures out of $TESTS_RUN checks" >&2
  exit 1
fi

echo "vault.sh tests: all $TESTS_RUN checks passed" >&2
exit 0
