# Agent configuration schema

This directory holds **prebuilt agent** definitions for Claude CLI-driven runs. The canonical generic agent source is the flat markdown file `bundle/.ralph/agents/<agent-id>.md`; `scripts/sync-runtime-assets.sh` generates this directory's `config.json` and runtime-native `.md` files from that frontmatter.

The same schema applies under `.cursor/agents/` for Cursor runs so tooling can validate and apply configuration consistently.

## Dual-purpose agents

Every agent in this directory serves two runtimes. The generated `config.json` files are used by Ralph tooling (`.ralph/run-plan.sh` with **`--plan`**, `orchestrator.sh`, MCP) while Claude Code native sessions consume the generated peer `.md` files with YAML frontmatter. The six built-in agents (`research`, `architect`, `implementation`, `code-review`, `qa`, `security`) share both representations, but the canonical source of truth is the flat frontmatter markdown under `bundle/.ralph/agents/`.

| Purpose | `config.json` | `<agent-id>.md` frontmatter |
|---------|---------------|-----------------------------|
| Identifier | `name` field | `name` field (must match directory) |
| Role summary | `description` | `description` |
| Model selection | `model` | `model` |
| Constraints | `rules` | frontmatter `rules` array |
| Skill references | `skills` | frontmatter `skills` array |
| Allowed tooling | `allowed_tools` (Claude headless) | `tools` |
| Artifacts | `output_artifacts` (optional) | body instructions referencing `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/...` |

When touching any of the shared values above, update the canonical markdown frontmatter and then rerun `scripts/sync-runtime-assets.sh` so Ralph and Claude Code stay aligned.

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

### Optional fields

| Field | Type | Purpose |
|-------|------|---------|
| `output_artifacts` | array | Context hint: declared deliverables this agent is expected to produce. For structured pipeline plans, artifact contracts live in the plan's `produces`/`requires` fields instead. For legacy `.orch.json` orchestration, artifact and handoff metadata is declared in the `.orch.json` stage `outputArtifacts` array (not here). When present, validated as an array of path entries. |
| `allowed_tools` | string or array of strings | **Claude headless only.** Comma-separated tool names (same as `claude -p --allowedTools`), or a JSON array of names. Passed when `CLAUDE_PLAN_ALLOWED_TOOLS` is **unset**. Include **Write** if the agent creates new artifact files. Cursor/Codex runners ignore this key. Requires **python3** in PATH when the key is present (validation). |
| `mcp_proxy_policy` | string | Optional default MCP proxy policy name for proxy-enabled runs. The orchestrator may override this per stage with `mcpProxyPolicy` in `.orch.json`. |

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

- **Required:** yes (key must be present).
- **Type:** string.
- **Rules:**
  - May be an empty string for Ralph prebuilt Claude/Codex agents (no bundled default). When empty, `run-plan` resolves the model from saved models (`ralph models add`), env vars, or an interactive prompt.
  - When non-empty: no line breaks or control characters.
  - User-authored agents may set an explicit model id; orchestration stage `model` overrides agent config for that stage.
  - Ralph no longer ships or validates against bundled default model lists for Claude/Codex.

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

- **Required:** no (optional).
- **Type:** array (when present).
- **Purpose:** Context hint for the agent. The structured pipeline runner verifies artifacts from
  the plan's `produces`/`requires` fields. The legacy orchestrator reads `outputArtifacts` from
  the `.orch.json` stage definitions. This field is not the source of truth for either path; it
  is injected into the agent's context block so the agent knows what it is expected to produce.
- **Rules (when present):**
  - Each entry must be either:
    - a non-empty string (file path or glob relative to repo root), or
    - an object with at least `path` (string) and optionally `required` (boolean, default true), `kind` (string), `to` (string), and `description` (string).
  - Path templates may include `{{ARTIFACT_NS}}` and `{{PLAN_KEY}}`.
    - `{{ARTIFACT_NS}}` resolves from `RALPH_ARTIFACT_NS` (or plan key fallback).
    - `{{PLAN_KEY}}` resolves from `RALPH_PLAN_KEY`.
  - **`kind`** (optional): Classifies artifact type. Allowed values:
    - `handoff`: Indicates artifact contains tasks/instructions to hand off to another stage (requires `to` field).
    - `design`: Design or architecture artifact.
    - `review`: Review findings or analysis.
    - `research`: Research or exploration output.
    - `notes`: General notes or summary.
  - **`to`** (conditionally required when `kind: handoff`): Target stage ID. Used only by the legacy
    `.orch.json` orchestrator; structured pipeline plans use plan `produces`/`requires` instead.

### `mcp_proxy_policy`

- **Required:** no.
- **Type:** string.
- **Rules:**
  - When present, must be a non-empty string naming a proxy policy defined in the active policy document.
  - Used only when Ralph mode is `ralph` or `hybrid` and no stage-level `mcpProxyPolicy` has already been supplied.
  - Policy caps apply to Ralph MCP tool results and MCP `resources/read`, not to runtime-native tools (`Read`, `Bash`, `Grep`, and so on). See `docs/TOOLING.md` for policy field naming (`camelCase` schema fields; `toolResultByteCaps` keys are exact MCP tool identifiers such as `ralph_proxy_read` or `resources/read`).
  - Policy precedence and Ralph mode defaults: see `docs/TOOLING.md` (default `no`; use `--ralph-mode` or `RALPH_MODE` on plan runs).

## Example (minimal valid config)

```json
{
  "name": "research",
  "model": "example-model-id",
  "description": "Gathers context and writes research notes.",
  "rules": [".claude/rules/no-emoji.md"],
  "skills": []
}
```

## Example with optional `output_artifacts` context hint

```json
{
  "name": "research",
  "model": "example-model-id",
  "description": "Gathers context and writes research notes.",
  "rules": [".claude/rules/no-emoji.md"],
  "skills": [],
  "output_artifacts": [
    { "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md", "required": true }
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
  "allowed_tools": "Bash,Read,Edit,Write,Grep,Glob"
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
| Empty `description` | Fail |
| Missing `model` key | Fail |
| Empty `model` string | Allowed (Claude/Codex prebuilt agents; runtime resolves via saved models or env) |
| `rules` not array or empty strings inside | Fail |
| `skills` not array or non-string elements | Fail |
| `output_artifacts` present but not array or invalid entries | Fail |

Runners should validate `config.json` before starting an agent session and log which file failed and why.
