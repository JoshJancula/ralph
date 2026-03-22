# Claude Code integration

`settings.json` stores the project-level Claude Code settings for this workspace. Define the environment variables, hooks, and any other workspace-wide knobs there, and enable agent teams by setting `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` to `true` in that file.

If you want to run Ralph MCP inside Claude Code, copy `bundle/.claude/mcp.example.json` to the project root as `.mcp.json`. Update the placeholder paths so `RALPH_MCP_WORKSPACE` and `PATH` point to this repository, then run `claude mcp list` to confirm the server is available from Claude Code.

For more MCP background, including the Ralph-specific workflow, see `docs/MCP.md`.

## CLI session resume

When a plan runs for Claude Code you can opt in to CLI session resume so the next invocation picks up the stored assistant conversation. Enable it by setting `RALPH_PLAN_CLI_RESUME=1`, passing `--cli-resume`, or answering **yes** when the interactive prompt runs in a TTY. The runner records the active session ID at `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt` and the JSON demux helper (`.ralph/bash-lib/run-plan-cli-json-demux.py`) uses Python 3 to parse the `stream-json` output and update that file; without Python 3, the plan shrugs it off and continues without resume.

If you need bare resume without an existing session file (for isolated CI or trusted operators), set `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` or pass `--allow-unsafe-resume`. This tells the runtime to invoke `--resume` without relying on the stored session ID. Avoid doing this on shared workstations because it can attach to another user's session.
