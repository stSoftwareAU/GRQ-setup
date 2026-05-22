#!/bin/bash
# lib/grq_sysadm.sh
#
# Issue #15: drive macOS `sysadminctl` for user creation / password reset
# without ever putting the password on argv.
#
# Background
# ----------
# `sysadminctl -addUser ... -password "$pw" ...` and
# `sysadminctl -resetPasswordFor ... -newPassword "$pw" ...` both bake
# the secret into the spawned process's argv vector, which is readable
# by every local user via `ps -ef`, `/proc/<pid>/cmdline`,
# `ps -o command`, and `proc_pidinfo(PROC_PIDARGS)`. A single
# race-window observation by any unprivileged local process is
# sufficient to capture the cleartext password during the provisioning
# window.
#
# Approach
# --------
# When called with `-password -` (or `-newPassword -`), `sysadminctl`
# prompts on /dev/tty for the value. This helper:
#   * runs as root (invoked via `sudo`), so it can read the persisted
#     per-user secret at /var/root/grq/passwords/<user>.secret directly
#     — the caller does not need to materialise the password into a
#     bash variable or a transient temp file in user space;
#   * uses /usr/bin/expect to allocate a pty, spawn sysadminctl with
#     `-password -` / `-newPassword -`, and feed the secret over the
#     pty when the prompt appears. The secret only ever exists in the
#     helper's own memory and in the pty buffer between expect and
#     sysadminctl — it is never on any argv.
#
# Usage
# -----
#   sudo lib/grq_sysadm.sh --password-file PATH add  USERNAME FULLNAME HOME ADMIN_USER
#   sudo lib/grq_sysadm.sh --password-file PATH reset USERNAME ADMIN_USER
#
# The password file must be mode 0600. The helper does not delete it
# — the caller owns its lifetime (and the persisted /var/root/grq/...
# files are kept across reruns for idempotency, see issue #18).
#
# Test hooks
# ----------
# The functional test in tests/sysadm_argv_test.sh drives this helper
# unprivileged with a mocked `sysadminctl`. Two env knobs:
#   GRQ_SYSADM_TEST=1   skip the EUID-must-be-0 guard
#   GRQ_SYSADM_BIN=PATH override the sysadminctl binary path

set -u

: "${GRQ_SYSADM_TEST=}"
: "${GRQ_SYSADM_BIN=/usr/sbin/sysadminctl}"
: "${GRQ_SYSADM_EXPECT=/usr/bin/expect}"
: "${GRQ_SYSADM_TIMEOUT=60}"

die() { printf '%s\n' "$*" >&2; exit 1; }

if [[ -z "$GRQ_SYSADM_TEST" && "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "ERROR: lib/grq_sysadm.sh must be run as root (invoke via sudo)"
fi

if [[ "${1:-}" != "--password-file" || -z "${2:-}" ]]; then
  cat >&2 <<USAGE
Usage:
  sudo $0 --password-file PATH add  USERNAME FULLNAME HOME ADMIN_USER
  sudo $0 --password-file PATH reset USERNAME ADMIN_USER

The password file must be mode 0600. The helper feeds the password to
sysadminctl over a pty so it never appears on argv (issue #15).
USAGE
  exit 2
fi

PWFILE="$2"
shift 2

[[ -f "$PWFILE" ]] || die "ERROR: password file not found: $PWFILE"

# Reject anything that is not strictly 0600 — a permissive password file
# is a separate-but-related leak.
PERM=$(stat -f '%Lp' "$PWFILE" 2>/dev/null || stat -c '%a' "$PWFILE" 2>/dev/null || echo "")
case "$PERM" in
  600|0600) : ;;
  *) die "ERROR: password file $PWFILE must be mode 0600 (got $PERM)" ;;
esac

# Capture the password into a shell variable. The bash process's own
# memory is not exposed via /proc/<pid>/cmdline. `read -r` from the
# file rather than `cat $(...)` to avoid spawning extra processes that
# might in principle observe argv — although none of them would have
# the password on argv here, we keep the invocation chain tight.
PASSWORD=$(< "$PWFILE")
[[ -n "$PASSWORD" ]] || die "ERROR: password file $PWFILE is empty"

if ! command -v "$GRQ_SYSADM_EXPECT" >/dev/null 2>&1; then
  die "ERROR: '$GRQ_SYSADM_EXPECT' is required to set passwords without argv exposure (issue #15)"
fi

CMD="${1:-}"
shift || true

# run_sysadminctl_via_pty drives sysadminctl under expect, feeding the
# password whenever a "Password:" prompt appears. The actual sysadminctl
# invocation arguments are read from the GRQ_SYSADM_* env vars below
# rather than spliced into the heredoc, so a password full of awkward
# Tcl metacharacters is handled correctly.
run_sysadminctl_via_pty() {
  local mode="$1"  # 'add' or 'reset'
  GRQ_SYSADM_PW="$PASSWORD" \
  GRQ_SYSADM_MODE="$mode" \
  GRQ_SYSADM_BIN="$GRQ_SYSADM_BIN" \
  GRQ_SYSADM_TIMEOUT="$GRQ_SYSADM_TIMEOUT" \
  GRQ_SYSADM_USER="${GRQ_SYSADM_USER:-}" \
  GRQ_SYSADM_FULLNAME="${GRQ_SYSADM_FULLNAME:-}" \
  GRQ_SYSADM_HOME="${GRQ_SYSADM_HOME:-}" \
  GRQ_SYSADM_ADMIN="${GRQ_SYSADM_ADMIN:-}" \
  "$GRQ_SYSADM_EXPECT" <<'EXP'
    set timeout $env(GRQ_SYSADM_TIMEOUT)
    log_user 0
    set pw $env(GRQ_SYSADM_PW)
    set bin $env(GRQ_SYSADM_BIN)
    set mode $env(GRQ_SYSADM_MODE)
    set user $env(GRQ_SYSADM_USER)
    set admin $env(GRQ_SYSADM_ADMIN)
    if {$mode eq "add"} {
      set fullname $env(GRQ_SYSADM_FULLNAME)
      set home $env(GRQ_SYSADM_HOME)
      spawn -noecho $bin -addUser $user -fullName $fullname -password - -home $home -adminUser $admin
    } else {
      spawn -noecho $bin -resetPasswordFor $user -newPassword - -adminUser $admin
    }
    expect {
      -nocase -re "password\[^\r\n]*:" {
        send -- "$pw\r"
        exp_continue
      }
      timeout {
        send_user "ERROR: timed out waiting for sysadminctl prompt\n"
        exit 124
      }
      eof
    }
    catch wait result
    set status [lindex $result 3]
    exit $status
EXP
}

case "$CMD" in
  add)
    GRQ_SYSADM_USER="${1:-}"
    GRQ_SYSADM_FULLNAME="${2:-}"
    GRQ_SYSADM_HOME="${3:-}"
    GRQ_SYSADM_ADMIN="${4:-}"
    if [[ -z "$GRQ_SYSADM_USER" || -z "$GRQ_SYSADM_FULLNAME" \
          || -z "$GRQ_SYSADM_HOME" || -z "$GRQ_SYSADM_ADMIN" ]]; then
      die "ERROR: 'add' requires USERNAME FULLNAME HOME ADMIN_USER"
    fi
    run_sysadminctl_via_pty add
    ;;
  reset)
    GRQ_SYSADM_USER="${1:-}"
    GRQ_SYSADM_ADMIN="${2:-}"
    if [[ -z "$GRQ_SYSADM_USER" || -z "$GRQ_SYSADM_ADMIN" ]]; then
      die "ERROR: 'reset' requires USERNAME ADMIN_USER"
    fi
    run_sysadminctl_via_pty reset
    ;;
  *)
    die "ERROR: unknown subcommand: '${CMD}' (expected 'add' or 'reset')"
    ;;
esac
