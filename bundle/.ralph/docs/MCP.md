# Ralph MCP server and resources

The MCP server lets an external orchestrator (e.g. Claude) run Ralph plans and orchestration via tools. The **canonical server is bash + jq**, so no `pip`, no Node, and no extra runtime beyond Ralph's existing requirements. Run it from your workspace root with:

```bash
RALPH_MCP_WORKSPACE=/path/to/your/workspace bash .ralph/mcp-server.sh
```

Configure your MCP host (e.g. Cursor) to start that command over stdio.

## Prerequisites in your project

A normal install drops **`.ralph/`** into your workspace, which includes **`mcp-server.sh`** and the rest of the shared scripts. You do not need Python or Node for this server, only **`bash`** and **`jq`**. The guides in this folder are also copied to **`.ralph/docs/`** if you used an install that includes shared **`.ralph`**.

---

## Agent catalog resource

- **URI:** `resource://ralph/agents`
- **Description:** Aggregates every agent configuration that lives under `.cursor/agents/`, `.claude/agents/`, and `.codex/agents/`. The resource returns a Markdown catalog listing each agent ID, the path to its `config.json`, its `model` declaration, and the published description.
- **Consumption:** Use any MCP-capable client to call `resources/read` with the URI. The returned Markdown is safe to render in dashboards or include as context for downstream agents.

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
  - `workspace` (required) – absolute path to the workspace (defaults to the MCP server's configured root).
  - `plan_path` (required) – the plan file path relative to the workspace root (e.g., `PLAN.md`).
- **Behavior:** The prompt reminds the orchestrator to consult `resource://ralph/agents`, call `ralph_plan_status` (or the future `ralph_list_next_todo` tool), and articulate the `ralph_run_plan` invocation that should follow.

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
