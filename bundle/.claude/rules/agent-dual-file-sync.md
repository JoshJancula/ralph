---
name: agent-dual-file-sync
description: Ralph supports single-file canonical agents (Ralph-native) and dual-file with per-runtime artifacts (bundled-default).
globs: ["**/.cursor/agents/**", "**/.claude/agents/**", "**/.codex/agents/**", "**/.opencode/agents/**", "**/bundle/*/agents/**"]
alwaysApply: false
---

# Agent dual-file sync

Ralph supports two agent definition paths: **single-file canonical .md** (Ralph-native) and **dual-file canonical .md + generated per-runtime artifacts** (bundled-default). The single-file path is the default for new Ralph-native agents. The dual-file path is preserved for distributed agent bundles.

## Single-file canonical path (Ralph-native)

When working in Ralph's own `.ralph/agents/` or projects with .ralph-workspace-scoped overrides, write only the canonical markdown file with YAML frontmatter. The agent source resolver normalizes it at runtime without requiring `scripts/sync-runtime-assets.sh`:

| File | Read by | Fields that matter |
|------|---------|-------------------|
| `.ralph/agents/<agent-id>.md` or `.ralph-workspace/agents/<agent-id>.md` | `ralph_agent_resolve_source` + adapters | YAML frontmatter (`description`, `models`, `rules`, `skills`, `output_artifacts`) + instruction body |

Use `ralph agent new <id>` (default `--ralph`) to scaffold this path:

```bash
ralph agent new my-agent              # Creates .ralph/agents/my-agent.md only
ralph agent new my-agent --ralph      # Same (explicit flag)
ralph agent list                       # Shows all sources with shadowing
ralph agent show my-agent              # Prints resolved normalized profile
```

## Dual-file bundled-default path (with --all)

When distributing agents across all runtimes as an installable bundle, use `ralph agent new <id> --all` to generate the full per-runtime artifact set and synchronize with `scripts/sync-runtime-assets.sh`:

| File | Read by | Fields that matter |
|------|---------|-------------------|
| `agents/agents/<agent-id>.md` or `bundle/.ralph/agents/<agent-id>.md` | `scripts/sync-runtime-assets.sh` | YAML frontmatter (`description`, `models`, `rules`, `skills`, `output_artifacts`) + instruction body |
| `<runtime>/agents/<agent-id>/config.json` | Orchestrator, `agent-config-tool.sh` | Generated runtime metadata derived from the canonical frontmatter |
| `<runtime>/agents/<agent-id>/<agent-id>.md` or `.toml` | Cursor / Claude / Codex / OpenCode / Antigravity native session | Generated native session file derived from the canonical frontmatter + instruction body |

## Rules

- **Single-file path:** Edit only `.ralph/agents/<agent-id>.md` (or `.ralph-workspace/agents/` for overrides). Do not run sync; the resolver adapts at runtime.
- **Dual-file path:** Edit the canonical frontmatter in `agents/agents/<agent-id>.md` or `bundle/.ralph/agents/<agent-id>.md`, then run `scripts/sync-runtime-assets.sh` to refresh generated outputs.
- Do not hand-edit generated `config.json`, runtime `.md`, `.toml`, or `.agents/agents.md` files in either path.
- Never leave the canonical frontmatter pointing to a rule or skill path that no longer exists.
- Agent names must be **lowercase + hyphens only** (e.g. `code-review`, not `code_review`, not `codeReview`).
- `output_artifacts` in the canonical frontmatter are context hints; orchestration stage `artifacts` / `outputArtifacts` override them at runtime.
- `allowed_tools` remains Claude headless only; leave unset for other runtimes.

## Artifact path placeholders

Use these tokens in `output_artifacts[].path` — never hardcode run-specific values:

| Token | Source | Example |
|-------|--------|---------|
| `{{ARTIFACT_NS}}` | Orchestration JSON or plan basename | `my-feature` |
| `{{PLAN_KEY}}` | Plan namespace (falls back to ARTIFACT_NS) | `my-feature-01` |
| `{{STAGE_ID}}` | Sanitized stage `id` from orchestration JSON | `cr1` |
