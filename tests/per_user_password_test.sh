#!/bin/bash
# Regression test for issue #18: the provisioning scripts must NOT pass a
# single shared $AUTOMATED_PASSWORD to every automated user account they
# create. Each automated account must have its own randomly generated
# password stored in a root-owned 0600 file.
#
# This test has two parts:
#   1. Functional: source lib/per_user_password.sh and exercise the helper
#      functions with a temporary directory and GRQ_SUDO="" (no sudo
#      required, so the test runs in CI/dev).
#   2. Static: confirm the parent setup scripts source the lib and no longer
#      pass the shared $AUTOMATED_PASSWORD to sysadminctl / chpasswd.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"

PASS=0
FAIL=0
FAILED_TESTS=()
ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

assert_eq() {
  # $1=actual $2=expected $3=test_name
  if [[ "$1" == "$2" ]]; then
    ok "$3"
  else
    fail "$3 (expected '$2', got '$1')"
  fi
}

assert_ne() {
  # $1=a $2=b $3=test_name (passes when a != b)
  if [[ "$1" != "$2" ]]; then
    ok "$3"
  else
    fail "$3 (both values are '$1')"
  fi
}

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

# ---------------------------------------------------------------------------
# 1. Functional tests against lib/per_user_password.sh
# ---------------------------------------------------------------------------

LIB="${REPO_DIR}/lib/per_user_password.sh"
if [[ ! -f "$LIB" ]]; then
  fail "lib/per_user_password.sh exists"
else
  ok "lib/per_user_password.sh exists"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  # Run the helper without root by overriding the directory and dropping sudo.
  GRQ_PASSWORD_DIR="$TMP/passwords"
  GRQ_SUDO=""
  GRQ_PASSWORD_OWNER="" # skip chown — current user owns everything in TMP
  export GRQ_PASSWORD_DIR GRQ_SUDO GRQ_PASSWORD_OWNER
  # shellcheck disable=SC1090
  source "$LIB"

  ensure_password_dir
  if [[ -d "$GRQ_PASSWORD_DIR" ]]; then
    ok "ensure_password_dir creates the directory"
  else
    fail "ensure_password_dir creates the directory"
  fi

  PW_ROCKET_1=$(get_or_create_user_password "rocket")
  if [[ -n "$PW_ROCKET_1" ]]; then
    ok "get_or_create_user_password returns a non-empty password on first call"
  else
    fail "get_or_create_user_password returns a non-empty password on first call"
  fi

  # File must be 0600
  PWFILE="$GRQ_PASSWORD_DIR/rocket.secret"
  if [[ -f "$PWFILE" ]]; then
    ok "per-user password file is created on disk"
    PERM=$(stat -f '%Lp' "$PWFILE" 2>/dev/null || stat -c '%a' "$PWFILE" 2>/dev/null)
    assert_eq "$PERM" "600" "per-user password file is mode 600"
  else
    fail "per-user password file is created on disk"
  fi

  # Idempotent: second call returns the same password
  PW_ROCKET_2=$(get_or_create_user_password "rocket")
  assert_eq "$PW_ROCKET_2" "$PW_ROCKET_1" \
    "get_or_create_user_password is idempotent for the same user"

  # Different users get different passwords
  PW_SLOTH=$(get_or_create_user_password "sloth")
  PW_ELEPHANT=$(get_or_create_user_password "elephant")
  assert_ne "$PW_SLOTH" "$PW_ROCKET_1" \
    "rocket and sloth get different passwords"
  assert_ne "$PW_ELEPHANT" "$PW_ROCKET_1" \
    "rocket and elephant get different passwords"
  assert_ne "$PW_ELEPHANT" "$PW_SLOTH" \
    "sloth and elephant get different passwords"

  # Missing username argument fails fast
  if get_or_create_user_password "" 2>/dev/null; then
    fail "get_or_create_user_password rejects an empty username"
  else
    ok "get_or_create_user_password rejects an empty username"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Static checks on the parent setup scripts
# ---------------------------------------------------------------------------

MAC_SETUP="$REPO_DIR/MacOS/setup.sh"
MAC_ADD="$REPO_DIR/MacOS/add-user.sh"
UBU_SETUP="$REPO_DIR/Ubuntu/setup.sh"

for parent in "$MAC_SETUP" "$MAC_ADD" "$UBU_SETUP"; do
  label="$(basename "$(dirname "$parent")")/$(basename "$parent")"
  if [[ ! -f "$parent" ]]; then
    fail "$label exists"
    continue
  fi
  assert_contains "$parent" 'lib/per_user_password.sh' \
    "$label sources lib/per_user_password.sh"
  assert_contains "$parent" 'get_or_create_user_password' \
    "$label calls get_or_create_user_password"
  assert_not_contains "$parent" '-password "$AUTOMATED_PASSWORD"' \
    "$label no longer hands shared \$AUTOMATED_PASSWORD to sysadminctl -addUser"
  assert_not_contains "$parent" '-newPassword "$AUTOMATED_PASSWORD"' \
    "$label no longer hands shared \$AUTOMATED_PASSWORD to sysadminctl -resetPasswordFor"
  assert_not_contains "$parent" '"$USERNAME:$AUTOMATED_PASSWORD"' \
    "$label no longer pipes shared \$AUTOMATED_PASSWORD into chpasswd"
done

# Platform-specific password store locations
assert_contains "$MAC_SETUP" '/var/root/grq/passwords' \
  "MacOS/setup.sh uses /var/root/grq/passwords"
assert_contains "$MAC_ADD"   '/var/root/grq/passwords' \
  "MacOS/add-user.sh uses /var/root/grq/passwords"
assert_contains "$UBU_SETUP" '/var/lib/grq/passwords' \
  "Ubuntu/setup.sh uses /var/lib/grq/passwords"

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
