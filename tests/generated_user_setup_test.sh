#!/bin/bash
# Tests that the heredoc-generated per-user setup scripts (the ones written to
# ~/setup.sh on each automated user during provisioning) actually carry the
# pinned hashes and the verifier function. Regression test for issue #16.
#
# We do NOT run the parent setup scripts (they need sudo + real machines).
# Instead, we grep the source of each parent script to confirm the heredoc
# bodies include the supply-chain hardening.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"

PASS=0
FAIL=0
FAILED_TESTS=()

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

assert_contains() {
  # $1=file $2=needle $3=test_name
  if grep -F -- "$2" "$1" >/dev/null 2>&1; then
    ok "$3"
  else
    fail "$3 (missing in $1: $2)"
  fi
}

assert_not_contains() {
  # $1=file $2=needle $3=test_name
  if grep -F -- "$2" "$1" >/dev/null 2>&1; then
    fail "$3 (forbidden literal still in $1: $2)"
  else
    ok "$3"
  fi
}

# Each parent setup script must:
#   1. source lib/pinned_versions.sh (so the heredoc can expand the pinned
#      URL/hash variables).
#   2. embed the _grq_verify_install helper in the heredoc body.
#   3. reference the pinned URL and hash variables, not literal upstream URLs.
#   4. NOT carry the old unpinned `curl ... | sh` calls anywhere.

for parent in \
    "${REPO_DIR}/MacOS/setup.sh" \
    "${REPO_DIR}/MacOS/add-user.sh" \
    "${REPO_DIR}/Ubuntu/setup.sh"; do
  label="$(basename "$(dirname "$parent")")/$(basename "$parent")"
  if [[ ! -f "$parent" ]]; then
    fail "$label exists"
    continue
  fi
  assert_contains "$parent" 'lib/pinned_versions.sh' \
    "$label sources lib/pinned_versions.sh"
  assert_contains "$parent" '_grq_verify_install' \
    "$label embeds the _grq_verify_install helper"
  assert_not_contains "$parent" 'curl --proto '"'"'=https'"'"' --tlsv1.2 -sSf https://sh.rustup.rs | sh' \
    "$label removed the old unpinned rustup pipe-to-sh"
  assert_not_contains "$parent" 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh' \
    "$label removed the old unpinned rustup pipe-to-sh (double-quoted variant)"
done

# Ubuntu/setup.sh also installs Deno — it must reference DENO_INSTALL_URL.
UBUNTU="${REPO_DIR}/Ubuntu/setup.sh"
assert_contains "$UBUNTU" 'DENO_INSTALL_URL' \
  "Ubuntu/setup.sh references DENO_INSTALL_URL"
assert_contains "$UBUNTU" 'DENO_INSTALL_SHA256' \
  "Ubuntu/setup.sh references DENO_INSTALL_SHA256"
assert_not_contains "$UBUNTU" 'curl -fsSL https://deno.land/install.sh | sh' \
  "Ubuntu/setup.sh removed the old unpinned deno pipe-to-sh"

# rustup pinned references
for parent in \
    "${REPO_DIR}/MacOS/setup.sh" \
    "${REPO_DIR}/MacOS/add-user.sh" \
    "${REPO_DIR}/Ubuntu/setup.sh"; do
  label="$(basename "$(dirname "$parent")")/$(basename "$parent")"
  assert_contains "$parent" 'RUSTUP_INSTALL_URL' \
    "$label references RUSTUP_INSTALL_URL"
  assert_contains "$parent" 'RUSTUP_INSTALL_SHA256' \
    "$label references RUSTUP_INSTALL_SHA256"
done

# MacOS/setup.sh must verify Homebrew before installing it.
MAC="${REPO_DIR}/MacOS/setup.sh"
assert_contains "$MAC" 'download_and_verify "${HOMEBREW_INSTALL_URL}"' \
  "MacOS/setup.sh verifies Homebrew installer before executing"
assert_contains "$MAC" 'lib/verify_installer.sh' \
  "MacOS/setup.sh sources lib/verify_installer.sh"

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
