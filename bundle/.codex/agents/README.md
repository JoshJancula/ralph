# Codex Ralph prebuilt agents

Mirrors `.cursor/agents/<name>/config.json` for orchestrator stages with `runtime: codex`.
Rules and skills use repo-relative paths (same files as Cursor agents where possible).

## Official Codex subagents (native)

So that Codex can spawn these agents as custom subagents, each agent is also defined in **official Codex custom agent format**: a standalone TOML file in this directory (e.g. `research.toml`, `architect.toml`). See [Codex Subagents](https://developers.openai.com/codex/subagents).

- **File:** `.codex/agents/<name>.toml` (e.g. `.codex/agents/code-review.toml`)
- **Required:** `name`, `description`, `developer_instructions`
- **Optional:** `model`, `model_reasoning_effort`, `sandbox_mode`, `nickname_candidates`, `mcp_servers`, `skills.config`

Ralph orchestration continues to use `<name>/config.json`. The `.toml` files are for Codex's native custom agent discovery and spawning (e.g. "Have research explore the codebase and reviewer check risks").
