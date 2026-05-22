#!/bin/bash
# lib/verify_installer.sh
#
# Supply-chain hardening for external install scripts (issue #16).
#
# Provides helpers to download an installer over strict TLS, compute its
# SHA-256, compare against a hash pinned in lib/pinned_versions.sh, and refuse
# to execute the script if the hash does not match. This converts the
# `curl ... | sh` anti-pattern into a deliberate, human-reviewed trust
# decision: a compromise of the upstream installer or the TLS path causes the
# hash to mismatch and aborts the install instead of silently running
# attacker-controlled bash with sudo rights.
#
# This file is intended to be sourced, not executed.

# compute_sha256 <file>
# Prints the SHA-256 of <file> as a 64-char lowercase hex string. Uses
# `shasum -a 256` on macOS and `sha256sum` on Linux. Returns 2 if neither is
# available.
compute_sha256() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo "ERROR: no SHA-256 utility found (need shasum or sha256sum)" >&2
    return 2
  fi
}

# verify_sha256 <file> <expected_hex>
# Returns 0 if the file's SHA-256 matches <expected_hex>, 1 otherwise.
# Writes a diagnostic to stderr on mismatch.
verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual=$(compute_sha256 "$file") || return 2
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: SHA-256 mismatch for $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
  return 0
}

# download_and_verify <url> <expected_sha256> <output_path>
# Downloads <url> with strict TLS (`--proto '=https' --tlsv1.2`) to
# <output_path>, then verifies its SHA-256 matches <expected_sha256>. On
# mismatch the output file is deleted and the function returns non-zero so
# the caller never executes attacker-controlled content.
download_and_verify() {
  local url="$1"
  local expected="$2"
  local out="$3"

  echo "Fetching $url"
  if ! curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$out"; then
    echo "ERROR: failed to download $url" >&2
    rm -f "$out"
    return 1
  fi

  if ! verify_sha256 "$out" "$expected"; then
    echo "ERROR: refusing to execute $url — downloaded content does not match the pinned SHA-256." >&2
    echo "       If the upstream installer was updated intentionally, audit the new script and refresh" >&2
    echo "       the pinned hash in lib/pinned_versions.sh as a deliberate, human-reviewed trust decision." >&2
    rm -f "$out"
    return 1
  fi
  return 0
}

# fetch_verified_installer <url> <expected_sha256> <output_path>
# Convenience alias kept for readability at call sites.
fetch_verified_installer() {
  download_and_verify "$@"
}
