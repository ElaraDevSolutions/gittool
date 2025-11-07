#!/usr/bin/env bash
# Test suite for ssh.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_SCRIPT="$SCRIPT_DIR/../src/ssh.sh"
FAILURES=0
TESTS_RUN=0

function report_fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES+1))
}
function assert_equals() {
  local got="$1"; local expected="$2"; local msg="$3"
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$got" != "$expected" ]; then
    report_fail "$msg (expected='$expected' got='$got')"
  fi
}
function assert_file_exists() {
  local f="$1"; local msg="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  if [ ! -f "$f" ]; then
    report_fail "$msg (missing file $f)"
  fi
}
function assert_file_not_exists() {
  local f="$1"; local msg="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  if [ -f "$f" ]; then
    report_fail "$msg (file should not exist $f)"
  fi
}
function assert_grep() {
  local pattern="$1"; local file="$2"; local msg="$3"
  TESTS_RUN=$((TESTS_RUN+1))
  if ! grep -qE "$pattern" "$file"; then
    report_fail "$msg (pattern '$pattern' not found in $file)"
  fi
}
function assert_not_grep() {
  local pattern="$1"; local file="$2"; local msg="$3"
  TESTS_RUN=$((TESTS_RUN+1))
  if grep -qE "$pattern" "$file"; then
    report_fail "$msg (pattern '$pattern' unexpectedly found in $file)"
  fi
}
# Isolated HOME
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
# Stub ssh-keygen
STUB_BIN="$TEST_HOME/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
OUT=""
EMAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) shift; OUT="$1" ;;
    -C) shift; EMAIL="$1" ;;
  esac
  shift
done
[ -z "$OUT" ] && echo "stub ssh-keygen missing -f" >&2 && exit 1
echo "FAKE_PRIVATE_KEY $EMAIL" > "$OUT"
echo "FAKE_PUBLIC_KEY $EMAIL" > "$OUT.pub"
echo "Generated stub key for $EMAIL"
EOF
chmod +x "$STUB_BIN/ssh-keygen"
export PATH="$STUB_BIN:$PATH"
CONFIG_FILE="$HOME/.ssh/config"
KEY_ALIAS="personal"
KEYFILE="$HOME/.ssh/id_ed25519_${KEY_ALIAS}"
### Test 1: add key (default HostName)
printf "\n%s\n%s\n" "$KEY_ALIAS" "user@example.com" | bash "$SSH_SCRIPT" add
assert_file_exists "$CONFIG_FILE" "Config file should be created"
assert_file_exists "$KEYFILE" "Private key should be created"
assert_file_exists "$KEYFILE.pub" "Public key should be created"
assert_grep "^Host ${KEY_ALIAS}$" "$CONFIG_FILE" "Host alias block present"
assert_grep "HostName github.com" "$CONFIG_FILE" "Default HostName applied"
assert_grep "IdentityFile $KEYFILE" "$CONFIG_FILE" "IdentityFile path recorded"
CONFIG_SNAPSHOT="$(cat "$CONFIG_FILE")"
### Test 2: re-add same key (should not duplicate block)
printf "\n%s\n%s\n" "$KEY_ALIAS" "user@example.com" | bash "$SSH_SCRIPT" add
count_hosts=$(grep -c "^Host ${KEY_ALIAS}$" "$CONFIG_FILE" || true)
assert_equals "$count_hosts" "1" "Re-adding should not duplicate Host block"
### Test 3: remove existing host
bash "$SSH_SCRIPT" remove "$KEY_ALIAS"
assert_not_grep "^Host ${KEY_ALIAS}$" "$CONFIG_FILE" "Host block removed"
assert_file_not_exists "$KEYFILE" "Private key removed"
assert_file_not_exists "$KEYFILE.pub" "Public key removed"
### Test 4: remove non-existent host (should leave config unchanged)
CONFIG_BEFORE_NON_EXIST="$(cat "$CONFIG_FILE")"
bash "$SSH_SCRIPT" remove missing
CONFIG_AFTER_NON_EXIST="$(cat "$CONFIG_FILE")"
assert_equals "$CONFIG_BEFORE_NON_EXIST" "$CONFIG_AFTER_NON_EXIST" "Config unchanged removing non-existent host"
### Test 5: remove without alias (expect usage + exit code 1)
set +e
output_no_alias=$(bash "$SSH_SCRIPT" remove 2>&1)
rc_no_alias=$?
set -e
assert_equals "$rc_no_alias" "1" "Remove without alias should exit 1"
echo "$output_no_alias" | grep -q "Missing HostAlias" || report_fail "Usage message expected for remove without alias"
### Test 6: help output
help_out=$(bash "$SSH_SCRIPT" help)
echo "$help_out" | grep -q "Commands" || report_fail "Help should contain 'Commands'"
### Test 7: add with space in alias (should fail)
set +e
output_space_alias=$(printf "\ninvalid alias\nuser@example.com\n" | bash "$SSH_SCRIPT" add 2>&1)
rc_space_alias=$?
set -e
assert_equals "$rc_space_alias" "1" "Add with space in alias should exit 1"
echo "$output_space_alias" | grep -q "cannot contain spaces" || report_fail "Space in alias should be rejected"
### Test 8: add with empty alias (should fail)
set +e
output_empty_alias=$(printf "\n\nuser@example.com\n" | bash "$SSH_SCRIPT" add 2>&1)
rc_empty_alias=$?
set -e
assert_equals "$rc_empty_alias" "1" "Add with empty alias should exit 1"
echo "$output_empty_alias" | grep -q "cannot be empty" || report_fail "Empty alias should be rejected"
### Test 9: add with empty email (should fail)
set +e
output_empty_email=$(printf "\npersonal2\n\n" | bash "$SSH_SCRIPT" add 2>&1)
rc_empty_email=$?
set -e
assert_equals "$rc_empty_email" "1" "Add with empty email should exit 1"
echo "$output_empty_email" | grep -q "Email cannot be empty" || report_fail "Empty email should be rejected"
### Test 10: unknown command
set +e
output_unknown=$(bash "$SSH_SCRIPT" unknown 2>&1)
rc_unknown=$?
set -e
assert_equals "$rc_unknown" "1" "Unknown command should exit 1"
echo "$output_unknown" | grep -q "Unknown command" || report_fail "Unknown command message expected"
echo "Tests run: $TESTS_RUN"
if [ "$FAILURES" -gt 0 ]; then
  echo "Failures: $FAILURES"
  exit 1
fi
echo "All tests passed."
rm -rf "$TEST_HOME" || true
### Test 11: list with config present
list_out=$(bash "$SSH_SCRIPT" list)
echo "$list_out" | grep -q "Current HostAliases" || report_fail "List should show header"
echo "$list_out" | grep -q "^${KEY_ALIAS}$" || report_fail "List should show added HostAlias"
### Test 12: list after removal (should not show alias)
bash "$SSH_SCRIPT" remove "$KEY_ALIAS"
list_out2=$(bash "$SSH_SCRIPT" list)
echo "$list_out2" | grep -q "Current HostAliases" || report_fail "List should show header after removal"
echo "$list_out2" | grep -v "^${KEY_ALIAS}$" || report_fail "List should not show removed HostAlias"
### Test 13: list with no config file
rm -f "$CONFIG_FILE"
list_out3=$(bash "$SSH_SCRIPT" list 2>&1)
echo "$list_out3" | grep -q "No SSH config file found" || report_fail "List should warn if config file missing"
