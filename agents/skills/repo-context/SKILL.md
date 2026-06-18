---
name: repo-context
description: Discover repository layout, stack, and how to build, test, and run. Use when planning cross-cutting work or when the user asks how to run commands. Customize the Layout/Stack/Commands sections for this project.
---

# Repo context

## How to orient in this repo

1. Reuse repo context you already gathered in this run; do not restart orientation on every TODO.
2. If the user request or plan already names exact files or commands, read those first.
3. Read **README.md** and from docs/ directory only when they are needed to answer missing build/test/run or repo-convention questions.
4. Inspect **package.json**, **pyproject.toml**, **go.mod**, **Cargo.toml**, or similar only when the task depends on stack or script details not already known.
5. Map top-level directories before editing across boundaries, not for single-file or verification-only follow-ups.

## Layout

- `bundle/` — install source with `bundle/.ralph/` canonical scripts and the root `.ralph` symlink
- Two layers of runtime dirs: root `.cursor/`, `.claude/`, `.codex/`, `.opencode/` and `bundle/.cursor/`, `bundle/.claude/`, `bundle/.codex/`, `bundle/.opencode/`
- `tests/bats/` — Bats test suites; `tests/python/` — stdlib unit tests
- `scripts/` — build, test, and helper scripts
- `docs/` — project documentation for humans
- `ralph-dashboard/` — separate dashboard Node application

## Stack

- Core is **bash** plus **python3** stdlib
- No `npm install` for core framework
- Dashboard (`ralph-dashboard/`) is a separate Node app

## Commands

| Task | Command |
|------|---------|
| Fixtures | `bash scripts/setup-test-fixtures.sh` |
| Default bats suite | `bash scripts/run-bats.sh` |
| Bats suite | `bash scripts/run-bats.sh` |
| Python unit tests | `bash scripts/run-python-unit-tests.sh` |
| Single bats file | `bats tests/bats/<file>.bats` (use `--filter "pattern"` for a subset) |
| Validate orchestration schema | `bash scripts/validate-orchestration-schema.sh` |

## Conventions

- Match existing patterns in each area of the codebase.
- Do not add dependencies without explicit instruction.
- Plan-driven Ralph work: unchecked items in the active plan file are the source of truth for what to do next.
- Canonical rules live under `agents/rules/` and are the source of truth for repo conventions; runtime rule copies are generated from them.

## When to use

- Before refactors that span multiple top-level areas.
- When the user asks how to run, test, or build.
- When artifact paths should use Ralph placeholders like `artifacts/{{ARTIFACT_NS}}/...`
- Skip broad repo re-orientation for verification-only todos or follow-up todos that already provide the exact command or file set.
