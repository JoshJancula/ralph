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

- `tools/list` – advertises `ralph_run_plan`, `ralph_plan_status`, and `ralph_orchestrator_run`.
- `tools/call` – accepts exactly those three tool names and enforces workspace/plan/orchestration validation, runtime whitelisting, and argument safety before executing the helper scripts. Any other tool name yields `tool not found` (`-32601`).

## Agent catalog resource

- **URI:** `resource://ralph/agents`
- **Description:** Aggregates every agent configuration that lives under `.cursor/agents/`, `.claude/agents/`, and `.codex/agents/`. `resources/list` advertises the catalog; `resources/read` returns a Markdown document that lists each agent ID, the relative path to its `config.json`, the declared `model`, and the published description.
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

3. **Guard rails.** `RALPH_MCP_WORKSPACE` is the only workspace the server will act on; tool calls that escape that path are rejected. When you switch workspaces, restart the server with the new path.

4. **Confirm connectivity.** Run `cursor mcp list` (or your client's equivalent) to ensure the server responds.

For Claude Code, the host expects a project-scoped `.mcp.json` at the workspace root. Copy **`.claude/mcp.example.json`** (in your workspace after install) to `.mcp.json` (same idea as Cursor’s `.cursor/mcp.example.json` templates), update the script path, `RALPH_MCP_WORKSPACE`, and `PATH` for your environment, then rerun `claude mcp list` to confirm the entry is available.

For Codex, MCP servers are configured in `config.toml` (`~/.codex/config.toml` or project-scoped `.codex/config.toml`). Copy the `[mcp_servers.ralph]` block from **`.codex/mcp.example.toml`** into your config, set `args` to the path of `.ralph/mcp-server.sh` in your workspace, and set `RALPH_MCP_WORKSPACE` and `PATH` in `[mcp_servers.ralph.env]`. Then run `codex mcp --help` or use `/mcp` in the Codex TUI to confirm the server is available.

### Environment guard rails

- `RALPH_MCP_WORKSPACE` is the only workspace the server will act on; tool calls that escape that path are rejected.
- `RALPH_MCP_ALLOWLIST` lets you whitelist additional directories. Supply colon/comma/semicolon-separated entries (relative entries are resolved under `RALPH_MCP_WORKSPACE`, and `~` expands to the user home). The server canonicalizes each path, ensures it exists, logs the configured roots, and rejects tool calls that try to operate outside this set with a JSON-RPC error.
- The server spawns `cursor`, `claude`, and `codex` runners, so the `PATH` that Cursor inherits must include their installers (`/opt/homebrew/bin`, `~/.local/bin`, etc.). Explicitly set `PATH` inside your MCP server `env` block (see the example below) so it can launch all runtimes regardless of how you installed them.
- If your workspace uses multiple artifact namespaces (per plan, per feature), set `RALPH_ARTIFACT_NS` before starting the server so log and artifact paths stay predictable for downstream tools.

### Tool stream limits

The MCP server currently truncates any single tool response (stdout or stderr) to 32 KiB before it writes the JSON-RPC response back to the host. Long-running commands that emit more than 32 KiB will still finish, but the host will only see the trailing chunk. If you need the full raw streams for auditing or debugging, capture them yourself (for example, redirect `run-plan.sh` output to a workspace file or artifact path) and keep only the truncated tail for the MCP response so the client still receives the summary it expects.

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

Ralph's bash MCP server (`mcp-server.sh`) exposes **plan and orchestration** tools to an external MCP client. It does **not** provide a browser, Playwright, or other product-specific integrations. When `.ralph/run-plan.sh` runs the **qa** agent (or any agent) via Cursor, Claude Code, or Codex, only the **tools that runtime has configured** are available. To let QA open a browser, call external APIs through MCP, or use other skills, add those MCP servers to **that** runtime's configuration and approve tool use according to your policy.

Official references:

- Codex: [Model Context Protocol (Codex)](https://developers.openai.com/codex/mcp)
- Cursor: [Model Context Protocol (MCP)](https://cursor.com/docs/mcp) and [MCP in the Cursor CLI](https://cursor.com/docs/cli/mcp)
- Claude Code: [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)

### Example: Playwright MCP

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

You should see the Ralph server. Your OpenClaw assistant can then use Ralph tools (e.g. plan status, run plan, agent catalog) in conversation. The same guard rails apply: `RALPH_MCP_WORKSPACE` is the only workspace the server will act on unless you set `RALPH_MCP_ALLOWLIST`.
