#!/bin/bash
# Tests for lib/verify_installer.sh — supply-chain hardening for issue #16.
#
# These tests exercise the verifier helper directly: compute SHA-256 of a real
# file, accept a matching expected hash, reject a mismatching expected hash,
# and refuse to execute downloaded content whose hash does not match.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"
LIB_FILE="${REPO_DIR}/lib/verify_installer.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

ok() {
  printf '  ok   - %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '  FAIL - %s\n' "$1"
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$1")
}

assert_eq() {
  # $1=name $2=actual $3=expected
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1 (expected '$3', got '$2')"
  fi
}

assert_rc() {
  # $1=name $2=actual_rc $3=expected_rc
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1 (expected exit $3, got $2)"
  fi
}

if [[ ! -f "$LIB_FILE" ]]; then
  echo "FATAL: $LIB_FILE not found" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$LIB_FILE"

# --- compute_sha256 -----------------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf 'hello\n' > "$TMP/hello.txt"
# Known SHA-256 of "hello\n"
EXPECTED_HELLO="5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

actual=$(compute_sha256 "$TMP/hello.txt")
assert_eq "compute_sha256 matches known hash for 'hello\\n'" "$actual" "$EXPECTED_HELLO"

# --- verify_sha256 ------------------------------------------------------------

verify_sha256 "$TMP/hello.txt" "$EXPECTED_HELLO" >/dev/null 2>&1
assert_rc "verify_sha256 accepts matching hash" "$?" "0"

verify_sha256 "$TMP/hello.txt" "0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1
assert_rc "verify_sha256 rejects non-matching hash" "$?" "1"

# verify_sha256 error message should mention the mismatch
err_output=$(verify_sha256 "$TMP/hello.txt" "0000000000000000000000000000000000000000000000000000000000000000" 2>&1 || true)
if [[ "$err_output" == *"SHA-256 mismatch"* ]]; then
  ok "verify_sha256 reports SHA-256 mismatch in error message"
else
  fail "verify_sha256 reports SHA-256 mismatch in error message (got: $err_output)"
fi

# --- download_and_verify (offline, by stubbing curl) --------------------------
#
# We cannot reach the public installers from CI, and `curl --proto '=https'`
# correctly refuses file:// URLs. Stub `curl` to a function that copies a
# fixture file into place, then exercise the hash check.

# shellcheck disable=SC2317
_stub_curl_copy() {
  # Last arg of the verifier call is the -o output path; the URL is the
  # last positional. We just write the fixture content into "$out".
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o)
        out="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ -z "$out" ]]; then
    echo "stub curl: no -o argument" >&2
    return 1
  fi
  cp "$TMP/hello.txt" "$out"
}

curl() { _stub_curl_copy "$@"; }
export -f curl 2>/dev/null || true

download_and_verify "https://stub.test/hello" "$EXPECTED_HELLO" "$TMP/out.bin" >/dev/null 2>&1
rc=$?
assert_rc "download_and_verify accepts matching hash (curl stub)" "$rc" "0"
if [[ -f "$TMP/out.bin" ]]; then
  ok "download_and_verify leaves verified output file in place"
else
  fail "download_and_verify leaves verified output file in place"
fi

rm -f "$TMP/out.bin"
download_and_verify "https://stub.test/hello" "0000000000000000000000000000000000000000000000000000000000000000" "$TMP/out.bin" >/dev/null 2>&1
rc=$?
assert_rc "download_and_verify rejects non-matching hash (curl stub)" "$rc" "1"
if [[ ! -f "$TMP/out.bin" ]]; then
  ok "download_and_verify deletes output file on hash mismatch"
else
  fail "download_and_verify deletes output file on hash mismatch (file still present)"
fi

unset -f curl

# --- Pinned versions sanity ---------------------------------------------------

PINS_FILE="${REPO_DIR}/lib/pinned_versions.sh"
if [[ -f "$PINS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$PINS_FILE"

  # Every pinned hash must be a 64-char lowercase hex string.
  is_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

  for var in HOMEBREW_INSTALL_SHA256 RUSTUP_INSTALL_SHA256 DENO_INSTALL_SHA256; do
    val="${!var:-}"
    if is_sha256 "$val"; then
      ok "$var is a 64-char hex SHA-256"
    else
      fail "$var is not a 64-char hex SHA-256 (got: '$val')"
    fi
  done

  # Homebrew install URL must include the pinned commit SHA, not HEAD.
  if [[ "$HOMEBREW_INSTALL_URL" == *"$HOMEBREW_INSTALL_SHA"* ]]; then
    ok "HOMEBREW_INSTALL_URL includes pinned commit SHA"
  else
    fail "HOMEBREW_INSTALL_URL must reference HOMEBREW_INSTALL_SHA, not HEAD (got: $HOMEBREW_INSTALL_URL)"
  fi
  if [[ "$HOMEBREW_INSTALL_URL" == *"/HEAD/"* ]]; then
    fail "HOMEBREW_INSTALL_URL still references /HEAD/ — must use a pinned commit SHA"
  else
    ok "HOMEBREW_INSTALL_URL does not reference /HEAD/"
  fi
else
  fail "lib/pinned_versions.sh is missing"
fi

# --- Source script audit: no unpinned curl|sh patterns ------------------------

# The whole point of issue #16: there must be no remaining `curl ... | sh`
# (or `bash -c "$(curl ...)"`) calls in the maintained setup scripts.
audit_no_unpinned_curl_sh() {
  local file="$1"
  local label="$2"
  if [[ ! -f "$file" ]]; then
    fail "$label exists"
    return
  fi
  if grep -E 'curl[^|]*\|[[:space:]]*sh' "$file" >/dev/null 2>&1; then
    fail "$label has no unpinned 'curl ... | sh' pattern"
  else
    ok "$label has no unpinned 'curl ... | sh' pattern"
  fi
  if grep -F 'bash -c "$(curl' "$file" >/dev/null 2>&1; then
    fail "$label has no unpinned 'bash -c \"\$(curl ...)\"' pattern"
  else
    ok "$label has no unpinned 'bash -c \"\$(curl ...)\"' pattern"
  fi
  if grep -F 'raw.githubusercontent.com/Homebrew/install/HEAD' "$file" >/dev/null 2>&1; then
    fail "$label has no Homebrew /HEAD/ reference"
  else
    ok "$label has no Homebrew /HEAD/ reference"
  fi
}

audit_no_unpinned_curl_sh "${REPO_DIR}/MacOS/setup.sh"   "MacOS/setup.sh"
audit_no_unpinned_curl_sh "${REPO_DIR}/MacOS/add-user.sh" "MacOS/add-user.sh"
audit_no_unpinned_curl_sh "${REPO_DIR}/Ubuntu/setup.sh"  "Ubuntu/setup.sh"

# --- Summary ------------------------------------------------------------------

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
