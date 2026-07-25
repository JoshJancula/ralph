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

## What needs a test

- **New shell behavior** (new script, new function, new flag) needs a Bats test under `tests/bats/`.
- **New Ralph-owned Python logic** needs a stdlib unit test under `tests/python/`.
- **Docs-only changes** do not need a new test, but must pass the existing suite.

## PR policy

Every pull request must pass Python unit tests and the Bats suite. Do not disable or skip existing tests to make a PR green.
