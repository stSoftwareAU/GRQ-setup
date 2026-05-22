#!/bin/bash
# lib/input_validation.sh
#
# Input validators and XML-escape helper for the provisioning scripts.
# See issue #19.
#
# Why this exists
# ---------------
# MacOS/add-user.sh previously took $USERNAME and $NODE_NUMBER as CLI
# arguments and interpolated them directly into a LaunchDaemons plist
# path and the plist's XML body. Without validation, an operator who can
# influence the $USERNAME argument (for example via an unattended
# provisioning wrapper that reads it from a config file or remote API)
# could:
#
#   1. Smuggle path-traversal sequences (e.g. '../../etc/cron.d/x') into
#      "/Library/LaunchDaemons/com.lecklogic.${USERNAME}task.plist" and
#      have `sudo tee` write a root-owned file at an attacker-chosen
#      location.
#
#   2. Smuggle XML fragments (e.g. '</string><key>UserName</key>
#      <string>root</string><key>x</key><string>') into the plist body
#      and override the daemon's effective UID at next boot.
#
# The helpers in this file fail-closed on any input that does not match
# a conservative allowlist regex, and provide an xml_escape helper for
# any value that must be embedded in plist XML without round-trip risk.
#
# This file is intended to be sourced, not executed.

# validate_username <candidate>
# Accepts a lowercase POSIX-portable username (`[a-z][a-z0-9_-]{0,30}`),
# matching how the provisioning scripts use the value (lowercase service
# accounts like rocket/sloth/elephant). Prints an error to stderr and
# returns 1 on any other input.
validate_username() {
  local candidate="${1-}"
  if [[ "$candidate" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; then
    return 0
  fi
  echo "ERROR: Invalid username: must match ^[a-z][a-z0-9_-]{0,30}\$" >&2
  return 1
}

# validate_node_number <candidate>
# Accepts a non-empty decimal-digit string. Prints an error to stderr
# and returns 1 on any other input (empty, signed, hex, whitespace,
# embedded shell metacharacters, etc.).
validate_node_number() {
  local candidate="${1-}"
  if [[ "$candidate" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  echo "ERROR: Invalid node number: must match ^[0-9]+\$" >&2
  return 1
}

# xml_escape <value>
# Writes the XML-1.0 escaped form of <value> to stdout. Escapes & < > " '
# in that order — ampersand FIRST so that later substitutions never
# re-escape an already-escaped sequence (e.g. avoiding &amp;lt; from
# escaping the & in &lt;). Suitable for plist <string> bodies.
xml_escape() {
  local s="${1-}"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}
