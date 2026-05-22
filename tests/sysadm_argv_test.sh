#!/bin/bash
# Regression test for issue #15: the macOS provisioning scripts must NOT
# pass the per-user password as a command-line argument to sysadminctl.
# Anything on argv is world-readable via `ps -ef`, `/proc/<pid>/cmdline`
# and `proc_pidinfo(PROC_PIDARGS)`, so a single race-window observation
# from any unprivileged local process leaks every automated user's
# password.
#
# This test has three parts:
#   1. Static: confirm MacOS/setup.sh and MacOS/add-user.sh no longer
#      contain `-password "$..."` / `-newPassword "$..."` patterns and
#      instead delegate to lib/grq_sysadm.sh.
#   2. Static: confirm Ubuntu/setup.sh still uses the chpasswd stdin pipe
#      (the password never reaches chpasswd's argv).
#   3. Functional: drive lib/grq_sysadm.sh with a mocked sysadminctl and
#      verify the mock's recorded argv contains the literal "-" sentinel
#      and not the actual password.
#
# The functional check requires /usr/bin/expect, which ships with macOS
# but may not be present on Linux CI runners. The test soft-skips with a
# logged note when expect is missing — the static checks still run.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"

PASS=0
FAIL=0
FAILED_TESTS=()

ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }
skip() { printf '  skip - %s (%s)\n' "$1" "$2"; }

assert_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    ok "$name"
  else
    fail "$name (missing in $file: $needle)"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    fail "$name (forbidden literal still in $file: $needle)"
  else
    ok "$name"
  fi
}

assert_not_matches() {
  local file="$1" pattern="$2" name="$3"
  if grep -E -- "$pattern" "$file" >/dev/null 2>&1; then
    fail "$name (forbidden pattern still in $file: $pattern)"
  else
    ok "$name"
  fi
}

# ---------------------------------------------------------------------------
# 1. Static: helper exists, parent scripts use it
# ---------------------------------------------------------------------------

HELPER="${REPO_DIR}/lib/grq_sysadm.sh"
if [[ ! -f "$HELPER" ]]; then
  fail "lib/grq_sysadm.sh exists"
else
  ok "lib/grq_sysadm.sh exists"
  if [[ ! -x "$HELPER" ]]; then
    fail "lib/grq_sysadm.sh is executable"
  else
    ok "lib/grq_sysadm.sh is executable"
  fi
  if bash -n "$HELPER" < /dev/null; then
    ok "lib/grq_sysadm.sh passes bash -n"
  else
    fail "lib/grq_sysadm.sh passes bash -n"
  fi
fi

MAC_SETUP="${REPO_DIR}/MacOS/setup.sh"
MAC_ADD="${REPO_DIR}/MacOS/add-user.sh"
UBU_SETUP="${REPO_DIR}/Ubuntu/setup.sh"

for parent in "$MAC_SETUP" "$MAC_ADD"; do
  label="$(basename "$(dirname "$parent")")/$(basename "$parent")"
  if [[ ! -f "$parent" ]]; then
    fail "$label exists"
    continue
  fi
  # Must delegate to the helper.
  assert_contains "$parent" 'lib/grq_sysadm.sh' \
    "$label invokes lib/grq_sysadm.sh"
  # Must NOT pass any bash variable as the password value on argv.
  # We forbid: -password "$..." and -newPassword "$...".
  assert_not_matches "$parent" '-password +"\$[A-Za-z_]' \
    "$label no longer feeds sysadminctl -password via argv"
  assert_not_matches "$parent" '-newPassword +"\$[A-Za-z_]' \
    "$label no longer feeds sysadminctl -newPassword via argv"
done

# Ubuntu/setup.sh: the chpasswd pipe must still be the only place a
# password lands, and it must come from a per-user variable (not the
# deprecated shared $AUTOMATED_PASSWORD which is a regression we want to
# keep flagged).
if [[ -f "$UBU_SETUP" ]]; then
  assert_contains "$UBU_SETUP" '| sudo chpasswd' \
    "Ubuntu/setup.sh still pipes the password to chpasswd via stdin"
  assert_not_contains "$UBU_SETUP" 'chpasswd "$' \
    "Ubuntu/setup.sh does not pass the password on chpasswd's argv"
fi

# ---------------------------------------------------------------------------
# 2. Functional: drive the helper with a mocked sysadminctl
# ---------------------------------------------------------------------------

if [[ ! -f "$HELPER" ]]; then
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
fi

if ! command -v expect >/dev/null 2>&1; then
  skip "functional helper test" "/usr/bin/expect not installed"
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  # Mock sysadminctl: writes its argv (one per line) to $TMP/argv.log
  # and reads any prompt response from stdin (the pty under expect).
  cat > "$TMP/sysadminctl" <<'MOCK'
#!/bin/bash
LOG="${SYSADM_MOCK_LOG:-/tmp/sysadm_argv.log}"
{
  echo "---"
  for a in "$@"; do
    printf '%s\n' "$a"
  done
} >> "$LOG"
# If the caller used -password - or -newPassword -, emulate the
# interactive prompt so the helper's expect script feeds the secret over
# the pty. Read it back and log so the test can prove it never appeared
# on argv.
for ((i = 1; i <= $#; i++)); do
  prev="${!i}"
  next_idx=$((i + 1))
  next="${!next_idx-}"
  if [[ "$prev" == "-password" || "$prev" == "-newPassword" ]]; then
    if [[ "$next" == "-" ]]; then
      printf 'Password: ' >&2
      IFS= read -r pty_pw
      printf 'PTY_PW=%s\n' "$pty_pw" >> "$LOG"
    fi
  fi
done
exit 0
MOCK
  chmod +x "$TMP/sysadminctl"

  PWFILE="$TMP/secret"
  SECRET='Tr0ub4dor&3-correct horse battery staple'
  umask 077
  printf '%s' "$SECRET" > "$PWFILE"
  chmod 600 "$PWFILE"

  export SYSADM_MOCK_LOG="$TMP/argv.log"

  if GRQ_SYSADM_TEST=1 GRQ_SYSADM_BIN="$TMP/sysadminctl" \
       "$HELPER" --password-file "$PWFILE" add bob "Bob Builder" /Users/bob admin \
       >"$TMP/add.out" 2>"$TMP/add.err"; then
    ok "grq_sysadm.sh add returns success with mocked sysadminctl"
  else
    fail "grq_sysadm.sh add returns success with mocked sysadminctl (stderr: $(cat "$TMP/add.err" 2>/dev/null))"
  fi

  if grep -F -- "$SECRET" "$TMP/argv.log" >/dev/null 2>&1; then
    # The secret must only appear on the PTY_PW= line, never as an argv
    # entry.
    pty_count=$(grep -c "^PTY_PW=" "$TMP/argv.log" 2>/dev/null || echo 0)
    leaking=$(grep -vF "PTY_PW=" "$TMP/argv.log" | grep -F -- "$SECRET" >/dev/null 2>&1 && echo yes || echo no)
    if [[ "$leaking" == "no" && "$pty_count" -ge 1 ]]; then
      ok "password reached sysadminctl via pty, not argv (add)"
    else
      fail "password leaked onto sysadminctl argv (add): $(cat "$TMP/argv.log")"
    fi
  else
    fail "password was never delivered to sysadminctl mock (add): $(cat "$TMP/argv.log")"
  fi

  # The dash sentinel must be present on argv to prove we used
  # `-password -` form.
  if grep -Fxq -- "-" "$TMP/argv.log"; then
    ok "sysadminctl was invoked with -password - sentinel"
  else
    fail "sysadminctl was not invoked with -password - sentinel (argv log: $(cat "$TMP/argv.log"))"
  fi

  # Now exercise the reset path.
  : > "$TMP/argv.log"
  if GRQ_SYSADM_TEST=1 GRQ_SYSADM_BIN="$TMP/sysadminctl" \
       "$HELPER" --password-file "$PWFILE" reset bob admin \
       >"$TMP/reset.out" 2>"$TMP/reset.err"; then
    ok "grq_sysadm.sh reset returns success with mocked sysadminctl"
  else
    fail "grq_sysadm.sh reset returns success (stderr: $(cat "$TMP/reset.err" 2>/dev/null))"
  fi

  leaking=$(grep -vF "PTY_PW=" "$TMP/argv.log" | grep -F -- "$SECRET" >/dev/null 2>&1 && echo yes || echo no)
  if [[ "$leaking" == "no" ]]; then
    ok "password reached sysadminctl via pty, not argv (reset)"
  else
    fail "password leaked onto sysadminctl argv (reset): $(cat "$TMP/argv.log")"
  fi

  # Bad mode bits on the password file must be rejected.
  chmod 644 "$PWFILE"
  if GRQ_SYSADM_TEST=1 GRQ_SYSADM_BIN="$TMP/sysadminctl" \
       "$HELPER" --password-file "$PWFILE" add bob "Bob Builder" /Users/bob admin \
       >"$TMP/bad.out" 2>"$TMP/bad.err"; then
    fail "grq_sysadm.sh rejects password files that are not 0600"
  else
    ok "grq_sysadm.sh rejects password files that are not 0600"
  fi
  chmod 600 "$PWFILE"

  # Missing password file must be rejected.
  if GRQ_SYSADM_TEST=1 GRQ_SYSADM_BIN="$TMP/sysadminctl" \
       "$HELPER" --password-file "$TMP/does-not-exist" add bob "Bob" /Users/bob admin \
       >"$TMP/missing.out" 2>"$TMP/missing.err"; then
    fail "grq_sysadm.sh rejects a missing password file"
  else
    ok "grq_sysadm.sh rejects a missing password file"
  fi

  # Unknown subcommand must be rejected.
  if GRQ_SYSADM_TEST=1 GRQ_SYSADM_BIN="$TMP/sysadminctl" \
       "$HELPER" --password-file "$PWFILE" wibble bob admin \
       >"$TMP/wibble.out" 2>"$TMP/wibble.err"; then
    fail "grq_sysadm.sh rejects unknown subcommand"
  else
    ok "grq_sysadm.sh rejects unknown subcommand"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Functional: per_user_password.sh exposes ensure_user_password
# ---------------------------------------------------------------------------

LIB="${REPO_DIR}/lib/per_user_password.sh"
if [[ -f "$LIB" ]]; then
  TMP2=$(mktemp -d)
  GRQ_PASSWORD_DIR="$TMP2/passwords"
  GRQ_SUDO=""
  GRQ_PASSWORD_OWNER=""
  export GRQ_PASSWORD_DIR GRQ_SUDO GRQ_PASSWORD_OWNER
  # shellcheck disable=SC1090
  source "$LIB"

  if declare -f ensure_user_password >/dev/null 2>&1; then
    ok "ensure_user_password is defined in lib/per_user_password.sh"
    ensure_password_dir
    ensure_user_password "rocket" >/dev/null
    if [[ -f "$GRQ_PASSWORD_DIR/rocket.secret" ]]; then
      ok "ensure_user_password creates the per-user secret file"
    else
      fail "ensure_user_password creates the per-user secret file"
    fi
    OUT=$(ensure_user_password "sloth" 2>&1)
    if [[ -z "$OUT" ]]; then
      ok "ensure_user_password writes nothing to stdout (the secret stays on disk)"
    else
      fail "ensure_user_password writes nothing to stdout (got: $OUT)"
    fi
  else
    fail "ensure_user_password is defined in lib/per_user_password.sh"
  fi
  rm -rf "$TMP2"
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
