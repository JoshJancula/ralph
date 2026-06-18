# Ralph Antigravity agent metadata

This directory holds Ralph's **prebuilt agent metadata** for Antigravity (`agy`) CLI-driven runs. It is consumed by Ralph tooling (`run-plan.sh --agent`, orchestration, MCP catalogs, output artifact checks, and model resolution).

Antigravity's native team/persona registry is the peer file `.agents/agents.md`. Keep that file aligned with the profiles here, but do not treat `.agents/agents/<agent-id>/` as the native Antigravity agent registry.

The `config.json` schema is identical to the other runtimes. See [bundle/.claude/agents/README.md](../../.claude/agents/README.md) for the full field-by-field schema and validation rules. This file documents only the Antigravity-specific behavior.

## Dual files

Each Ralph prebuilt agent keeps a `config.json` and a peer `<agent-id>.md` with YAML frontmatter. Ralph reads both to build the prompt context it passes to `agy --print`.

Antigravity reads native workspace customizations from `.agents/`, including `.agents/agents.md`, `.agents/rules/`, `.agents/skills/`, and `.agents/workflows/`. Keep `name`, `description`, `rules`, and `skills` in sync between this Ralph metadata and `.agents/agents.md` so native Antigravity sessions and Ralph-driven runs describe the same personas.

## Model contract

Antigravity model ids are **never normalized**. The exact display string from `agy models` is passed through unchanged:

```
agy --model "<exact model string from agy models>" ...
```

Set `ANTIGRAVITY_PLAN_MODEL` to that exact string for non-interactive runs, or leave `model` empty to pick from `agy models` interactively. There is no saved-model store for Antigravity.

## Invocation and caching

Ralph drives `agy` in headless print mode:

- Prompt: `agy --print "<prompt>"` (agy emits no JSON stream).
- Auto-approve: `agy --dangerously-skip-permissions` (default; disable with `ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=0`).
- Wait budget: `agy --print-timeout` is widened to Ralph's per-invocation timeout.

`agy` mints its own conversation id and cannot be told to reuse a preset one. After each TODO, Ralph reads the id agy recorded in `${RALPH_GEMINI_HOME:-~/.gemini}/antigravity-cli/cache/last_conversations.json` and resumes the next TODO with `agy --conversation <id>`. Reusing one conversation across TODOs keeps agy's session-tied prompt cache warm.
