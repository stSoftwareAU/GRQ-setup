## Summary

Added the Dependency Review GitHub Actions workflow at `.github/workflows/dependency-review.yml`. The workflow uses `actions/dependency-review-action@v4` on every pull request to flag dependency changes that introduce known vulnerabilities, improving the repository's security posture. Closes #8.

## Evidence

This is a CI configuration change with no UI or runtime behaviour. Validation performed:

- Parsed the new YAML with `python3 -c "import yaml; yaml.safe_load(...)"` — file is syntactically valid.
- Workflow uses the template recommended by GitHub's Dependency Review documentation and matches the body of issue #8 verbatim.

```mermaid
flowchart LR
    A[Pull Request opened] --> B[Dependency Review job]
    B --> C[actions/checkout@v4]
    C --> D[actions/dependency-review-action@v4]
    D -->|vulnerable deps| E[PR check fails]
    D -->|clean| F[PR check passes]
```

## Test Plan

- [x] YAML parses cleanly (`python3 -c "import yaml; yaml.safe_load(open('.github/workflows/dependency-review.yml'))"`).
- [ ] After merge, open a test PR and confirm the `Dependency Review` check appears and runs on `ubuntu-latest`.
