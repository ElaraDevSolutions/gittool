#!/usr/bin/env bash
# Test suite for install.sh
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$SCRIPT_ROOT/install.sh"

TEST_TMP="$(mktemp -d)"
PREFIX="$TEST_TMP/prefix"
FAILURES=0
TESTS=0

report_fail() {
  echo "FAIL: $1"; FAILURES=$((FAILURES+1))
}
assert_file() {
  TESTS=$((TESTS+1))
  local f="$1"; local msg="$2"
  if [[ ! -f "$f" ]]; then report_fail "$msg (missing $f)"; fi
}
assert_not_file() {
  TESTS=$((TESTS+1))
  local f="$1"; local msg="$2"
  if [[ -f "$f" ]]; then report_fail "$msg (unexpected file $f)"; fi
}
assert_dir() {
  TESTS=$((TESTS+1))
  local d="$1"; local msg="$2"
  if [[ ! -d "$d" ]]; then report_fail "$msg (missing dir $d)"; fi
}
assert_not_dir() {
  TESTS=$((TESTS+1))
  local d="$1"; local msg="$2"
  if [[ -d "$d" ]]; then report_fail "$msg (unexpected dir $d)"; fi
}
assert_rc_zero() {
  TESTS=$((TESTS+1))
  local rc="$1"; local msg="$2"
  if [[ "$rc" -ne 0 ]]; then report_fail "$msg (rc=$rc)"; fi
}

echo "==> Running install.sh tests with PREFIX=$PREFIX"

### Test 1: basic install
bash "$INSTALL_SCRIPT" --prefix="$PREFIX"
assert_dir "$PREFIX/lib/gittool" "Library directory should be created"
assert_file "$PREFIX/lib/gittool/gt.sh" "gt.sh should be copied"
assert_file "$PREFIX/lib/gittool/git.sh" "git.sh should be copied"
assert_file "$PREFIX/lib/gittool/ssh.sh" "ssh.sh should be copied"
assert_file "$PREFIX/bin/gt" "Wrapper should be created"
grep -q 'GT_INSTALL_WRAPPER_MARKER' "$PREFIX/bin/gt" || report_fail "Wrapper should contain marker"

### Test 2: wrapper executes underlying script (help command)
set +e
out_help=$("$PREFIX/bin/gt" ssh help 2>&1)
rc_help=$?
set -e
assert_rc_zero "$rc_help" "gt ssh help should exit 0"
echo "$out_help" | grep -q "Commands" || report_fail "Help output should contain 'Commands'"

### Test 3: reinstall without --force should fail (expect error)
set +e
out_reinstall=$(bash "$INSTALL_SCRIPT" --prefix="$PREFIX" 2>&1)
rc_reinstall=$?
set -e
if [[ "$rc_reinstall" -eq 0 ]]; then report_fail "Reinstall without --force should not succeed"; fi
echo "$out_reinstall" | grep -q "already exists" || report_fail "Should mention existing files on reinstall"

### Test 4: reinstall with --force should succeed
bash "$INSTALL_SCRIPT" --prefix="$PREFIX" --force
assert_file "$PREFIX/bin/gt" "Wrapper still exists after force reinstall"

### Test 5: uninstall
bash "$INSTALL_SCRIPT" --prefix="$PREFIX" --uninstall
assert_not_dir "$PREFIX/lib/gittool" "Library directory should be removed after uninstall"
assert_not_file "$PREFIX/bin/gt" "Wrapper should be removed after uninstall"

### Test 6: dry-run should not create directories or files
DRY_PREFIX="$TEST_TMP/dry"
set +e
dry_out=$(bash "$INSTALL_SCRIPT" --prefix="$DRY_PREFIX" --dry-run 2>&1)
rc_dry=$?
set -e
assert_rc_zero "$rc_dry" "Dry-run should exit 0"
echo "$dry_out" | grep -q "DRY:" || report_fail "Dry-run output should contain DRY markers"
assert_not_dir "$DRY_PREFIX/lib/gittool" "Dry-run must not create lib directory"
assert_not_file "$DRY_PREFIX/bin/gt" "Dry-run must not create wrapper"

echo "Tests run: $TESTS"
if [[ $FAILURES -gt 0 ]]; then
  echo "Failures: $FAILURES"
  rm -rf "$TEST_TMP" || true
  exit 1
fi
echo "All install tests passed."
rm -rf "$TEST_TMP" || true
exit 0
