---
name: agent-dual-file-sync
description: Every agent is defined by two files that must stay in sync. Editing one without the other causes orchestrator/session drift.
globs: ["**/.cursor/agents/**", "**/.claude/agents/**", "**/.codex/agents/**", "**/.opencode/agents/**", "**/bundle/*/agents/**"]
alwaysApply: false
---

# Agent dual-file sync

Each Ralph agent is described by a canonical markdown file with frontmatter plus generated runtime files. The canonical file must be updated first and then `scripts/sync-runtime-assets.sh` should be run to refresh the generated outputs:

| File | Read by | Fields that matter |
|------|---------|-------------------|
| `agents/agents/<agent-id>.md` or `bundle/.ralph/agents/<agent-id>.md` | `scripts/sync-runtime-assets.sh` | YAML frontmatter (`description`, `models`, `rules`, `skills`, `output_artifacts`) + instruction body |
| `<runtime>/agents/<agent-id>/config.json` | Orchestrator, `agent-config-tool.sh` | Generated runtime metadata derived from the canonical frontmatter |
| `<runtime>/agents/<agent-id>/<agent-id>.md` or `.toml` | Cursor / Claude / Codex / OpenCode / Antigravity native session | Generated native session file derived from the canonical frontmatter + instruction body |

## Rules

- Edit the canonical frontmatter only; do not hand-edit generated `config.json`, runtime `.md`, `.toml`, or `.agents/agents.md` files.
- Never leave the canonical frontmatter pointing to a rule or skill path that no longer exists.
- Agent names must be **lowercase + hyphens only** (e.g. `code-review`, not `code_review`, not `codeReview`).
- To scaffold a new agent for all runtimes at once: `bash .ralph/new-agent.sh`
- `output_artifacts` in the canonical frontmatter are context hints; orchestration stage `artifacts` / `outputArtifacts` override them at runtime.
- `allowed_tools` remains Claude headless only; leave unset for other runtimes.

## Artifact path placeholders

Use these tokens in `output_artifacts[].path` — never hardcode run-specific values:

| Token | Source | Example |
|-------|--------|---------|
| `{{ARTIFACT_NS}}` | Orchestration JSON or plan basename | `my-feature` |
| `{{PLAN_KEY}}` | Plan namespace (falls back to ARTIFACT_NS) | `my-feature-01` |
| `{{STAGE_ID}}` | Sanitized stage `id` from orchestration JSON | `cr1` |
