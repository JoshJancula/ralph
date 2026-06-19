# Ralph MCP server and resources

The MCP server lets an external orchestrator (e.g. Claude) run Ralph plans and orchestration via tools. The **canonical server is bash + jq**, so no `pip`, no Node, and no extra runtime beyond Ralph's existing requirements. Run it from your workspace root with:

```bash
RALPH_MCP_WORKSPACE=/path/to/your/workspace bash .ralph/mcp-server.sh
```

Configure your MCP host (e.g. Cursor) to start that command over stdio.

## Prerequisites in your project

A normal install drops **`.ralph/`** into your workspace, which includes **`mcp-server.sh`** and the rest of the shared scripts. You do not need Python or Node for this server, only **`bash`** and **`jq`**. The guides in this folder are also copied to **`.ralph/docs/`** if you used an install that includes shared **`.ralph`**.

---

## Supported MCP surface today

The canonical MCP server implementation described in this doc is the Bash script at `bundle/.ralph/mcp-server.sh`. The server implements **only** the JSON-RPC methods listed below; any other method currently returns `method not found` (`-32601`). Keep this doc aligned with the script so the surface you depend on matches the actual behavior that Cursor, Claude, or Codex sees.

### lifecycle & capability methods

- `initialize` / `initialized` – announces `{ "tools": { "listChanged": false }, "resources": { "listChanged": false }, "prompts": { "listChanged": false } }` so hosts know the available capabilities.
- `shutdown` – responds with `{ "status": "shutting_down" }`.
- `exit` – replies `{ "status": "exiting" }` and terminates the server process.

### resource discovery

- `resources/list` – advertises `resource://ralph/agents` as the only catalog entry.
- `resources/read` – accepts `resource://ralph/agents` and returns the Markdown catalog content.

### prompt discovery

- `prompts/list` – lists the single `ralph_run_next_todo_prompt` definition.
- `prompts/get` – requires `plan_path`, validates the optional `workspace`, and returns the templated guidance for scheduling the next unchecked TODO.

### tools

- `tools/list` – advertises `ralph_run_plan`, `ralph_plan_status`, `ralph_orchestrator_run`, and proxy tools such as `ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_shell`, and the async shell lifecycle tools when enabled.
- `tools/call` – dispatches those tool names (orchestration handlers plus bounded `ralph_proxy_*` read tools). Any other tool name yields `tool not found` (`-32601`).

## Agent catalog resource

- **URI:** `resource://ralph/agents`
- **Description:** Aggregates every Ralph agent configuration that lives under `.cursor/agents/`, `.claude/agents/`, `.codex/agents/`, `.opencode/agents/`, and Ralph's Antigravity metadata under `.agents/agents/`. Antigravity's native persona registry is `.agents/agents.md`; the MCP catalog uses `config.json` metadata for model and artifact validation. `resources/list` advertises the catalog; `resources/read` returns a Markdown document that lists each agent ID, the relative path to its `config.json`, the declared `model`, and the published description.
- **Consumption:** Call `resources/read` with the URI and render the `text` of the first entry in `contents`. The response follows the MCP resources schema: `contents` is an array of `{ "uri", "mimeType", "text" }` blocks, so clients can display the Markdown or include it in plan context.

Example outline:

```
# Ralph agent catalog

Workspace root: `/path/to/workspace`

## Cursor agents

- **implementation** (`.cursor/agents/implementation/config.json`)
  - model: `auto`
  - Implements code changes per architecture.
```

## Next unchecked TODO prompt

- **Name:** `ralph_run_next_todo_prompt`
- **Purpose:** Guides the orchestrator to inspect the next unchecked TODO in a plan and determine which runtime/agent should execute it.
- **Arguments:**
  - `workspace` (optional) – absolute path to the workspace (defaults to the MCP server's configured root).
  - `plan_path` (required) – the plan file path relative to the workspace root (e.g., `PLAN.md`).
- **Behavior:** `prompts/list` advertises the prompt and its arguments. `prompts/get` returns a user-message template that reminds the orchestrator to consult `resource://ralph/agents`, call `ralph_plan_status`, and articulate the following `ralph_run_plan` invocation.

Use `prompts/get` with the prompt name and arguments to pull the textual template before composing the next tool call.

## Durable MCP setup (`ralph setup --mcp`)

After a global or in-repo install, use `ralph setup --mcp` to merge a durable Ralph MCP server entry into the runtime config your IDE reads. This is the same merge logic the installer uses when it offers MCP configuration; run it again any time you add a project, move a checkout, or want to refresh paths.

```bash
ralph setup --runtime <claude|cursor|codex|opencode|antigravity> [--runtime-dir <path>] --mcp [--dry-run] [--yes]
ralph setup --runtime claude --hooks --mcp    # hooks plus MCP
ralph setup --runtime cursor --runtime-dir /path/to/project/.cursor --all
```

Default `--runtime-dir` is `$PWD/.$runtime`. Project root (for `RALPH_MCP_WORKSPACE`) is the parent of that directory. The command prefers `<project>/.ralph/mcp-server.sh` when present; otherwise it uses `$RALPH_HOME/bundle/.ralph/mcp-server.sh`. Existing third-party MCP entries are preserved; invalid JSON or TOML aborts without partial writes. Each Ralph entry sets `RALPH_MODE=hybrid`.

| Runtime | Durable MCP target | Notes |
|---------|-------------------|-------|
| Cursor | `<runtime-dir>/mcp_config.json` | Typically `<project>/.cursor/mcp.json`. |
| Claude | `<project>/.mcp.json` | **Project root**, not inside `.claude/`. Claude Code reads `.mcp.json` at the workspace root. |
| Codex | `<runtime-dir>/config.toml` | Typically `<project>/.codex/config.toml`. **Trusted-project caveat:** Codex loads project-scoped `.codex/` layers (including `config.toml` and project-local hooks) only when the project is trusted. If Ralph MCP does not appear, mark the project trusted in `~/.codex/config.toml`, for example `[projects."/absolute/path/to/project"]` with `trust_level = "trusted"`, or trust the project from the Codex UI. Untrusted projects skip project-local MCP and hooks. |
| OpenCode | `<project>/opencode.json` | Project-root `opencode.json` with `mcp.ralph` (`type: "local"`, `command: ["bash", "<server>"]`, `enabled: true`). **MCP-first recommendation:** native OpenCode hooks are not proven on headless `opencode run`; treat durable MCP (and `ralph setup --mcp` or `--ralph-mode hybrid` on plan runs) as the authoritative path for bounded tools and compaction. Use `--hooks` only when you also use the OpenCode UI and accept that hook effectiveness may vary. |
| Antigravity | `<runtime-dir>/mcp_config.json` | Typically `<project>/.agents/mcp_config.json` with `mcpServers.ralph` (`type: "stdio"`, `command: "bash"`, `args: ["<server>"]`). |

Use `ralph setup --mcp --dry-run` to see exact target files before writing. Combine with `--hooks` or `--all` when you also want durable native adapters; see [TOOLING.md](TOOLING.md#durable-hooks-and-mcp-ralph-setup).

## Enabling the MCP server

1. **Use the bash server.** From the workspace root (after Ralph is installed so `.ralph/` exists):
   ```bash
   RALPH_MCP_WORKSPACE="$PWD" bash .ralph/mcp-server.sh
   ```

2. **Configure your MCP host.** In Cursor (or another MCP client), add a stdio server entry. Example (adjust the path to your repo or installed Ralph):
   ```json
   {
     "ralph": {
       "command": "bash",
       "args": [ "/absolute/path/to/.ralph/mcp-server.sh" ],
       "env": { "RALPH_MCP_WORKSPACE": "/absolute/path/to/workspace" }
     }
   }
   ```
   The server reads JSON-RPC from stdin and writes to stdout; the host manages the process.

3. **Guard rails.** `RALPH_MCP_WORKSPACE` is the project root the server acts on; proxy tools also honor `RALPH_AGENT_WORKSPACE`, `RALPH_PLAN_WORKSPACE_ROOT`, `RALPH_MCP_ALLOWLIST`, and read-only `$HOME/.cursor/plans` / `$HOME/.claude/plans`. Paths outside allowed roots are rejected. When you switch roots, restart the server with the new paths.

4. **Confirm connectivity.** Run `cursor mcp list` (or your client's equivalent) to ensure the server responds.

For Claude Code, the host expects a project-scoped `.mcp.json` at the workspace root. Prefer `ralph setup --runtime claude --mcp`, which writes or merges `<project>/.mcp.json` (not a file under `.claude/`). Manual alternative: copy **`.claude/mcp.example.json`** to `.mcp.json`, update the script path, `RALPH_MCP_WORKSPACE`, and `PATH`, then rerun `claude mcp list`.

For Codex, MCP servers are configured in `config.toml` (`~/.codex/config.toml` or project-scoped `.codex/config.toml`). Prefer `ralph setup --runtime codex --mcp`, which merges into `<project>/.codex/config.toml`. Remember the **trusted-project caveat:** project-local `.codex/config.toml` is ignored until Codex trusts the project (see [Durable MCP setup](#durable-mcp-setup-ralph-setup---mcp)). Manual alternative: copy the `[mcp_servers.ralph]` block from **`.codex/mcp.example.toml`**, set `args` to `.ralph/mcp-server.sh`, and set `RALPH_MCP_WORKSPACE` and `PATH` in `[mcp_servers.ralph.env]`. Confirm with `codex mcp --help` or `/mcp` in the Codex TUI.

For OpenCode, prefer `ralph setup --runtime opencode --mcp`, which merges `mcp.ralph` into project-root `opencode.json`. Use MCP as the primary integration path; native hooks are optional and unproven headless (see [TOOLING.md](TOOLING.md#durable-hooks-and-mcp-ralph-setup)).

For Antigravity, prefer `ralph setup --runtime antigravity --mcp`, which merges `mcp.ralph` into `.agents/mcp_config.json`.

For Antigravity, prefer `ralph setup --runtime antigravity --mcp`, which merges `mcpServers.ralph` into `<project>/.agents/mcp_config.json`.

#### Codex Ralph MCP smoke testing

Ralph includes a smoke test that verifies Codex can receive the MCP config and make harmless tool calls through the Ralph MCP server. The test runs by default using a Codex CLI stub; no real Codex installation or authentication is required.

To opt into the real Codex CLI smoke test when Codex is installed and authenticated on your machine, set:
```bash
RALPH_CODEX_REAL_MCP_SMOKE=1 bash scripts/run-bats.sh tests/bats/run-plan/run-plan-invoke-codex-mcp-smoke.bats
```

Without the real Codex CLI or the opt-in env var, the test skips the real path with a clear message and the stubbed path runs. The test verifies that:
- The ephemeral MCP config is generated with the correct Ralph MCP server reference and workspace path.
- Proxy config arguments (e.g., `--config mcp_servers.ralph.enabled=true`) are correctly assembled.
- The stub or real Codex CLI accepts the config without errors.

- The stub now emits a realistic NDJSON transcript that includes a completed `ralph_proxy_read` `mcp_tool_call`, so the smoke will fail if Codex cannot reach that proxy tool anymore.
- With `RALPH_CODEX_REAL_MCP_SMOKE=1` the smoke runs the actual Codex CLI (defaulting to `gpt-5.4-mini`) and asserts that the captured usage transcript contains a completed `ralph_proxy_read` tool call before declaring success.

This smoke test demonstrates that the end-to-end Ralph MCP wiring for Codex is sound and that Codex can discover and invoke Ralph proxy tools like `ralph_proxy_read`.

### Ralph mode (plan runs)

Plan runs default to **Ralph mode: no** (no Ralph MCP injection). When you pass `--ralph-mode ralph` on [`.ralph/run-plan.sh`](../bundle/.ralph/run-plan.sh), Ralph injects an ephemeral MCP config for [`.ralph/mcp-server.sh`](../bundle/.ralph/mcp-server.sh) (orchestration tools plus `ralph_proxy_*` read helpers). Agent `mcp_servers` are merged over ambient configuration before Ralph's protected `ralph` server is added. Policy-based filtering and truncation run inside that single server; Ralph does not replace every runtime-native built-in tool.

**Precedence in `ralph`/`hybrid` mode:**
1. Native ambient MCP servers (from runtime's own config)
2. Agent `mcp_servers` declarations (override ambient with same name)
3. Ralph's protected `ralph` MCP server

See **[AGENTS.md](../AGENTS.md#agent-mcp-servers)** for the full `mcp_servers` syntax and **[TOOLING.md](TOOLING.md)** for `--ralph-mode`, `RALPH_MODE`, the interactive prompt, workspace preferences, the runtime matrix, and available tools.

### Environment guard rails

Ralph uses a **three-root model** (project root, state root, agent workspace). See [AGENTS.md](../AGENTS.md#three-root-model) for flags, defaults, and examples.

- `RALPH_MCP_WORKSPACE` is the **project root** the server was started with. When `RALPH_PROJECT_ROOT`, `RALPH_AGENT_WORKSPACE`, and `RALPH_PLAN_WORKSPACE_ROOT` are unset, `RALPH_MCP_WORKSPACE` alone defines backward-compatible behavior.
- Plan-run injection forwards all four roots to the ephemeral MCP server. Proxy read/search tools allow paths under `RALPH_MCP_WORKSPACE` (project root), `RALPH_AGENT_WORKSPACE`, `RALPH_PLAN_WORKSPACE_ROOT`, and `RALPH_MCP_ALLOWLIST` entries. Missing files inside an allowed root return a non-fatal "path does not exist" tool error; traversal or paths outside allowed roots trigger a fatal kill-switch sentinel under `RALPH_PLAN_WORKSPACE_ROOT/security/`.
- `$HOME/.cursor/plans` and `$HOME/.claude/plans` are always readable (read-only) so agents can reference original plan files from Cursor and Claude Code. Read-style proxy tools (`ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_search`, `ralph_proxy_repomap`) accept paths under these directories; write/edit tools reject them.
- `RALPH_MCP_ALLOWLIST` lets you whitelist additional directories beyond the three roots. Supply colon/comma/semicolon-separated entries (relative entries are resolved under `RALPH_MCP_WORKSPACE`, and `~` expands to the user home). The server canonicalizes each path, ensures it exists, logs the configured roots, and rejects tool calls that try to operate outside the allowed set with a JSON-RPC error.
- The server spawns `cursor`, `claude`, `codex`, `opencode`, and `antigravity` (`agy`) runners, so the `PATH` that Cursor inherits must include their installers (`/opt/homebrew/bin`, `~/.local/bin`, etc.). Explicitly set `PATH` inside your MCP server `env` block (see the example below) so it can launch all runtimes regardless of how you installed them.
- If your workspace uses multiple artifact namespaces (per plan, per feature), set `RALPH_ARTIFACT_NS` before starting the server so log and artifact paths stay predictable for downstream tools.

### Tool stream limits (Ralph MCP only)

The Ralph MCP server truncates **its own** JSON-RPC tool and resource responses when they exceed configured policy caps (`resultByteCap`, `toolResultByteCaps`, and `proxyOwnedTools` limits). This applies to Ralph MCP `tools/call` results (including `ralph_proxy_*`) and MCP `resources/read` payloads. It does **not** cap runtime-native tools such as Claude `Read`, `Bash`, or `Grep`, or Cursor/Codex equivalents; those remain under the host runtime's control.

Legacy resource tail reads also use a 32 KiB ceiling in `mcp-tools.sh` (`MAX_TOOL_TAIL_BYTES`) before policy shaping runs. When policy is loaded, per-tool caps in `toolResultByteCaps` take precedence for matching MCP tool names and methods (see [TOOLING.md](TOOLING.md#policy-and-caps) for naming rules: policy fields are camelCase; `toolResultByteCaps` keys are exact MCP identifiers and may include underscores or slashes).

If you need full raw streams for auditing or debugging, capture them yourself (for example, redirect `run-plan.sh` output to a workspace file or artifact path) instead of relying on truncated MCP responses.

The default policy is permissive out of the box: `proxyOwnedTools.allowAllCommands` and `proxyOwnedTools.allowShellOperators` are `true` and `shellTimeoutSeconds` is generous, so `ralph_proxy_shell` can run arbitrary commands, operators (`&&`, `|`, redirects), and longer builds or pipelines in a trusted local dev loop. This reflects the proxy's actual promise: it bounds output (policy caps + stored-result envelopes), it does not sandbox. For commands that may outlive a host MCP request timeout, use `ralph_proxy_shell_start` to get a `jobId`, then prefer `ralph_proxy_shell_wait` (optionally tuning `waitSeconds` to control how long the server waits before reporting the current status) so you wait for completion without hammering the proxy. Runner-first verification remains the default path for any command that proves TODO completion, so treat `ralph_proxy_shell_status` as a manual follow-up for occasional progress checks, avoid short-interval polling loops, and inspect output with `ralph_proxy_shell_read` / cancel with `ralph_proxy_shell_cancel` if needed. Set `RALPH_PROXY_SHELL_ASYNC=0` to hide those tools. The kill-switch and blocking machinery stay fully intact and still fire on real tripwires (tool denylists, `deniedArgumentPatterns`, path traversal).

Runner-first policy:

- Declare verification commands via plan/TODO `verification:` / `verify:` metadata so the runner executes them out-of-process rather than relying on agent-side `ralph_proxy_shell_start` + `ralph_proxy_shell_status` loops. The runner captures the full transcripts under `.ralph-workspace/artifacts/<PLAN_KEY>/verification/`, keeps the next prompt compact, and reopens the TODO with artifacts when verification fails.
- When you rerun a declared verification command interactively, start it with `ralph_proxy_shell_start` and block on completion using `ralph_proxy_shell_wait` (pass `waitSeconds` to limit how long the server waits). Prefer `shell_wait` so the wait happens server-side instead of hammering the proxy with repeated `shell_status` polls.
- Treat `ralph_proxy_shell_status` as an occasional manual progress check and avoid short-interval polling loops; inspect output via `ralph_proxy_shell_read` and cancel with `ralph_proxy_shell_cancel` if needed. For exploratory jobs, rely on `shell_wait` as the primary blocker so `shell_status` remains a manual spot check rather than the default loop.

To tighten shell access, supply your own policy via `RALPH_MCP_PROXY_POLICY_FILE` or `RALPH_MCP_PROXY_POLICY_INLINE` (for example set `proxyOwnedTools.allowAllCommands` to `false` with an explicit `shellAllowlist`); see `bundle/.ralph/mcp-proxy-policy.example.json`.

## Audited launch contract

The PLAN30 audit ensures the MCP surface, runtime wiring, and kill-switch behavior are consistent across Cursor, Claude, Codex, OpenCode, and Antigravity when Ralph mode is explicitly set to `ralph` or `hybrid`.

### Runtime wiring summary

- **Cursor** merges the injected `mcpServers.ralph` entry into the workspace `.cursor/mcp.json`, always emits `stdio: true`, `command: ["bash", "<server_script>"]`, and `env.RALPH_MCP_WORKSPACE`, and restores the original bytes (or removes the file) after the run.
- **Claude** launches with `--strict-mcp-config --mcp-config <temp>`, adds MCP-qualified proxy tools, and, once the MCP preflight succeeds, strips native `Bash` from the built-in schema so commands run through the bounded `ralph_proxy_shell`; set `RALPH_CLAUDE_RALPH_STRICT_PROXY=0` to keep native `Bash` temporarily for troubleshooting. Native `Read`/`Edit`/`Write` stay available because Claude Code requires a native `Read` before it will `Edit`/`Write` a file (a `ralph_proxy_read` does not satisfy that gate), so stripping `Read` would deadlock edits; proxy reads remain preferred for bounded large reads. For read-only plans you can also set `RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ=1` to strip native `Read` too (which disables native edits of existing files).
- **Codex** injects `--config mcp_servers.ralph.* --strict-config`, sets `mcp_servers.ralph.enabled=true`, and when the CLI accepts it sets `mcp_servers.ralph.required=true` so the runtime fails closed if the MCP server cannot start. When supported, Ralph also injects `mcp_servers.ralph.default_tools_approval_mode` (default `approve`) so Ralph-owned proxy tools are not cancelled in non-interactive runs. Optional-field compatibility is probed under the same `--strict-config` mode Ralph uses for the real invocation: if the installed CLI rejects `mcp_servers.ralph.type` or `default_tools_approval_mode`, Ralph omits only that field and still passes other supported keys such as `required=true`.
- **OpenCode** writes a temp JSON config for `OPENCODE_CONFIG`, merges `mcp.ralph` into any existing JSON or JSONC file so comments survive, and keeps every other key untouched. **Strict proxy enforcement not supported:** Because OpenCode cannot selectively hide native tools before the model executes, Ralph fails before the CLI is invoked when strict proxy mode is enabled (`RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=1` or `RALPH_STRICT_PROXY=1`). This prevents wasting an invocation on unavoidable policy violations. Set `RALPH_OPENCODE_ALLOW_STRICT_PROXY_BESTEFFORT=1` to permit post-execution audit/warning behavior, or use Claude/Cursor for enforced proxy-only Ralph mode.
- **Antigravity** writes a temp JSON config for `ANTIGRAVITY_CONFIG` when needed and merges `mcp.ralph` into `.agents/mcp_config.json` for durable setups. The antigravity model contract applies: Ralph lists models via `agy models` and invokes the CLI with `agy --model "<exact model string from agy models>"`.

### `ralph_run_plan` contract

`ralph_run_plan` is the audited launch helper in `tools/list`. Each invocation must specify `workspace`, `plan_path`, `runtime` (`cursor`, `claude`, `codex`, `opencode`, or `antigravity`), and `agent`. Declare Ralph mode via `env_overrides.RALPH_MODE` (`no`, `native`, `ralph`, or `hybrid`) or pass `--ralph-mode <mode>` on the generated command. Invalid values return `-32602`.

`env_overrides` is limited to Ralph-owned names (for example `RALPH_MODE`, `RALPH_KNOWLEDGE_*`, `RALPH_MCP_PROXY_POLICY*`, `RALPH_PLAN_*`, runtime model selectors, etc.). Shapes outside that allowlist or values with unsafe bytes are rejected. The handler runs:

```
.ralph/run-plan.sh --runtime <runtime> --plan <plan_path> --agent <agent> --workspace <workspace> --ralph-mode <mode>
```

with the overrides delivered via `env KEY=value ...` (no shell eval) so the workspace argument always uses `--workspace`.

### `tools/list` invariants

- `tools/list` always advertises orchestration/status tools (`ralph_run_plan`, `ralph_plan_status`, `ralph_orchestrator_run`) plus `ralph_proxy_result_read`, `ralph_proxy_result_search`, and `ralph_proxy_result_summary`. The list is deterministic (name-sorted) so hosts can rely on stable ordering.
- In `RALPH_MODE=ralph` or `RALPH_MODE=hybrid`, `tools/list` also advertises the Ralph proxy catalog: `ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_shell`, and async shell lifecycle tools when `RALPH_PROXY_SHELL_ASYNC` is not `0`.
- In `RALPH_MODE=native`, `tools/list` exposes only the orchestration/status tools and the three `ralph_proxy_result_*` follow-up tools; proxy read/search/shell tools stay hidden.
- The standalone Ralph MCP server fails immediately when `RALPH_MODE=no`.
- Optional knowledge helpers (`ralph_knowledge_record`, `ralph_knowledge_query`, `ralph_knowledge_status`) appear only when the matching `RALPH_KNOWLEDGE_*` env vars enable them; policy caps never hide them once they are turned on, and `--ralph-mode native` keeps them hidden.

When `RALPH_PROXY_SHELL_ASYNC` is enabled, the async helpers appear (`ralph_proxy_shell_start`, `_wait`, `_status`, `_read`, and `_cancel`). Prefer `_wait` for blocking follow-up work, treat `_status` as a manual progress check, and avoid short-interval polling loops—read output through `_read` and cancel via `_cancel` when you need to intervene.

Many MCP hosts namespace tool names with the server label. When Codex or Claude connects to the Ralph server, their `tools/list` output looks like `mcp__ralph__ralph_proxy_read`, `mcp__ralph__ralph_proxy_shell`, or `mcp__ralph__ralph_knowledge_query`. The `mcp__<server>__` prefix is purely a naming convention to keep server/tool pairs distinct; the server still implements the core `ralph_proxy_*` and `ralph_knowledge_*` handlers documented here.

### Kill-switch sentinel behavior

Fatal policy violations, out-of-workspace attempts, or banned shell commands write a sentinel such as `.ralph-workspace/security/kill-switch.<plan-key>.json` containing `timestamp`, `workspace`, `plan_key`, `tool`, `category`, `reason`, and a hashed or redacted argument summary. The MCP server exits with a reserved non-zero code; `.ralph/run-plan.sh` checks for a current-run sentinel before starting a runtime and after it exits, logging the failure and exiting non-zero so orchestrator stages fail instead of advancing. Stale sentinels from earlier runs are ignored, and RALPH_MODE=no or native runs ignore Ralph MCP sentinels unless `RALPH_MCP_ENFORCE_KILL_SWITCH_NATIVE=1` is set. Only an explicit escape hatch (for example `RALPH_MCP_POLICY_VIOLATION_MODE=error`) permits non-fatal behavior for special fixtures.

### Operator approvals (unified server + plan-runner only)

The canonical server supports three policy modes: `fatal` (default) that writes the kill-switch sentinel, `error` that returns a recoverable JSON-RPC error instead of exiting, and `approve` that pauses for operator input on a denied proxy-owned request before retrying. The approval mode is only active when `.ralph/run-plan.sh` is running with `RALPH_AGENT_TOOL_ACCESS=ralph` so the watcher can scan `$RALPH_PLAN_WORKSPACE_ROOT/security/approvals/<plan-key-safe>/`, read requests, and honor decision files. Every operator approval request, including those for `ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_search`, and (when enabled) `ralph_proxy_repomap`, creates `request.<id>.json` in that directory. The server waits for the matching `decision.<id>.json` (owned by the current plan-runner UID) with either `"decision":"approve"` or `"decision":"deny"` before retrying just the denied call; every other policy guard stays in effect. Each final outcome appends a JSONL audit line to `approvals.log` so you can review approvals, denials, timeouts, and their metadata later.

The plan-run watcher (`bundle/.ralph/bash-lib/run-plan/run-plan-approvals.sh`) polls the approvals directory, emits JSON-RPC progress notifications, and keeps artifacts under `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/` current. Interactive runs print a notice to `/dev/tty`; headless runs write `APPROVAL-REQUIRED.md` and `approvals.md` that list pending request IDs, decision-file paths, tool summaries, and next steps so an operator can simply write `{"id":"<request id>","decision":"approve","reason":"..."}` or a deny with an optional reason. Approved calls retry once, a repeated denial surfaces as a recoverable tool error, and the watcher keeps updating the artifacts until every decision file exists so the plan can resume automatically.

Because this approval flow depends on the watcher being able to respond, any other context—including manually starting `.ralph/mcp-server.sh`, the standalone `.ralph/mcp-proxy-server.sh`, or headless MCP runs without the watcher—keeps obeying the existing `fatal` (or explicitly configured `error`) behavior and never waits on operator input.

## Cursor host configuration example

Once the server is running, add a host-level configuration so Cursor can launch it with `cursor mcp`. Create or update `.cursor/mcp.json` and include at least one `mcpServers` entry whose `command` binds stdio to the canonical bash entrypoint. The snippet below uses the **root of the project where you ran `install.sh`** (e.g. your app or boilerplate repo). That is where `.ralph/` was copied, so the script path is `<project-root>/.ralph/mcp-server.sh` and `RALPH_MCP_WORKSPACE` is that same project root. Replace `/path/to/your-project` with your project's absolute path and adjust `PATH` to include the installed Cursor/Claude/Codex binaries.

```json
{
  "mcpServers": [
    {
      "name": "ralph-mcp",
      "label": "Ralph plan runner host",
      "command": [
        "bash",
        "/path/to/your-project/.ralph/mcp-server.sh"
      ],
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "RALPH_MCP_WORKSPACE": "/path/to/your-project"
      },
      "stdio": true
    }
  ]
}
```

Copy this block into `.cursor/mcp.json` or start from `.cursor/mcp.example.json` so you can repeatably stash the template. Set both the script path and `RALPH_MCP_WORKSPACE` to your project root (where Ralph is installed), and set `PATH` for your machine before saving.

The `stdio` flag tells Cursor to speak the MCP protocol over the server's standard input/output stream. Once Cursor sees the server listed in `cursor mcp list`, you can run plan tooling with `cursor mcp run <server-name> ...`. The inline `env` block keeps the runtime CLIs and workspace guard rails in sync for every connection.

---

## Third-party MCP servers (browser and tools for plan agents)

Ralph's bash MCP server (`mcp-server.sh`) exposes **plan and orchestration** tools to an external MCP client. It does **not** provide a browser, Playwright, or other product-specific integrations. When `.ralph/run-plan.sh` runs the **qa** agent (or any agent) via Cursor, Claude Code, Codex, OpenCode, or Antigravity, only the **tools that runtime has configured** are available. To let QA open a browser, call external APIs through MCP, or use other skills, add those MCP servers to **that** runtime's configuration and approve tool use according to your policy.

Ralph preserves each runtime's native MCP configuration chain and merges agent-specific `mcp_servers` on top. See [AGENTS.md](AGENTS.md) for the native configuration preservation table.

Official references:

- Codex: [Model Context Protocol (Codex)](https://developers.openai.com/codex/mcp)
- Cursor: [Model Context Protocol (MCP)](https://cursor.com/docs/mcp) and [MCP in the Cursor CLI](https://cursor.com/docs/cli/mcp)
- Claude Code: [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)

### Agent-specific MCP servers

Agents can declare optional `mcp_servers` in their canonical frontmatter or `config.json`. This allows agents to reference ambient MCP servers or define portable inline servers.

**Precedence (highest to lowest)**:
1. Native ambient MCP servers (runtime's own configuration)
2. Agent `mcp_servers` declarations (override ambient servers with the same name)
3. Ralph's protected `ralph` MCP server (in `ralph`/`hybrid` mode)

**Reserved name**: The server name `ralph` is reserved; agents cannot reference, redefine, or replace it.

### mcp_servers syntax

The `mcp_servers` field accepts an array of:

**String references** (ambient server names):
```yaml
mcp_servers:
  - playwright
  - github
```

**Portable definitions** (inline server configuration):
```yaml
mcp_servers:
  - name: my-api
    transport: http
    url: https://api.example.com/v1/mcp
    headers:
      Authorization: ${API_TOKEN}
  - name: local-tool
    transport: stdio
    command: node
    args:
      - /path/to/server.js
    env:
      API_KEY: ${LOCAL_API_KEY}
```

**Supported transports**:

| Transport | Required fields | Optional fields |
|-----------|-----------------|-----------------|
| `stdio` | `name`, `transport`, `command` | `args` (array), `env` (map with `${ENV_VAR}` refs) |
| `http` | `name`, `transport`, `url` | `headers` (map with `${ENV_VAR}` refs) |

**Secret policy**: All credential values must use `${ENV_VAR}` references. Literal secrets matching credential patterns are rejected at validation. Secrets are resolved at invocation time and never persisted to disk.

**Failure behavior**: Unresolved `${ENV_VAR}` references, invalid server definitions, missing environment variables, or use of the reserved `ralph` name cause validation failures before model invocation. Error messages include the runtime, agent, and searched source paths.

### Example: Playwright MCP

[Playwright's MCP server](https://www.npmjs.com/package/@playwright/mcp) is a common choice for browser automation and visual checks during QA work.

**Adding via agent definition**:
```yaml
mcp_servers:
  - playwright
```

Or with explicit configuration:
```yaml
mcp_servers:
  - name: playwright
    transport: stdio
    command: npx
    args:
      - -y
      - '@playwright/mcp@latest'
```

**Codex**

[Playwright's MCP server](https://www.npmjs.com/package/@playwright/mcp) is a common choice for browser automation and visual checks during QA work.

**Codex**

Add the stdio server (requires Node/`npx` on `PATH`):

```bash
codex mcp add playwright -- npx -y @playwright/mcp@latest
```

Some servers ask the user for input through MCP **elicitation**. To allow that when Codex applies granular approval policy, set in `~/.codex/config.toml` or project-scoped `.codex/config.toml` (see [Codex MCP](https://developers.openai.com/codex/mcp)):

```toml
[approval_policy.granular]
mcp_elicitations = true
```

Use `/mcp` in the Codex TUI or `codex mcp --help` to inspect servers, OAuth login, and timeouts.

**Cursor**

MCP is shared between the editor and the Cursor CLI `agent`. Configure servers in `.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global) as described in the [Cursor MCP guide](https://cursor.com/docs/mcp). Then use the [CLI MCP commands](https://cursor.com/docs/cli/mcp) to list, enable, or authenticate:

```bash
agent mcp enable playwright
```

Use `agent mcp list` first if you need to confirm the server name or connection status; add or fix the Playwright entry in `mcp.json` if it does not appear.

**Claude Code**

Options such as `--transport` and `--env` must come **before** the server name; the stdio command and its arguments follow `--` (see [Claude Code MCP](https://code.claude.com/docs/en/mcp)):

```bash
claude mcp add --transport stdio playwright -- npx -y @playwright/mcp@latest
```

Use `claude mcp list`, `claude mcp get playwright`, and `/mcp` inside Claude Code for OAuth and status. For team-shared entries, consider `--scope project` so the repo carries a `.mcp.json` (with secrets supplied via environment expansion, not committed values).

### Other MCP servers and safety

The same pattern applies to documentation indexes, issue trackers, observability, and other MCP packages: register them on the **runtime that executes the plan**, not inside `mcp-server.sh`. Review each server's tools and data access, use restricted credentials where possible, and align auto-approval settings with your threat model (see [SECURITY.md](SECURITY.md)).

---

### Troubleshooting agent MCP servers

**Agent MCP server not found.** If an agent references an ambient MCP server by name (e.g., `mcp_servers: ["playwright"]`), verify the server is configured in the runtime's native MCP configuration. Error messages include the runtime, agent, and searched source paths.

**Missing environment variable.** Secrets in portable definitions must use `${ENV_VAR}` references. If the referenced environment variable is unset at invocation time, the run fails before launching the CLI with the missing variable name.

**Reserved name collision.** The server name `ralph` is reserved for Ralph's protected MCP server. Agents cannot reference, redefine, or replace it. Attempting to use `ralph` in `mcp_servers` causes a validation error.

**Literal secret rejected.** Values matching credential patterns (API keys, tokens, passwords) must use `${ENV_VAR}` references. Literal secrets are rejected at validation to prevent credential leakage.

**Orchestration stage MCP servers.** Each orchestration stage receives only its selected agent's MCP additions. Stages with different agents have isolated MCP catalogs. See [AGENTS.md](../AGENTS.md#agent-mcp-servers).

---

## Connecting from OpenClaw

[OpenClaw](https://openclaw.ai/) is a personal AI assistant that runs on your machine and can use MCP servers as skills. With the Ralph MCP server configured, OpenClaw can run Ralph plans, check plan status, and use the agent catalog from chat (e.g. WhatsApp, Telegram, Discord).

**Prerequisites:** OpenClaw installed and Ralph installed in the workspace you want OpenClaw to control (so `.ralph/mcp-server.sh` exists).

**Configuration:** OpenClaw reads MCP servers from `~/.openclaw/openclaw.json` under `mcpServers`. Add a stdio entry that runs the bash server with the same environment as above.

1. **Locate your config.** Create or edit `~/.openclaw/openclaw.json`.

2. **Add the Ralph MCP server.** Use the workspace where Ralph is installed (the directory that contains `.ralph/`). Replace `/path/to/your-project` with that path and ensure `PATH` includes your Cursor/Claude/Codex binaries so the server can spawn runners:

```json
{
  "mcpServers": {
    "ralph": {
      "command": "bash",
      "args": ["/path/to/your-project/.ralph/mcp-server.sh"],
      "transport": "stdio",
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "RALPH_MCP_WORKSPACE": "/path/to/your-project"
      }
    }
  }
}
```

If `mcpServers` already exists, add the `"ralph"` block alongside your other servers.

3. **Restart and verify.** Restart the OpenClaw gateway so it picks up the new server, then list MCP servers:

```bash
openclaw gateway restart
openclaw mcp list
```

You should see the Ralph server. Your OpenClaw assistant can then use Ralph tools (e.g. plan status, run plan, agent catalog) in conversation. The same guard rails apply: proxy tools allow the project root (`RALPH_MCP_WORKSPACE`), agent workspace, state root, `RALPH_MCP_ALLOWLIST` entries, and read-only `$HOME/.cursor/plans` / `$HOME/.claude/plans`.
