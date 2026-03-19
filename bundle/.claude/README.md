# Claude Code integration

`settings.json` stores the project-level Claude Code settings for this workspace. Define the environment variables, hooks, and any other workspace-wide knobs there, and enable agent teams by setting `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` to `true` in that file.

If you want to run Ralph MCP inside Claude Code, copy `bundle/.claude/mcp.example.json` to the project root as `.mcp.json`. Update the placeholder paths so `RALPH_MCP_WORKSPACE` and `PATH` point to this repository, then run `claude mcp list` to confirm the server is available from Claude Code.

For more MCP background, including the Ralph-specific workflow, see `docs/MCP.md`.
