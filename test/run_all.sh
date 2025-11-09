#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT_DIR/test"

PASS=0
FAIL=0
declare -a RESULTS

run_test() {
  local script="$1"
  echo "==> Running $script" >&2
  set +e
  bash "$script"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    RESULTS+=("PASS $(basename "$script")")
    PASS=$((PASS+1))
  else
    RESULTS+=("FAIL $(basename "$script") (rc=$rc)")
    FAIL=$((FAIL+1))
  fi
}

run_test "$TEST_DIR/test_ssh.sh"
run_test "$TEST_DIR/test_install.sh"

echo "\nSummary:" >&2
for line in "${RESULTS[@]}"; do echo "$line" >&2; done
echo "Passed: $PASS  Failed: $FAIL" >&2

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
