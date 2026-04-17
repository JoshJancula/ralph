# Agent configuration schema

This directory holds **prebuilt agent** definitions for Claude CLI-driven runs. Each agent lives in its own subdirectory (for example `research/`, `architect/`, `implementation/`) and is described by a `config.json` file that must conform to the schema below.

The same schema applies under `.cursor/agents/` for Cursor runs so tooling can validate and apply configuration consistently.

## Dual-purpose agents

Every agent in this directory currently serves two runtimes. The existing `config.json` files are used by Ralph tooling (`.ralph/run-plan.sh` with **`--plan`**, `orchestrator.sh`, MCP) while Claude Code native sessions consume the peer `.md` files with YAML frontmatter (e.g., `research.md`). The six agents (`research`, `architect`, `implementation`, `code-review`, `qa`, `security`) share both representations, so keep values in sync when you edit an agent’s name, description, model, rules, or skills.

| Purpose | `config.json` | `<agent-id>.md` frontmatter |
|---------|---------------|-----------------------------|
| Identifier | `name` field | `name` field (must match directory) |
| Role summary | `description` | `description` |
| Model selection | `model` | `model` |
| Constraints | `rules` | frontmatter `rules` array |
| Skill references | `skills` | frontmatter `skills` array |
| Allowed tooling | `allowed_tools` (Claude headless) | `tools` |
| Artifacts | `output_artifacts` | body instructions referencing `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/...` |

When touching any of the shared values above, update both the JSON and the Markdown files so Ralph and Claude Code stay aligned.

## File location

- **Claude:** `.claude/agents/<agent-id>/config.json`
- **Cursor:** `.cursor/agents/<agent-id>/config.json`

`<agent-id>` should match the `name` field (see validation).

## Required fields

Every agent `config.json` **must** include all of the following keys. Missing keys or wrong types cause validation to fail.

| Field | Type | Purpose |
|-------|------|---------|
| `name` | string | Stable identifier for the agent (used in flags, discovery, and logs). |
| `model` | string | Model id passed to the runtime (Claude or Cursor) for this agent. |
| `description` | string | Short human-readable summary of role and boundaries. |
| `rules` | array | Paths (relative to repo root) or rule bundle ids that constrain this agent. |
| `skills` | array | Paths (relative to repo root) or skill ids available to this agent. |
| `output_artifacts` | array | Declared deliverables this agent is expected to produce (paths or patterns, namespace placeholders supported). |

### Optional fields

| Field | Type | Purpose |
|-------|------|---------|
| `allowed_tools` | string or array of strings | **Claude headless only.** Comma-separated tool names (same as `claude -p --allowedTools`), or a JSON array of names. Passed when `CLAUDE_PLAN_ALLOWED_TOOLS` is **unset**. Include **Write** if the agent creates new artifact files. Cursor/Codex runners ignore this key. Requires **python3** in PATH when the key is present (validation). |

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
  - Paths, if relative, should resolve under `.claude/rules/`, `.cursor/rules/`, or documented global rule roots; unknown paths may warn but optional fail is implementation-defined.

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
    - an object with at least `path` (string) and optionally `required` (boolean, default true), `kind` (string), `to` (string), and `description` (string).
  - Path templates may include `{{ARTIFACT_NS}}` and `{{PLAN_KEY}}`.
    - `{{ARTIFACT_NS}}` resolves from `RALPH_ARTIFACT_NS` (or plan key fallback).
    - `{{PLAN_KEY}}` resolves from `RALPH_PLAN_KEY`.
  - **`kind`** (optional): Classifies artifact type for orchestration and handoff routing. Allowed values:
    - `handoff`: Indicates artifact contains tasks/instructions to hand off to another stage (requires `to` field).
    - `design`: Design or architecture artifact.
    - `review`: Review findings or analysis.
    - `research`: Research or exploration output.
    - `notes`: General notes or summary.
    - If omitted, artifact is treated as a standard deliverable without handoff semantics.
  - **`to`** (conditionally required): When `kind` is `handoff`, specifies the target stage ID that receives this handoff. Must match a declared stage id in the orchestration config. Orchestration will inject identified unchecked tasks from the handoff file into the target stage's plan.
  - At least one artifact should be listed for agents that produce handoff files; orchestrators may require `required: true` entries to exist and be non-empty after a run.

## Example (minimal valid config)

```json
{
  "name": "research",
  "model": "example-model-id",
  "description": "Gathers context and writes research notes.",
  "rules": [".claude/rules/no-emoji.md"],
  "skills": [],
  "output_artifacts": [
    { "path": "artifacts/{{ARTIFACT_NS}}/research.md", "required": true }
  ]
}
```

## Example with Claude `allowed_tools`

```json
{
  "name": "architect",
  "model": "claude-sonnet-4-6",
  "description": "Design and handoff only.",
  "rules": [".claude/rules/no-emoji.md"],
  "skills": [".claude/skills/repo-context/SKILL.md"],
  "allowed_tools": "Bash,Read,Edit,Write,Grep,Glob",
  "output_artifacts": [
    { "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/architecture.md", "required": true }
  ]
}
```

Array form (equivalent): `"allowed_tools": ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]`

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
