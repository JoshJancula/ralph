---
name: bundle-vs-root
description: Never confuse repo-root runtime dirs with bundle/ install templates. Edits to bundle/ do not affect the active runtime config.
globs: ["**/*"]
alwaysApply: true
---

# Bundle vs repo-root runtime directories

This repo has two layers that look similar but serve different purposes:

| Layer | Path pattern | Purpose |
|-------|-------------|---------|
| **Repo-root runtime** | `.cursor/`, `.claude/`, `.codex/`, `.opencode/`, `.agents/` at repo root | Ralph's own dev workflow config — active right now |
| **Install templates** | `bundle/.cursor/`, `bundle/.claude/`, `bundle/.codex/`, `bundle/.opencode/`, `bundle/.agents/` | Defaults copied into downstream projects on `./install.sh` |

## Rules

- **Edit repo-root** `.<runtime>/` when working on Ralph's own development workflow (agents, hooks, rules, skills in use during development).
- **Edit `bundle/.<runtime>/`** only when the change should ship as a template for downstream projects.
- **Never assume** a change to `bundle/.cursor/rules/no-emoji.mdc` updates `.cursor/rules/no-emoji.mdc` — they are separate files.
- **`.ralph/` is a symlink** to `bundle/.ralph/`. Editing files under `bundle/.ralph/` is reflected at `.ralph/` immediately. This is the one intentional exception.
- When in doubt: check whether the task says "update the install template" vs "update the dev workflow." If it is not specified, default to repo-root.
- Rules, skills, agents, and the Antigravity registry are generated from `agents/` (root) and `bundle/.ralph/` (bundle) canonical dirs by `scripts/sync-runtime-assets.sh`.
