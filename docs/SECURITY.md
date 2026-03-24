# Security and workspace trust

Ralph drives **Cursor**, **Claude Code**, or **Codex** against a workspace you choose. There is no substitute for knowing what those tools can read, write, and execute.

## Workspace sandboxing (what Ralph does)

**Codex:** Ralph always invokes the Codex CLI through **`.codex/ralph/codex-exec-prompt.sh`**, which runs `codex exec` with **`--sandbox`** (default mode **`workspace-write`**). Override the mode with **`CODEX_PLAN_SANDBOX`** if your CLI supports other values. By default the script also passes **`--add-dir`** for **`.ralph-workspace/`** so logs, sessions, and human-prompt files stay reachable inside the sandbox. Details: **`.codex/ralph/README.md`** and **`.codex/ralph/codex-exec-prompt.sh`** under your workspace after install.

That is **Codex-specific**. It does not stop every way secrets could leave the machine; it is the one path where Ralph wires in the vendor’s sandbox flag for you.

**Cursor and Claude:** Ralph calls **`cursor-agent` / `agent`** and **`claude`** normally. It does **not** wrap them in an extra OS-level sandbox. For those runtimes, “sandboxing” means **how you set up the repo** (throwaway clone, no production credentials on disk), **tool allowlists** (Claude), **`.cursorignore`** (Cursor), **hooks** (Claude), and **human review**.

**Simplest pattern:** run plans against a **copy** of the project, merge back only after you are happy.

## Protecting sensitive files and prompts

### Cursor: `.cursorignore`

Add **`.cursorignore`** at the repo root (`.gitignore`-style patterns). Cursor uses it for indexing and for Agent / Tab / inline edit. Full reference: [Ignore file (Cursor docs)](https://cursor.com/docs/reference/ignore-file).

**Caveat:** Cursor documents that **terminal and MCP tools** used by Agent are **not** fully governed by `.cursorignore` in the same way, so this is **partial** coverage.

### Claude Code: hooks

Use **hooks** (e.g. pre-tool-use) to block reads or edits you care about. Ralph ships an example at **`.claude/hooks/block-env-reads.sh`** (blocks reads of `.env*`). Copy or adapt it in your project, make it executable, register it in **`.claude/settings.json`**: [Claude Code hooks](https://code.claude.com/docs/en/hooks).

### Codex: ignore lists vs sandbox

`--sandbox` limits how Codex can touch the workspace **per Codex’s rules**; it is not the same as “never read `.env`.” There is still no great repo-local “never send this path to the model” story; see discussion in **[openai/codex#2847](https://github.com/openai/codex/issues/2847#issuecomment-4095749783)**. Combine **`CODEX_PLAN_SANDBOX`**, a clean tree, and minimal secrets on disk.

## Session and human-interaction controls

Files under `.ralph-workspace/sessions/{{PLAN_KEY}}/` are now created with owner-only permissions: the directory itself is `700`, both `pending-human.txt` and `session-id.txt` are `600`, and response processing double-checks that the current user owns `operator-response.txt` before honoring it. These permissions prevent other tenants from reading pending interactions or session tokens while the plan is running.

Because these files can contain prompts, responses, and session identifiers, do not commit `.ralph-workspace/` into multi-tenant or shared repositories. Keep the directory outside the tracked tree and treat it like other sensitive runtime state.

If you override session handling with `RALPH_PLAN_ALLOW_UNSAFE_RESUME=1`, be aware that it forces the runner to reuse existing session files even when they live inside a workspace shared with other users. Only set this in isolated environments you control; in shared hosts keep it unset so each invocation creates fresh, owner-restricted session data.

## MCP server access controls

Ralph exposes an MCP JSON-RPC server for tool execution. Treat it as you would any RPC surface: set `RALPH_MCP_AUTH_TOKEN` to a shared secret so every request must include the matching `authToken` field before the server will run tools. When the token is unset, the server logs a startup warning and continues without authentication, so make sure to only run unauthenticated servers in isolated environments you control.

Always run the MCP server behind authenticated transport in shared environments (e.g., expose it only through an SSH tunnel or bind to a loopback-only socket). That keeps a compromised coworker or tenant from reaching the server even if they have network access to the host.

When your workspace root spans multiple projects or a directory tree with mixed owners, supply `RALPH_MCP_ALLOWLIST` to explicitly limit the directories the server will accept for `workspace`, `plan_path`, or `orchestration_path` parameters. The allowlist is a comma-separated list of absolute prefixes; any request that resolves outside the allowlisted roots is rejected before invoking a tool.
