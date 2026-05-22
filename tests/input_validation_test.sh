#!/bin/bash
# Regression test for issue #19: the $USERNAME and $NODE_NUMBER CLI arguments
# to MacOS/add-user.sh were interpolated unvalidated into a LaunchDaemons plist
# path and XML body. lib/input_validation.sh now provides reusable validators
# and an XML-escape helper so the provisioning scripts can fail-closed on
# attacker-controlled input.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"

# shellcheck disable=SC1091
source "${REPO_DIR}/lib/input_validation.sh"

PASS=0
FAIL=0
FAILED_TESTS=()
ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

assert_rc() {
  # $1=expected_rc $2=actual_rc $3=test_name
  if [[ "$1" == "$2" ]]; then
    ok "$3"
  else
    fail "$3 (expected rc=$1, got rc=$2)"
  fi
}

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    ok "$3"
  else
    fail "$3 (expected '$2', got '$1')"
  fi
}

# --- validate_username ------------------------------------------------------

# Happy path: typical automated-user names used by the provisioning scripts.
for u in rocket sloth elephant a a1 a_b user-01 svc_acct abc123 z; do
  validate_username "$u" >/dev/null 2>&1; rc=$?
  assert_rc 0 "$rc" "validate_username accepts '$u'"
done

# Reject empty / leading digit / uppercase / leading hyphen / overlong.
for u in "" "1abc" "Abc" "-abc" "abcdefghijklmnopqrstuvwxyzABCDE" "abcdefghijklmnopqrstuvwxyz01234567"; do
  validate_username "$u" >/dev/null 2>&1; rc=$?
  assert_rc 1 "$rc" "validate_username rejects '$u'"
done

# Attack patterns from the issue body: path traversal, XML injection, shell
# metacharacters. All must be rejected with rc=1 — these are the very inputs
# that would have written a plist outside /Library/LaunchDaemons/ or smuggled
# a `<key>UserName</key><string>root</string>` override into the plist body.
attack_inputs=(
  "../../etc/cron.d/x"
  "../etc/passwd"
  "user/../../root"
  "user;rm -rf /"
  "user with space"
  "user\$IFS"
  "user\`whoami\`"
  '</string><key>UserName</key><string>root</string><key>x</key><string>'
  "user&amp;"
  "user<tag>"
  $'user\nname'
)
for u in "${attack_inputs[@]}"; do
  validate_username "$u" >/dev/null 2>&1; rc=$?
  assert_rc 1 "$rc" "validate_username rejects attack input: ${u:0:32}…"
done

# --- validate_node_number ---------------------------------------------------

for n in 0 1 12 99 1000; do
  validate_node_number "$n" >/dev/null 2>&1; rc=$?
  assert_rc 0 "$rc" "validate_node_number accepts '$n'"
done

for n in "" "-1" "1.5" "12a" "0x1" "abc" "1 2" $'1\n2'; do
  validate_node_number "$n" >/dev/null 2>&1; rc=$?
  assert_rc 1 "$rc" "validate_node_number rejects '$n'"
done

# --- xml_escape -------------------------------------------------------------

# Build the test inputs in shell variables first so we don't have to wrangle
# nested quoting inside the assert_eq invocations.
plain_in='plain'                ; plain_out='plain'
amp_in='a & b'                  ; amp_out='a &amp; b'
ang_in='<tag>'                  ; ang_out='&lt;tag&gt;'
dq_in='"quoted"'                ; dq_out='&quot;quoted&quot;'
apo_in="it's"                   ; apo_out='it&apos;s'
# Ampersand must be escaped first; otherwise a literal & in the input would
# end up double-escaped (&amp;lt;) when subsequent rules ran.
ord_in='<a & b>'                ; ord_out='&lt;a &amp; b&gt;'

assert_eq "$(xml_escape "$plain_in")" "$plain_out" "xml_escape passes plain text"
assert_eq "$(xml_escape "$amp_in")"   "$amp_out"   "xml_escape escapes ampersand"
assert_eq "$(xml_escape "$ang_in")"   "$ang_out"   "xml_escape escapes angle brackets"
assert_eq "$(xml_escape "$dq_in")"    "$dq_out"    "xml_escape escapes double quotes"
assert_eq "$(xml_escape "$apo_in")"   "$apo_out"   "xml_escape escapes apostrophe"
assert_eq "$(xml_escape "$ord_in")"   "$ord_out"   "xml_escape orders ampersand first"
# The attack payload from the issue body must round-trip into pure text — no
# stray closing </string> tag must survive into the rendered plist.
inj='</string><key>UserName</key><string>root</string><key>x</key><string>'
escaped="$(xml_escape "$inj")"
case "$escaped" in
  *"</string>"*) fail "xml_escape neutralises injection </string> sequence" ;;
  *"<key>"*)     fail "xml_escape neutralises injection <key> sequence" ;;
  *)             ok   "xml_escape neutralises injection sequences" ;;
esac

# --- Integration: add-user.sh exits non-zero on bad USERNAME ---------------
# We cannot run the whole script (it calls sudo, sysadminctl, etc.), but we
# CAN check that the early-validation guard fires before any privileged work
# by running the script with an attack USERNAME and asserting it exits 1 with
# an "Invalid username" message on stderr before any sudo invocation.

ADD_USER_SCRIPT="${REPO_DIR}/MacOS/add-user.sh"

# Stub PATH so any accidental sudo/dscl/etc. call is visible.
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/sudo" <<'STUB'
#!/bin/bash
echo "STUB-SUDO-CALLED: $*" >&2
exit 99
STUB
cat > "$STUB_DIR/dscl" <<'STUB'
#!/bin/bash
echo "STUB-DSCL-CALLED" >&2
exit 99
STUB
chmod +x "$STUB_DIR/sudo" "$STUB_DIR/dscl"

run_add_user() {
  # Run with a clean PATH whose only sudo is our stub, so a failure to
  # validate would produce an obvious STUB-SUDO-CALLED message we can grep.
  PATH="$STUB_DIR:/usr/bin:/bin" bash "$ADD_USER_SCRIPT" "$@" 2>&1
}

# Path-traversal attack input — must be rejected before any sudo call.
out=$(run_add_user '../../etc/cron.d/x' 12 'pw'); rc=$?
assert_rc 1 "$rc" "add-user.sh exits 1 on path-traversal USERNAME"
case "$out" in
  *"Invalid username"*) ok   "add-user.sh reports 'Invalid username' on bad input" ;;
  *)                    fail "add-user.sh did not print 'Invalid username' (got: ${out:0:200})" ;;
esac
case "$out" in
  *"STUB-SUDO-CALLED"*) fail "add-user.sh invoked sudo before validating USERNAME" ;;
  *)                    ok   "add-user.sh did not invoke sudo before validation" ;;
esac

# XML-injection attack input — must be rejected before any sudo call.
inj='</string><key>UserName</key><string>root</string><key>x</key><string>'
out=$(run_add_user "$inj" 12 'pw'); rc=$?
assert_rc 1 "$rc" "add-user.sh exits 1 on XML-injection USERNAME"
case "$out" in
  *"STUB-SUDO-CALLED"*) fail "add-user.sh invoked sudo on XML-injection USERNAME" ;;
  *)                    ok   "add-user.sh refused XML-injection USERNAME before sudo" ;;
esac

# Non-numeric NODE_NUMBER must also be rejected.
out=$(run_add_user 'rocket' '12; rm -rf /' 'pw'); rc=$?
assert_rc 1 "$rc" "add-user.sh exits 1 on non-numeric NODE_NUMBER"
case "$out" in
  *"Invalid node number"*) ok "add-user.sh reports 'Invalid node number' on bad input" ;;
  *) fail "add-user.sh did not print 'Invalid node number' (got: ${out:0:200})" ;;
esac

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
