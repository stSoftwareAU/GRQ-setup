#!/bin/bash
# Tests for .github/workflows/shellcheck.yml — issue #25.
#
# Verifies the ShellCheck Lint workflow file exists with the structure the
# issue requires: triggered on pull_request, read-only contents permission,
# runs on ubuntu-latest, invokes ludeeus/action-shellcheck pinned to a
# 40-char commit SHA, scans the whole repository, and uses warning severity.
# Also runs shellcheck locally at warning severity to confirm the workflow
# will pass in CI.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"
WF_FILE="${REPO_DIR}/.github/workflows/shellcheck.yml"

PASS=0
FAIL=0
FAILED_TESTS=()

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

# --- file exists -------------------------------------------------------------
if [[ -f "$WF_FILE" ]]; then
  ok "shellcheck.yml workflow file exists"
else
  fail "shellcheck.yml workflow file exists"
  echo "FATAL: $WF_FILE not found" >&2
  exit 1
fi

# --- required content --------------------------------------------------------
assert_contains() {
  # $1=name $2=pattern (extended regex) $3=file
  if grep -Eq "$2" "$3"; then
    ok "$1"
  else
    fail "$1"
  fi
}

assert_contains "workflow name declared" '^name:[[:space:]]*ShellCheck' "$WF_FILE"
assert_contains "triggered on pull_request" '^on:|pull_request:' "$WF_FILE"
assert_contains "permissions contents: read" 'contents:[[:space:]]*read' "$WF_FILE"
assert_contains "runs on ubuntu-latest" 'runs-on:[[:space:]]*ubuntu-latest' "$WF_FILE"
assert_contains "uses ludeeus/action-shellcheck" 'ludeeus/action-shellcheck@' "$WF_FILE"
assert_contains "warning severity configured" 'severity:[[:space:]]*warning' "$WF_FILE"
assert_contains "scandir set to repository root" 'scandir:[[:space:]]*\.' "$WF_FILE"

# Third-party action SHA pinning (40-char hex), per Issue #1613.
if grep -Eq 'ludeeus/action-shellcheck@[0-9a-f]{40}' "$WF_FILE"; then
  ok "action-shellcheck pinned to 40-char commit SHA"
else
  fail "action-shellcheck pinned to 40-char commit SHA"
fi

if grep -Eq 'actions/checkout@[0-9a-f]{40}' "$WF_FILE"; then
  ok "actions/checkout pinned to 40-char commit SHA"
else
  fail "actions/checkout pinned to 40-char commit SHA"
fi

# --- local shellcheck run at warning severity --------------------------------
# Skip if shellcheck is not installed (e.g. CI runner without it); the
# GitHub workflow itself is the source of truth in that case.
if command -v shellcheck >/dev/null 2>&1; then
  # bash 3.2 (macOS) lacks `mapfile`, so collect script paths into a
  # space-separated string and rely on word-splitting. Repo paths
  # contain no spaces.
  SCRIPTS=$(find "$REPO_DIR" -type f \( -name '*.sh' -o -name '*.bash' \) -not -path '*/.git/*')
  # shellcheck disable=SC2086
  if shellcheck --severity=warning $SCRIPTS >/tmp/shellcheck_workflow_test.$$ 2>&1; then
    ok "shellcheck --severity=warning passes on repository shell scripts"
    rm -f /tmp/shellcheck_workflow_test.$$
  else
    fail "shellcheck --severity=warning passes on repository shell scripts"
    echo "    shellcheck output:"
    sed 's/^/      /' /tmp/shellcheck_workflow_test.$$
    rm -f /tmp/shellcheck_workflow_test.$$
  fi
else
  printf '  skip - shellcheck not installed locally\n'
fi

# --- summary -----------------------------------------------------------------
echo
echo "shellcheck_workflow_test.sh: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
exit 0
