<!-- GENERATED from bundle/.codex/skills/repo-context/SKILL.md by scripts/sync-plugin-assets.sh - edit the canonical file -->
---
name: repo-context
description: Discover repository layout, stack, and how to build, test, and run. Use when planning cross-cutting work or when the user asks how to run commands. Customize the Layout/Stack/Commands sections for this project.
---

# Repo context

## How to orient in this repo

1. Reuse repo context you already gathered in this run; do not restart orientation on every TODO.
2. If the user request or plan already names exact files or commands, read those first.
3. Read **README.md** and **AGENTS.md** or **CONTRIBUTING.md** only when they are needed to answer missing build/test/run or repo-convention questions.
4. Inspect **package.json**, **pyproject.toml**, **go.mod**, **Cargo.toml**, or similar only when the task depends on stack or script details not already known.
5. Map top-level directories before editing across boundaries, not for single-file or verification-only follow-ups.

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
- Skip broad repo re-orientation for verification-only todos or follow-up todos that already provide the exact command or file set.
