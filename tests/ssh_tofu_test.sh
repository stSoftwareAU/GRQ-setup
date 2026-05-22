#!/bin/bash
# Tests for issue #17 — SSH host-key TOFU hardening on LAN bootstrap.
#
# Each generated per-user ~/setup.sh must:
#   1. NOT use `ssh-copy-id -f` (the -f flag silently overwrites known_hosts
#      and removes the safety prompt on key change).
#   2. Pass `-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts`
#      to every ssh and ssh-copy-id invocation to the admin hosts.
#   3. Reference the pre-distributed /etc/ssh/ssh_known_hosts file so that
#      the first connection is verified against an out-of-band fingerprint,
#      not blindly trusted via TOFU.
#
# Each parent provisioning script (MacOS/setup.sh, MacOS/add-user.sh,
# Ubuntu/setup.sh) must:
#   4. Install lib/admin_known_hosts to /etc/ssh/ssh_known_hosts with
#      root:wheel (macOS) or root:root (Ubuntu) ownership and 0644 mode.
#   5. Source the admin known_hosts template that ships with the repo.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"

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

assert_not_contains() {
  if grep -F -- "$2" "$1" >/dev/null 2>&1; then
    fail "$3 (forbidden literal still in $1: $2)"
  else
    ok "$3"
  fi
}

# --- 1. lib/admin_known_hosts ships with the repo ----------------------------
KNOWN_HOSTS_TEMPLATE="${REPO_DIR}/lib/admin_known_hosts"
if [[ -f "$KNOWN_HOSTS_TEMPLATE" ]]; then
  ok "lib/admin_known_hosts template exists"
else
  fail "lib/admin_known_hosts template exists"
fi

# --- 2. Each parent setup script installs the known_hosts file ---------------
for parent in \
    "${REPO_DIR}/MacOS/setup.sh" \
    "${REPO_DIR}/MacOS/add-user.sh" \
    "${REPO_DIR}/Ubuntu/setup.sh"; do
  label="$(basename "$(dirname "$parent")")/$(basename "$parent")"
  if [[ ! -f "$parent" ]]; then
    fail "$label exists"
    continue
  fi
  assert_contains "$parent" '/etc/ssh/ssh_known_hosts' \
    "$label installs /etc/ssh/ssh_known_hosts"
  assert_contains "$parent" 'admin_known_hosts' \
    "$label references lib/admin_known_hosts template"
done

# --- 3. Generated user setup.sh body: no `ssh-copy-id -f`, strict hostkey ----
# The heredoc body is part of each parent script source. Grep the parent files.
for parent in \
    "${REPO_DIR}/MacOS/setup.sh" \
    "${REPO_DIR}/MacOS/add-user.sh" \
    "${REPO_DIR}/Ubuntu/setup.sh"; do
  label="$(basename "$(dirname "$parent")")/$(basename "$parent")"
  [[ -f "$parent" ]] || continue

  assert_not_contains "$parent" 'ssh-copy-id -f nigel@' \
    "$label dropped ssh-copy-id -f flag"
  assert_contains "$parent" 'StrictHostKeyChecking=yes' \
    "$label enforces StrictHostKeyChecking=yes"
  assert_contains "$parent" 'UserKnownHostsFile=/etc/ssh/ssh_known_hosts' \
    "$label references UserKnownHostsFile=/etc/ssh/ssh_known_hosts"
done

# --- 4. The known_hosts template documents how to populate it ----------------
if [[ -f "$KNOWN_HOSTS_TEMPLATE" ]]; then
  assert_contains "$KNOWN_HOSTS_TEMPLATE" '10.0.0.11' \
    "admin_known_hosts mentions 10.0.0.11"
  assert_contains "$KNOWN_HOSTS_TEMPLATE" '10.0.0.89' \
    "admin_known_hosts mentions 10.0.0.89"
  assert_contains "$KNOWN_HOSTS_TEMPLATE" 'ssh-keyscan' \
    "admin_known_hosts documents ssh-keyscan workflow"
fi

# --- 5. README documents the out-of-band fingerprint verification step ------
README="${REPO_DIR}/README.md"
if [[ -f "$README" ]]; then
  assert_contains "$README" 'admin_known_hosts' \
    "README references lib/admin_known_hosts"
  assert_contains "$README" 'fingerprint' \
    "README documents fingerprint verification"
else
  fail "README.md exists"
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
