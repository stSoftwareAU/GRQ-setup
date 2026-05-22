## Summary

Hardens the SSH bootstrap from each newly provisioned automated user
(`rocket`, `sloth`, `elephant`) to the admin hosts `10.0.0.11` and
`10.0.0.89`. The previous flow used `ssh-copy-id -f` plus bare `ssh`
to a hard-coded IP with no pre-populated `known_hosts`, so the first
connection was accepted via TOFU — an attacker who ARP-spoofed those
addresses on the flat `10.0.0.0/24` LAN could intercept the bootstrap
and from then on MITM every `ssh`, `git clone`, and `git push` from
the worker. Closes #17.

The fix pre-distributes a verified host-key list in
`lib/admin_known_hosts`. Each parent provisioning script installs it
to `/etc/ssh/ssh_known_hosts` (root-owned, `0644`) before generating
the per-user `~/setup.sh`. The generated script invokes `ssh-copy-id`
and `ssh` with:

```text
-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts
```

The `-f` flag is dropped from `ssh-copy-id` so any future host-key
change is surfaced as an error instead of silently overwriting the pin.
README documents the out-of-band fingerprint verification workflow the
admin must follow before populating the template.

## Evidence

This is a backend/shell change with no UI. Verification is covered by
the new test `tests/ssh_tofu_test.sh`, which asserts:

- `lib/admin_known_hosts` ships with the repo and references both
  admin hosts (`10.0.0.11`, `10.0.0.89`) and the `ssh-keyscan` workflow.
- Every parent script installs `/etc/ssh/ssh_known_hosts` from the
  template.
- Every generated `~/setup.sh` body enforces
  `StrictHostKeyChecking=yes` and `UserKnownHostsFile=/etc/ssh/ssh_known_hosts`
  on the admin-host SSH calls.
- The forbidden `ssh-copy-id -f` flag is gone from all three parent
  scripts.
- README references both `lib/admin_known_hosts` and the word
  "fingerprint" so the verification workflow is discoverable.

`./quality.sh` passes cleanly: `bash -n`, `shellcheck --severity=error`,
`markdownlint-cli2`, plus all four test suites (51 assertions in total,
21 from the new TOFU test).

```mermaid
flowchart LR
    A[Admin operator] -->|verify out-of-band| B[Populate<br/>lib/admin_known_hosts]
    B --> C[MacOS/Ubuntu setup.sh<br/>install -m 0644 -o root]
    C --> D[/etc/ssh/ssh_known_hosts]
    E[Generated ~/setup.sh] -->|ssh -o StrictHostKeyChecking=yes<br/>-o UserKnownHostsFile=/etc/ssh/ssh_known_hosts| D
    D -->|key matches pin| F[nigel@10.0.0.11 / 10.0.0.89]
    D -->|key mismatch| G[fail-closed: no TOFU window]
```

## Test Plan

- New: `tests/ssh_tofu_test.sh` — 21 assertions covering the new
  invariants listed in Evidence above.
- Existing: `tests/verify_installer_test.sh`,
  `tests/generated_user_setup_test.sh`,
  `tests/heredoc_render_test.sh` continue to pass — the supply-chain
  hardening from issue #16 is untouched.
- Manual: re-rendered the macOS heredoc body and confirmed the produced
  bash is syntactically valid (`bash -n`) and the array expansion
  `"${SSH_STRICT_OPTS[@]}"` resolves correctly.
