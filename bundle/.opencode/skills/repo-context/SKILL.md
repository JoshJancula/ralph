---
name: repo-context
description: Discover repository layout, stack, and how to build, test, and run. Use when planning cross-cutting work or when the user asks how to run commands. Customize the Layout/Stack/Commands sections for this project.
---

# Repo context

## How to orient in this repo

1. Read **README.md** at the repo root (and any linked docs).
2. If present, read **AGENTS.md** or **CONTRIBUTING.md** for project conventions.
3. Inspect **package.json**, **pyproject.toml**, **go.mod**, **Cargo.toml**, or similar for scripts and stack.
4. Map top-level directories before editing across boundaries.

## Customize this skill

Replace or extend the sections below with your project's specifics so agents do not guess wrong.

### Layout (edit me)

- Add your main directories (for example `apps/`, `packages/`, `src/`, `server/`, `client/`).

### Stack (edit me)

- Language/runtime versions (from version files, container images, or docs).
- Frameworks and major libraries.

### Commands (edit me)

| Task | Command |
|------|---------|
| Install | (add) |
| Dev | (add) |
| Test | (add) |
| Lint | (add) |

### Conventions

- Match existing patterns in each area of the codebase.
- Do not add dependencies without explicit instruction.
- Plan-driven Ralph work: unchecked items in the active plan file are the source of truth for what to do next.

## When to use

- Before refactors that span multiple top-level areas.
- When the user asks how to run, test, or build.
- When artifact paths should use Ralph placeholders like `artifacts/{{ARTIFACT_NS}}/...`
