---
name: testing-workflow
description: Ralph uses bats for shell integration and stdlib unit tests for Python. One Bats suite is the PR gate.
globs: ["tests/**", "scripts/**", "**/*.bats"]
alwaysApply: false
---

# Testing workflow

## Test suites

- **Bats suite** (`bash scripts/run-bats.sh`) is the CI and PR gate for shell behavior and integration paths.
- **Python unit tests** (`bash scripts/run-python-unit-tests.sh`) exercise Ralph-owned Python logic with the standard library only.
- **Fixtures** (`bash scripts/setup-test-fixtures.sh`) create the temporary workspace stubs that Bats tests expect.

## Running a single test file

Use `bash scripts/run-bats.sh tests/bats/<file>.bats` or `bin/bats -T <file>.bats` for fast local iteration.

## Selecting a tier

`bash scripts/run-bats.sh` runs the **fast** tier by default: everything except
the files listed as `slow` or `acceptance` in `tests/bats/tiers.json`. That is
the same set CI gates every push on.

- `--tier all` adds the slow and acceptance files.
- `--tier slow` / `--tier acceptance` run just those manifests. CI runs `slow`
  as its own job and `acceptance` nightly, so pull requests never pay for them.

Keep an expensive end-to-end file out of the default run by listing it in the
`slow` or `acceptance` manifest. An explicit test path still runs whatever you
name, regardless of tier.

## What needs a test

- **New shell behavior** (new script, new function, new flag) needs a Bats test under `tests/bats/`.
- **New Ralph-owned Python logic** needs a stdlib unit test under `tests/python/`.
- **Docs-only changes** do not need a new test, but must pass the existing suite.

See [test-design](test-design.md) for when a test is worth writing, which level
to write it at, and the speed rules (no blocking `sleep`, no long-running
end-to-end tests in the default tier).

## PR policy

Every pull request must pass Python unit tests and the Bats suite. Do not disable or skip existing tests to make a PR green.
