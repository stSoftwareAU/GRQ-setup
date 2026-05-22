#!/bin/bash
# lib/pinned_versions.sh
#
# Pinned commit SHAs and SHA-256 hashes for every external installer this
# repository pulls in at provisioning time. See issue #16.
#
# Each hash is a deliberate, human-reviewed trust decision. To refresh:
#
#   1. Read the upstream change (diff the new installer against the prior
#      pinned version). Confirm the changes are benign.
#   2. Compute the new SHA-256:
#         curl -fsSL <URL> | shasum -a 256        # macOS
#         curl -fsSL <URL> | sha256sum            # Linux
#   3. Bump the variable below in the same PR as the audit summary.
#
# Never bump these hashes automatically. Treat any mismatch detected by the
# verifier as a fail-closed event: investigate before re-running.
#
# This file is intended to be sourced, not executed. shellcheck-disable for
# SC2034 below: every variable is consumed by setup scripts that source us.
# shellcheck disable=SC2034

# --- Homebrew installer ------------------------------------------------------
# Pinned to a specific commit on Homebrew/install. The previous version of
# MacOS/setup.sh fetched HEAD, which made the install vulnerable to any
# transient compromise of the Homebrew/install repository.
HOMEBREW_INSTALL_SHA="5753984d1eb214c40e86489416be2d38972f836a"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_SHA}/install.sh"
HOMEBREW_INSTALL_SHA256="f3e91784ffeda32bc397de7acc1154724cc47522a459c9ac656cca176eeba457"

# --- rustup installer --------------------------------------------------------
# The canonical https://sh.rustup.rs/ endpoint redirects to
# https://static.rust-lang.org/rustup/rustup-init.sh. There is no
# per-version commit SHA in the URL, so we pin by SHA-256 of the script
# itself. Bump deliberately when rustup ships a new installer.
RUSTUP_INSTALL_URL="https://sh.rustup.rs"
RUSTUP_INSTALL_SHA256="6c30b75a75b28a96fd913a037c8581b580080b6ee9b8169a3c0feb1af7fe8caf"

# --- Deno installer ----------------------------------------------------------
# https://deno.land/install.sh is a small bootstrapper. Pin by SHA-256 of the
# script and refresh deliberately when Deno publishes a new installer.
DENO_INSTALL_URL="https://deno.land/install.sh"
DENO_INSTALL_SHA256="83f19ea13f6d7884f4dc0e2f92e7e08e7589204138d9b6edfcd53c3f07b3273b"
