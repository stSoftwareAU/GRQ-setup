#!/bin/bash
# lib/per_user_password.sh
#
# Per-account password generation for the automated user accounts
# (rocket / sloth / elephant / ...). See issue #18.
#
# Why this exists
# ---------------
# The provisioning scripts previously took a single $AUTOMATED_PASSWORD on
# the command line and applied it verbatim to every automated user. The
# consequence was that disclosure of the password from any one channel —
# a leaked log line, a `chpasswd` argv observation, a backup of one
# account's shell history, a brute-force against any one account — handed
# the attacker every other automated account on the node. This is a
# defence-in-depth failure: there was no compartmentalisation between
# rocket/sloth/elephant despite each running its own privileged daemon.
#
# The helpers below generate a 32-byte base64 random password per user
# the first time they are asked for it, persist it in a root-owned
# 0600 file under $GRQ_PASSWORD_DIR, and return the persisted value on
# subsequent calls (so reruns are idempotent and do not silently rotate
# anyone's password).
#
# Variables (overridable by the caller / by tests)
# ------------------------------------------------
#   GRQ_PASSWORD_DIR    Directory holding <user>.secret files.
#                       Defaults to /var/lib/grq/passwords (Linux).
#                       MacOS/* setup scripts override to
#                       /var/root/grq/passwords (root's home on macOS).
#   GRQ_PASSWORD_OWNER  chown spec ("user:group") for the directory and
#                       each .secret file. Defaults to "root:root";
#                       MacOS callers pass "root:wheel". An empty value
#                       skips chown (used by tests that run as the
#                       current unprivileged user inside a tmpdir).
#   GRQ_SUDO            Privilege-elevation command prefix. Defaults to
#                       "sudo". Tests set it to "" so the functions run
#                       unprivileged against a tmpdir.
#
# This file is intended to be sourced, not executed.

# NB: use the ${VAR=default} form (not ${VAR:=default}). Tests set GRQ_SUDO
# to the empty string deliberately, so the variable is *set* but empty —
# the `:=` variant would overwrite it back to "sudo" and break the tests.
: "${GRQ_PASSWORD_DIR=/var/lib/grq/passwords}"
: "${GRQ_PASSWORD_OWNER=root:root}"
: "${GRQ_SUDO=sudo}"

# ensure_password_dir
# Creates $GRQ_PASSWORD_DIR with mode 0700 and the configured owner. Safe
# to call repeatedly. The directory is mode 0700 so unprivileged users on
# the host cannot enumerate which accounts exist by listing it.
ensure_password_dir() {
  # shellcheck disable=SC2086  # word splitting on GRQ_SUDO is intentional
  $GRQ_SUDO mkdir -p "$GRQ_PASSWORD_DIR"
  # shellcheck disable=SC2086
  $GRQ_SUDO chmod 700 "$GRQ_PASSWORD_DIR"
  if [[ -n "$GRQ_PASSWORD_OWNER" ]]; then
    # shellcheck disable=SC2086
    $GRQ_SUDO chown "$GRQ_PASSWORD_OWNER" "$GRQ_PASSWORD_DIR"
  fi
}

# get_or_create_user_password <username>
# Writes the per-user password to stdout, generating it (32-byte base64
# from openssl rand) and persisting it root-owned 0600 on first call.
# Returns 1 on missing username.
get_or_create_user_password() {
  local username="$1"
  if [[ -z "$username" ]]; then
    echo "ERROR: get_or_create_user_password requires a username" >&2
    return 1
  fi

  local pwfile="$GRQ_PASSWORD_DIR/${username}.secret"

  # shellcheck disable=SC2086
  if ! $GRQ_SUDO test -f "$pwfile"; then
    # Write under a 077 umask so the file is 0600 from the moment it
    # contains entropy. Avoids any window where the secret is world-
    # readable (e.g. if we created it first and chmod'd later).
    # shellcheck disable=SC2086
    $GRQ_SUDO sh -c "umask 077 && openssl rand -base64 32 > '$pwfile'"
    if [[ -n "$GRQ_PASSWORD_OWNER" ]]; then
      # shellcheck disable=SC2086
      $GRQ_SUDO chown "$GRQ_PASSWORD_OWNER" "$pwfile"
    fi
    # shellcheck disable=SC2086
    $GRQ_SUDO chmod 600 "$pwfile"
  fi
  # shellcheck disable=SC2086
  $GRQ_SUDO cat "$pwfile"
}
