#!/bin/bash
# Local quality gate: bash syntax check, optional shellcheck, markdownlint, and tests.
# Stdin is redirected from /dev/null at every step so the gate cannot hang on
# an unattended worker.

set -uo pipefail

BASE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${BASE_DIR}"

RC=0
note()  { printf '[quality] %s\n' "$1"; }
fail()  { printf '[quality] FAIL: %s\n' "$1" >&2; RC=1; }

# --- 1. bash -n syntax check -------------------------------------------------
note "bash -n on shell sources"
for f in \
    MacOS/setup.sh MacOS/add-user.sh \
    Ubuntu/setup.sh \
    lib/verify_installer.sh lib/pinned_versions.sh lib/per_user_password.sh lib/grq_sysadm.sh lib/input_validation.sh \
    tests/verify_installer_test.sh tests/generated_user_setup_test.sh tests/heredoc_render_test.sh tests/ssh_tofu_test.sh tests/per_user_password_test.sh tests/sysadm_argv_test.sh tests/input_validation_test.sh \
    quality.sh; do
  if [[ -f "$f" ]]; then
    if ! bash -n "$f" < /dev/null; then
      fail "bash -n $f"
    fi
  fi
done

# --- 2. shellcheck (optional) ------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  note "shellcheck (errors only)"
  if ! shellcheck --severity=error -x \
        lib/verify_installer.sh lib/pinned_versions.sh lib/per_user_password.sh lib/grq_sysadm.sh lib/input_validation.sh \
        MacOS/setup.sh MacOS/add-user.sh Ubuntu/setup.sh < /dev/null; then
    fail "shellcheck reported errors"
  fi
else
  note "shellcheck not installed — skipping"
fi

# --- 3. markdownlint ---------------------------------------------------------
if command -v markdownlint-cli2 >/dev/null 2>&1; then
  note "markdownlint-cli2"
  if ! markdownlint-cli2 < /dev/null; then
    fail "markdownlint-cli2 reported issues"
  fi
else
  note "markdownlint-cli2 not installed — skipping"
fi

# --- 4. tests ----------------------------------------------------------------
note "tests/verify_installer_test.sh"
if ! bash tests/verify_installer_test.sh < /dev/null; then
  fail "verify_installer_test.sh"
fi

note "tests/generated_user_setup_test.sh"
if ! bash tests/generated_user_setup_test.sh < /dev/null; then
  fail "generated_user_setup_test.sh"
fi

note "tests/heredoc_render_test.sh"
if ! bash tests/heredoc_render_test.sh < /dev/null; then
  fail "heredoc_render_test.sh"
fi

note "tests/ssh_tofu_test.sh"
if ! bash tests/ssh_tofu_test.sh < /dev/null; then
  fail "ssh_tofu_test.sh"
fi

note "tests/per_user_password_test.sh"
if ! bash tests/per_user_password_test.sh < /dev/null; then
  fail "per_user_password_test.sh"
fi

note "tests/sysadm_argv_test.sh"
if ! bash tests/sysadm_argv_test.sh < /dev/null; then
  fail "sysadm_argv_test.sh"
fi

note "tests/input_validation_test.sh"
if ! bash tests/input_validation_test.sh < /dev/null; then
  fail "input_validation_test.sh"
fi

if (( RC == 0 )); then
  note "all quality checks passed"
else
  note "quality gate FAILED"
fi
exit $RC
