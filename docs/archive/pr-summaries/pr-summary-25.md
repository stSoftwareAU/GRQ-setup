# Add ShellCheck Lint workflow

## Summary

Adds the ShellCheck Lint GitHub Actions workflow requested in issue #25.
The workflow runs on every pull request, scans the repository root at
warning severity, and pins both third-party actions (`actions/checkout`
and `ludeeus/action-shellcheck`) to 40-character commit SHAs per the
project supply-chain policy (Issue #1613). Two existing shellcheck
warnings were fixed so the new workflow passes cleanly:

- `quality.sh` — added `|| exit 1` to the `cd "${BASE_DIR}"` call
  (SC2164).
- `Ubuntu/setup.sh` — annotated the retained-for-compatibility
  `CURRENT_USER` assignment with `# shellcheck disable=SC2034`.

Closes #25.

## Evidence

This is a CI/workflow change with no UI surface to screenshot. Verified
by running the new test suite plus the full quality gate locally:

```text
[quality] tests/shellcheck_workflow_test.sh
  ok   - shellcheck.yml workflow file exists
  ok   - workflow name declared
  ok   - triggered on pull_request
  ok   - permissions contents: read
  ok   - runs on ubuntu-latest
  ok   - uses ludeeus/action-shellcheck
  ok   - warning severity configured
  ok   - scandir set to repository root
  ok   - action-shellcheck pinned to 40-char commit SHA
  ok   - actions/checkout pinned to 40-char commit SHA
  ok   - shellcheck --severity=warning passes on repository shell scripts

shellcheck_workflow_test.sh: 11 passed, 0 failed
[quality] all quality checks passed
```

```mermaid
flowchart LR
    PR[Pull Request] --> CO[actions/checkout@SHA]
    CO --> SC[ludeeus/action-shellcheck@SHA<br/>scandir=.<br/>severity=warning]
    SC -->|warnings| Fail[CI fails]
    SC -->|clean| Pass[CI passes]
```

## Test Plan

- Added `tests/shellcheck_workflow_test.sh` — asserts the workflow file
  exists, declares the correct trigger/permissions/runner, pins both
  third-party actions to 40-char SHAs, and runs `shellcheck
  --severity=warning` locally over every `.sh`/`.bash` file in the repo
  to confirm CI will pass.
- Wired the new test into `quality.sh` so it runs as part of the
  standard quality gate.
- Confirmed the full quality gate (`./quality.sh < /dev/null`) exits
  with rc=0.
