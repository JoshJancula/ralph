# Security and workspace trust

Ralph drives Cursor, Claude Code, Codex, or OpenCode against a workspace you choose. Those assistants can read files, write files, and run shell commands, so there is no substitute for knowing what they can reach. The simplest safe pattern: run plans against a copy of the project and merge back only after review.

## What Ralph sandboxes (and what it does not)

**Codex:** Ralph always invokes the Codex CLI with `--sandbox` (default mode `workspace-write`; override with `CODEX_PLAN_SANDBOX`). It also passes `--add-dir` for `.ralph-workspace/` so logs and session files stay reachable inside the sandbox. This is the one runtime where Ralph wires in the vendor's sandbox flag for you -- it limits how Codex touches the workspace, but it is not a guarantee that secrets never leave the machine.

**Cursor and Claude:** Ralph calls `cursor-agent` and `claude` normally, with no extra OS-level sandbox. For these runtimes, "sandboxing" means how you set up the repo (throwaway clone, no production credentials on disk), tool allowlists (Claude), `.cursorignore` (Cursor), hooks (Claude), and human review.

**Ralph's own MCP tools** bound output size, not capability. The default proxy policy is permissive on purpose: `ralph_proxy_shell` can run arbitrary commands in a trusted workspace while responses stay capped and stored. Supply a stricter policy to change that; see [TOOLING.md](TOOLING.md#policy-and-caps).

## Protecting sensitive files

**Cursor:** add a `.cursorignore` file at the repo root (`.gitignore`-style patterns). Cursor uses it for indexing and for Agent / Tab / inline edits. Caveat: Cursor documents that terminal and MCP tools are not fully governed by `.cursorignore`, so this is partial coverage. Reference: [Ignore file (Cursor docs)](https://cursor.com/docs/reference/ignore-file).

**Claude Code:** use hooks to block reads or edits you care about. Ralph ships an example at `.claude/hooks/block-env-reads.sh` (blocks reads of `.env*`); copy or adapt it, make it executable, and register it in `.claude/settings.json`. Reference: [Claude Code hooks](https://code.claude.com/docs/en/hooks).

**Codex:** `--sandbox` limits workspace access per Codex's rules; it is not the same as "never read `.env`". There is still no great repo-local "never send this path to the model" mechanism (see [openai/codex#2847](https://github.com/openai/codex/issues/2847#issuecomment-4095749783)). Combine `CODEX_PLAN_SANDBOX`, a clean tree, and minimal secrets on disk.

## Files Ralph changes on your machine during a run

When you opt into Ralph mode or native adapters (see [TOOLING.md](TOOLING.md)), Ralph temporarily edits runtime config files for the duration of one plan run and restores them on exit:

- `<workspace>/.cursor/mcp.json` and `<workspace>/.cursor/hooks.json` (Cursor)
- `<workspace>/.claude/settings.json` hook entries (Claude)
- A staged plugin file under `<workspace>/.opencode/plugins/` (OpenCode)
- Temp MCP config files passed to Claude, Codex, and OpenCode

Every mutation is journaled under `.ralph-workspace/runtime-config/<plan-key>/` with byte-exact backups in `originals/`. Normal exits restore everything automatically; crashes and force-kills are recovered at the next run start, or manually with `.ralph/cleanup-plan.sh --runtime-config <plan-key>`. Details: [TOOLING.md](TOOLING.md#overlay-state-and-cleanup).

## Runtime state can contain sensitive content

`.ralph-workspace/` holds logs, session files, prompts, and stored tool results. Stored tool results in particular can contain anything an agent read or ran: file contents, grep matches, shell output. Nothing is encrypted; nothing is uploaded.

- Do not commit `.ralph-workspace/` (the installer's `.gitignore` patterns treat it as local-only).
- Exclude it from backups or shares when the workspace handles sensitive data.
- Run `.ralph/cleanup-plan.sh <plan-key>` after sensitive plan runs to remove that plan's logs, sessions, artifacts, and stored tool results.

Session files are created with owner-only permissions: `.ralph-workspace/sessions/<plan-key>/` is `700`, and `pending-human.txt` / `session-id.<runtime>.txt` are `600`. Response processing also checks that the current user owns `operator-response.txt` before honoring it, so other tenants on a shared host cannot read pending interactions or inject answers.

`RALPH_PLAN_ALLOW_UNSAFE_RESUME=1` makes the runner reuse session state without a stored session ID. Only set it in isolated environments you control; on shared hosts leave it unset so each invocation creates fresh, owner-restricted session data.

When the operator approves a permission block, Ralph can write a session-local override alongside the plan session files:

- `killswitch-override.json` for killswitch-backed command, tool, and path approvals
- `opencode-permission-override.json` for OpenCode `external_directory` approvals
- `runtime-permission-overrides.sh` for session-local Claude tool allowlists and Codex extra `--add-dir` paths

These overrides are reloaded on the next retry for the same plan session.

## Kill switch

The killswitch blocks dangerous commands or file access before they execute. When a violation is detected, Ralph logs the event, pauses for operator input when the run is waiting on a human, and writes a sentinel so downstream orchestration stages do not proceed.

In Ralph mode, a fatal proxy or policy violation (denied tool, denied argument pattern, path traversal) writes a sentinel to `.ralph-workspace/security/kill-switch.<plan-key>.json` recording the tool, category, reason, and a redacted argument summary. The MCP server exits non-zero, and the plan runner checks for a current-run sentinel before and after each runtime invocation, so a tripped run fails instead of advancing to the next orchestrator stage. Stale sentinels from earlier runs are logged and ignored.

### Configuration locations

Ralph loads killswitch config from the first file found in this order:

| Priority | Path | Use case |
|----------|------|----------|
| 1 | `$WORKSPACE/.ralph-workspace/killswitch.json` | Per-project overrides |
| 2 | `$RALPH_HOME/killswitch.json` | Global config (when using global install) |
| 3 | Bundle default | Ships with Ralph |

To customize, copy the bundle default to your workspace or global location and edit:

```bash
# Per-project (stays in .ralph-workspace, which is gitignored)
ralph config killswitch init

# Global (after global install; applies when no workspace override exists)
ralph config killswitch init --global

# See which config is active and where to edit
ralph config killswitch

# Open an existing config in $EDITOR
ralph config killswitch edit
ralph config killswitch edit --global
```

The bundle default path (for scripts) is `$(ralph --bundle-path)/killswitch.json`.

### Configuration reference

```json
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": false,
  "banned_tools": [],
  "allowed_tools": [],
  "banned_paths": [".env*", "**/.env*", "**/secrets/**"],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "custom_rules": [
    {"name": "no_sudo", "pattern": "^sudo\\s", "target": "command"},
    {"name": "no_rm_rf_root", "match": "rm -rf /", "target": "command"}
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | integer | Yes | Config format version (current: 2) |
| `enabled` | boolean | Yes | Set `false` to disable killswitch entirely |
| `dry_run` | boolean | Yes | When `true`, log violations but do not kill the runner |
| `banned_tools` | array | Yes | Tool names or glob patterns to block |
| `banned_paths` | array | Yes | File path glob patterns to block (supports `~` expansion) |
| `allowed_tools` | array | No | Tool names or glob patterns to allow through a ban |
| `allowed_paths` | array | No | File path glob patterns to allow through a ban |
| `allowed_commands` | array | No | Command substrings to allow through a ban |
| `allowed_patterns` | array | No | Regex patterns to allow through a ban |
| `custom_rules` | array | Yes | Command matching rules (see below) |

### Custom rules

Each rule in `custom_rules` must have a `name` and either `match` or `pattern`:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Human-readable name for logging |
| `match` | string | Plain substring to match (case-sensitive) |
| `pattern` | string | Regex pattern to match |
| `target` | string | What to match against (currently only `"command"`) |

Use `match` for simple substrings: `{"name": "no_rm_rf", "match": "rm -rf", "target": "command"}`

Use `pattern` for regex when you need anchors: `{"name": "no_sudo", "pattern": "^sudo\\s", "target": "command"}`

### Banned paths

Path patterns use glob syntax with `~` expansion:

```json
"banned_paths": [".env*", "**/.env*", "**/secrets/**", "~/.ssh/**", "~/.aws/**"]
```

### Banned tools

Block specific tools by name or glob pattern:

```json
"banned_tools": ["curl", "wget", "nc*"]
```

### Environment variable overrides

These env vars add to (not replace) the config file values:

| Variable | Description |
|----------|-------------|
| `RALPH_KILLSWITCH_DISABLED=1` | Disable killswitch entirely |
| `RALPH_BANNED_TOOLS` | Comma-separated tool names to add |
| `RALPH_BANNED_PATHS` | Comma-separated path patterns to add |
| `RALPH_BANNED_PATTERNS` | Comma-separated regex patterns to add (uses bash ERE) |

### Dry-run mode

Set `"dry_run": true` in your config to log violations without killing the runner. Violations land in `.ralph-workspace/killswitch-violations.log` in JSONL format. Review the log to tune rules before enabling enforcement.

### What happens when killswitch triggers

1. Logs the violation to `.ralph-workspace/killswitch-violations.log` (JSONL format)
2. Writes triggered status to `.ralph-workspace/killswitch-triggered.json`
3. Kills the runner process tree (unless `dry_run: true`)
4. Exits with code 77

The plan runner checks for killswitch sentinels before and after each runtime invocation. A tripped run fails instead of advancing to the next orchestration stage.

### Common examples

**Block destructive commands:**

```json
{
  "custom_rules": [
    {"name": "no_rm_rf", "match": "rm -rf", "target": "command"},
    {"name": "no_force_push", "match": "git push --force", "target": "command"},
    {"name": "no_hard_reset", "match": "git reset --hard", "target": "command"}
  ]
}
```

**Block elevated privileges:**

```json
{
  "custom_rules": [
    {"name": "no_sudo", "pattern": "^sudo\\s", "target": "command"},
    {"name": "no_su", "pattern": "^su\\s", "target": "command"}
  ]
}
```

**Protect credentials:**

```json
{
  "banned_paths": [".env*", "**/.env*", "**/secrets/**", "**/*.pem", "**/*.key", "~/.ssh/**", "~/.aws/**"]
}
```

## MCP server access controls

Treat the Ralph MCP server like any RPC surface:

- Set `RALPH_MCP_AUTH_TOKEN` to a shared secret so every request must include the matching `authToken`. Without it, the server warns at startup and runs unauthenticated -- acceptable only in isolated environments you control.
- In shared environments, expose the server only through authenticated transport (an SSH tunnel, or a loopback-only socket).
- When the workspace root spans directories with mixed owners, set `RALPH_MCP_ALLOWLIST` (comma-separated absolute path prefixes) to limit which directories the server accepts for `workspace`, `plan_path`, or `orchestration_path`. Requests resolving outside the allowlist are rejected before any tool runs.
