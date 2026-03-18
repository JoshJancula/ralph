# Agent configuration schema

This directory holds **prebuilt agent** definitions for Cursor-driven runs. Each agent lives in its own subdirectory (for example `research/`, `architect/`, `implementation/`) and is described by a `config.json` file that must conform to the schema below.

The same schema applies under `.claude/agents/` for Claude CLI runs so tooling can validate and apply configuration consistently.

## File location

- **Cursor:** `.cursor/agents/<agent-id>/config.json`
- **Claude:** `.claude/agents/<agent-id>/config.json`

`<agent-id>` should match the `name` field (see validation).

## Required fields

Every agent `config.json` **must** include all of the following keys. Missing keys or wrong types cause validation to fail.

| Field | Type | Purpose |
|-------|------|---------|
| `name` | string | Stable identifier for the agent (used in flags, discovery, and logs). |
| `model` | string | Model id passed to the runtime (Cursor or Claude) for this agent. |
| `description` | string | Short human-readable summary of role and boundaries. |
| `rules` | array | Paths (relative to repo root) or rule bundle ids that constrain this agent. |
| `skills` | array | Paths (relative to repo root) or skill ids available to this agent. |
| `output_artifacts` | array | Declared deliverables this agent is expected to produce (paths or patterns, namespace placeholders supported). |

### Optional fields

| Field | Type | Purpose |
|-------|------|---------|
| `allowed_tools` | string or array of strings | **Claude headless only** (same as `.claude/agents` README). Cursor/Codex ignore this key. |

## Field details and validation rules

### `name`

- **Required:** yes.
- **Type:** string.
- **Rules:**
  - Non-empty after trim.
  - Match `^[a-z0-9][a-z0-9-]*[a-z0-9]$` or single segment `^[a-z0-9]+$` (lowercase, digits, hyphens; no spaces).
  - Must equal the parent directory name `<agent-id>` (so discovery and config stay aligned).
- **Invalid examples:** empty string, `My Agent`, `agent_1` (underscores optional: disallow unless you extend the regex).

### `model`

- **Required:** yes.
- **Type:** string.
- **Rules:**
  - Non-empty after trim.
  - No line breaks or control characters.
  - Tooling may further restrict to an allowlist per runtime; schema validation only enforces presence and basic string hygiene.

### `description`

- **Required:** yes.
- **Type:** string.
- **Rules:**
  - Non-empty after trim.
  - Recommended max length 2000 characters (warn over limit; hard fail optional).

### `rules`

- **Required:** yes.
- **Type:** array.
- **Rules:**
  - Every element must be a non-empty string.
  - Paths, if relative, should resolve under `.cursor/rules/`, `.claude/rules/`, or documented global rule roots; unknown paths may warn but optional fail is implementation-defined.

### `skills`

- **Required:** yes.
- **Type:** array of strings (empty array allowed).
- **Rules:**
  - Each element must be a non-empty string.
  - Same path resolution notes as `rules`.

### `output_artifacts`

- **Required:** yes.
- **Type:** array.
- **Rules:**
  - Each entry must be either:
    - a non-empty string (file path or glob relative to repo root), or
    - an object with at least `path` (string) and optionally `required` (boolean, default true).
  - Path templates may include `{{ARTIFACT_NS}}` and `{{PLAN_KEY}}`.
    - `{{ARTIFACT_NS}}` resolves from `RALPH_ARTIFACT_NS` (or plan key fallback).
    - `{{PLAN_KEY}}` resolves from `RALPH_PLAN_KEY`.
  - At least one artifact should be listed for agents that produce handoff files; orchestrators may require `required: true` entries to exist and be non-empty after a run.

## Example (minimal valid config)

```json
{
  "name": "research",
  "model": "example-model-id",
  "description": "Gathers context and writes research notes.",
  "rules": [".cursor/rules/no-emoji.mdc"],
  "skills": [],
  "output_artifacts": [
    { "path": "artifacts/{{ARTIFACT_NS}}/research.md", "required": true }
  ]
}
```

## Validation summary

| Check | Action on failure |
|-------|-------------------|
| Missing required key | Fail |
| Wrong JSON type for a field | Fail |
| `name` / directory mismatch | Fail |
| `name` pattern invalid | Fail |
| Empty `model`, `description` | Fail |
| `rules` not array or empty strings inside | Fail |
| `skills` not array or non-string elements | Fail |
| `output_artifacts` not array or invalid entries | Fail |

Runners should validate `config.json` before starting an agent session and log which file failed and why.
