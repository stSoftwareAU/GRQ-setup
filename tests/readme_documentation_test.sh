#!/bin/bash
# Tests for issue #27 — README documents development workflow.
#
# The README should describe how to:
#   1. Run the local quality gate (./quality.sh) and what it checks.
#   2. Where the unit tests live (tests/) and how to invoke them.
#   3. What the CI workflows in .github/workflows/ enforce.
#   4. The input-validation helper (lib/input_validation.sh, issue #19).
#
# It should also live alongside the canonical PR summary location
# (docs/archive/pr-summaries/) and not leave stale summaries scattered
# in docs/ root (Issue #2173).

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"
README="${REPO_DIR}/README.md"

PASS=0
FAIL=0
FAILED_TESTS=()

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

assert_contains() {
  if grep -F -- "$2" "$1" >/dev/null 2>&1; then
    ok "$3"
  else
    fail "$3 (missing in $1: $2)"
  fi
}

# --- 1. README exists --------------------------------------------------------
if [[ ! -f "$README" ]]; then
  fail "README.md exists"
  echo "Pass: $PASS  Fail: $FAIL"
  exit 1
fi

# --- 2. quality gate documented ---------------------------------------------
assert_contains "$README" 'quality.sh' \
  "README references quality.sh"
assert_contains "$README" 'markdownlint' \
  "README mentions markdownlint check"

# --- 3. tests directory documented ------------------------------------------
assert_contains "$README" 'tests/' \
  "README references the tests directory"

# --- 4. CI workflows documented ---------------------------------------------
assert_contains "$README" '.github/workflows' \
  "README references CI workflows directory"
assert_contains "$README" 'ShellCheck' \
  "README mentions ShellCheck CI workflow"

# --- 5. input validation helper documented ----------------------------------
assert_contains "$README" 'input_validation.sh' \
  "README references lib/input_validation.sh"

# --- 6. PR summary archive convention documented ----------------------------
assert_contains "$README" 'docs/archive/pr-summaries' \
  "README references the PR summary archive path"

# --- 7. No stale PR summaries left in docs/ root ----------------------------
shopt -s nullglob
stale=("${REPO_DIR}/docs/"pr-summary-*.md)
shopt -u nullglob
if (( ${#stale[@]} == 0 )); then
  ok "no stale pr-summary-*.md files in docs/ root"
else
  fail "stale pr-summary-*.md files remain in docs/ root: ${stale[*]}"
fi

echo ""
echo "Pass: $PASS  Fail: $FAIL"
if (( FAIL > 0 )); then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
exit 0
