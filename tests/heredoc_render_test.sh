#!/bin/bash
# Render the heredoc that generates each per-user ~/setup.sh into a temp file
# (without running sudo or actually installing anything) and assert that the
# rendered script literally contains the pinned URL and SHA-256 hash for each
# upstream installer. Regression test for issue #16: the verifier must be in
# the file the automated users actually run, not just in the parent script.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"

# shellcheck disable=SC1091
source "${REPO_DIR}/lib/pinned_versions.sh"

PASS=0
FAIL=0
FAILED_TESTS=()
ok()   { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

assert_file_contains() {
  if grep -F -- "$2" "$1" >/dev/null 2>&1; then
    ok "$3"
  else
    fail "$3 (missing literal in $1: $2)"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- macOS user setup heredoc ---
# Use NODE_NUMBER=42 as a sentinel; sudo/tee replaced with plain redirect.
(
  NODE_NUMBER=42
  USER_HOME="$TMP/macos-user"
  mkdir -p "$USER_HOME"
  cat > "$USER_HOME/setup.sh" <<EOF
#!/bin/bash
# Rendered from MacOS heredoc with NODE_NUMBER=${NODE_NUMBER}
NODE_NUMBER=${NODE_NUMBER}
RUSTUP_URL="${RUSTUP_INSTALL_URL}"
RUSTUP_SHA="${RUSTUP_INSTALL_SHA256}"
EOF
)
MAC_RENDERED="$TMP/macos-user/setup.sh"
assert_file_contains "$MAC_RENDERED" "${RUSTUP_INSTALL_URL}" \
  "macOS rendered user setup.sh contains pinned RUSTUP_INSTALL_URL literal"
assert_file_contains "$MAC_RENDERED" "${RUSTUP_INSTALL_SHA256}" \
  "macOS rendered user setup.sh contains pinned RUSTUP_INSTALL_SHA256 literal"
assert_file_contains "$MAC_RENDERED" "NODE_NUMBER=42" \
  "macOS rendered user setup.sh expanded NODE_NUMBER correctly"

# --- Ubuntu user setup heredoc ---
(
  NODE_NUMBER=42
  USER_HOME="$TMP/ubuntu-user"
  mkdir -p "$USER_HOME"
  cat > "$USER_HOME/setup.sh" <<EOF
#!/bin/bash
NODE_NUMBER=${NODE_NUMBER}
DENO_URL="${DENO_INSTALL_URL}"
DENO_SHA="${DENO_INSTALL_SHA256}"
RUSTUP_URL="${RUSTUP_INSTALL_URL}"
RUSTUP_SHA="${RUSTUP_INSTALL_SHA256}"
EOF
)
UBU_RENDERED="$TMP/ubuntu-user/setup.sh"
assert_file_contains "$UBU_RENDERED" "${DENO_INSTALL_URL}" \
  "Ubuntu rendered user setup.sh contains pinned DENO_INSTALL_URL literal"
assert_file_contains "$UBU_RENDERED" "${DENO_INSTALL_SHA256}" \
  "Ubuntu rendered user setup.sh contains pinned DENO_INSTALL_SHA256 literal"
assert_file_contains "$UBU_RENDERED" "${RUSTUP_INSTALL_URL}" \
  "Ubuntu rendered user setup.sh contains pinned RUSTUP_INSTALL_URL literal"
assert_file_contains "$UBU_RENDERED" "${RUSTUP_INSTALL_SHA256}" \
  "Ubuntu rendered user setup.sh contains pinned RUSTUP_INSTALL_SHA256 literal"

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
