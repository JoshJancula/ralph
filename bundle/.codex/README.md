# Codex integration

This directory holds Codex-specific Ralph assets: agents, rules, skills, and the plan runner. Prebuilt agents under `agents/` are used by the orchestrator when a stage has `runtime: codex`.

The canonical source for those agents is `bundle/.ralph/agents/<id>.md`; `scripts/sync-runtime-assets.sh` generates the runtime `config.json` and `.toml` files from that frontmatter.

To run Ralph MCP inside Codex, add the Ralph MCP server to your Codex config. Copy the `[mcp_servers.ralph]` block from `mcp.example.toml` into `~/.codex/config.toml` or into `.codex/config.toml` at your project root. Set `args` to the path of `.ralph/mcp-server.sh` in your workspace and set `RALPH_MCP_WORKSPACE` and `PATH` in the `env` table. Then run `codex mcp --help` or use `/mcp` in the Codex TUI to confirm the server is available.

For more MCP background, including the Ralph-specific workflow, see `docs/MCP.md`. For Ralph mode on plan runs (`--ralph-mode`, `RALPH_MODE`), see `docs/TOOLING.md`.
