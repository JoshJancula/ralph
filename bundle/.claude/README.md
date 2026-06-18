# Claude Code integration

`settings.json` stores the project-level Claude Code settings for this workspace. Define the environment variables, hooks, and any other workspace-wide knobs there, and enable agent teams by setting `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` to `true` in that file.

If you want to run Ralph MCP inside Claude Code, copy `.claude/mcp.example.json` to your project root as `.mcp.json`. Update the placeholder paths so `RALPH_MCP_WORKSPACE` and `PATH` point to your project, then run `claude mcp list` to confirm the server is available from Claude Code.

For more MCP background, including the Ralph-specific workflow, see `docs/MCP.md`. For Ralph mode on plan runs (`--ralph-mode`, `RALPH_MODE`), see `docs/TOOLING.md`.

## Ralph mode

Plan runs default to **Ralph Mode: no** (no Ralph injection). Opt in with **`--ralph-mode hybrid`** (full Ralph MCP catalog plus native adapters), **`--ralph-mode ralph`** (Ralph MCP without native adapter overlays), or **`--ralph-mode native`** (native-primary runs with result-store tools).

In **`ralph`** or **`hybrid`** mode, `.ralph/run-plan.sh` builds a temporary Claude MCP config whose `mcpServers.ralph` entry is injected with `--strict-mcp-config --mcp-config <temp>`, publishes the unified `ralph_proxy_*` tools, and, after MCP preflight succeeds, strips native `Bash` from Claude's built-in schema so commands run through the bounded `mcp__ralph__ralph_proxy_shell`. Native `Read`/`Edit`/`Write` are **kept** so the agent can still modify files: Claude Code requires a native `Read` of a file before it will `Edit`/`Write` it, and a `ralph_proxy_read` does not satisfy that gate, so stripping `Read` would deadlock every edit. Proxy reads stay preferred for bounded large reads via prompt guidance. The strip is controlled by `RALPH_CLAUDE_RALPH_STRICT_PROXY` (it defaults to `1` in `ralph` and `hybrid` once preflight succeeds) and only runs after preflight has validated the proxy; set it to `0` if you temporarily need native `Bash`. For read-only/analysis plans that never modify existing files you can additionally set `RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ=1` to also strip native `Read` (this disables native `Edit`/`Write` on existing files). The temp config never touches the committed `.mcp.json`; it only exists while the runtime is busy and is discarded afterward with no persistent change.

When balancing safety and convenience, recall that the proxy's promise is output bounding—not a sandbox. The built-in default policy is permissive: `proxyOwnedTools.allowAllCommands` and `proxyOwnedTools.allowShellOperators` are `true` with a generous shell timeout, so `ralph_proxy_shell` runs arbitrary commands, operators, and builds/pipelines while each response is still truncated/stored under the byte caps. The kill-switch and blocking machinery stay intact and still fire on real tripwires. To tighten, supply your own policy via `RALPH_MCP_PROXY_POLICY_FILE` / `RALPH_MCP_PROXY_POLICY_INLINE` (see `docs/TOOLING.md`, `docs/MCP.md`, and the `readonly` / `minimal` profiles in `.ralph/mcp-proxy-policy.example.json`).

## CLI session resume

When a plan runs for Claude Code you can opt in to CLI session resume so the next invocation picks up the stored assistant conversation. Enable it by setting `RALPH_PLAN_CLI_RESUME=1`, passing `--cli-resume`, or answering **yes** when the interactive prompt runs in a TTY. The runner records the active session ID at `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.claude.txt` and the JSON demux helper (`.ralph/python/run-plan-cli-json-demux.py`) uses Python 3 to parse the `stream-json` output and update that file; without Python 3, the plan shrugs it off and continues without resume.

If you need bare resume without an existing session file (for isolated CI or trusted operators), set `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` or pass `--allow-unsafe-resume`. This tells the runtime to invoke `--resume` without relying on the stored session ID. Avoid doing this on shared workstations because it can attach to another user's session.
