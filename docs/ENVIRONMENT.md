# Ralph environment variables

This document lists environment variables recognized by Ralph tooling (run-plan, orchestrator, MCP server, and related wrappers). Values shown as defaults are typical when unset; see the referenced scripts for exact behavior.

For **runtime-specific** knobs (`CURSOR_PLAN_*`, `CLAUDE_PLAN_*`, `CODEX_PLAN_*`, `OPENCODE_PLAN_*`), precedence is defined in [`bundle/.ralph/bash-lib/run-plan-env.sh`](../bundle/.ralph/bash-lib/run-plan-env.sh): Cursor-only for `cursor`; each later runtime falls back to the chain (for example Codex uses `CODEX_*` then `CLAUDE_*` then `CURSOR_*`).

## Core plan runner and workspace

| Variable | Purpose |
|----------|---------|
| `RALPH_PLAN_RUNTIME` | Default CLI runtime when `--runtime` is omitted (`cursor`, `claude`, `codex`, `opencode`). |
| `RALPH_PLAN_WORKSPACE_ROOT` | Root for `.ralph-workspace/` (logs, artifacts, sessions). Default: `<workspace>/.ralph-workspace` unless `--workspace-root` overrides. |
| `RALPH_ARTIFACT_NS` | Namespace for logs and templated artifact paths. Default: plan basename; orchestration may set from JSON `namespace`. |
| `RALPH_PLAN_KEY` | Plan namespace (session dir name, metrics keys). Default: plan file basename (sanitized). |
| `RALPH_STAGE_ID` | Set by orchestration per stage; forwarded into logs and usage JSON when present. |
| `RALPH_ORCH_FILE` | Absolute path to the active `.orch.json` (orchestration / handoff injection). |
| `WORKSPACE_ROOT_OVERRIDE` | Same meaning as `--workspace-root` on run-plan and orchestrator: directory that should contain (or be) `.ralph-workspace` data. |

## Session, resume, and human interaction

| Variable | Purpose |
|----------|---------|
| `RALPH_PLAN_SESSION_STRATEGY` | Session behavior between TODOs: `fresh` (default strict isolation), `resume` (continue context), or `reset` (reuse session id and prefix a runtime reset command when configured). |
| `RALPH_PLAN_RESET_COMMAND` | Optional global reset command prefix used in reset mode before each TODO prompt (example: `/clear`). When set, overrides runtime-specific reset command defaults. |
| `RALPH_PLAN_RESET_COMMAND_CLAUDE` / `RALPH_PLAN_RESET_COMMAND_CURSOR` / `RALPH_PLAN_RESET_COMMAND_CODEX` / `RALPH_PLAN_RESET_COMMAND_OPENCODE` | Runtime-specific reset command prefix. Default for Claude is `/clear`; other runtimes default empty. |
| `RALPH_PLAN_CLI_RESUME` | `1` enables CLI session resume (`session-id.<runtime>.txt` and stream parsing). Often set via `--cli-resume` / `--no-cli-resume`. |
| `RALPH_PLAN_SESSION_HOME` | Directory containing `sessions/<plan-key>/` (or equivalent). Default: `${RALPH_PLAN_WORKSPACE_ROOT}/sessions`. |
| `RALPH_PLAN_ALLOW_UNSAFE_RESUME` | `1` allows resume without a stored session id (unsafe on shared machines). `--allow-unsafe-resume` sets this. |
| `RALPH_HUMAN_POLL_INTERVAL` | Seconds between polls for `operator-response.txt` when waiting offline (default commonly `2`). |
| `RALPH_HUMAN_OFFLINE_EXIT` | When `1`, non-TTY human wait may exit instead of blocking (see run-plan-core). |
| `RALPH_HANDOFFS_ENABLED` | `1` (default) injects handoff tasks into plans; `0` disables injection. |
| `RALPH_SKIP_FZF_HINT` | `1` silences the fzf install hint in interactive prompts (set automatically when `fzf` is installed). |
| `RALPH_PLAN_SESSION_MAX_TURNS` | Claude-specific session rotation threshold (default `8`). After this many invocations, the CLI session rotates to cap cache growth. Set `0` to disable rotation. Other runtimes are unaffected. |

## Limits, budgets, and timeouts

| Variable | Purpose |
|----------|---------|
| `CURSOR_PLAN_MAX_ITER` | Max plan iterations (outer loop). Default in core is often `50` unless overridden per runtime chain. |
| `CURSOR_PLAN_GUTTER_ITER` / `CLAUDE_PLAN_GUTTER_ITER` / `CODEX_PLAN_GUTTER_ITER` / `OPENCODE_PLAN_GUTTER_ITER` | Per-TODO retry gutter (attempts on the same open item). `--max-iterations` sets `RALPH_PLAN_TODO_MAX_ITERATIONS`. |
| `RALPH_PLAN_INVOCATION_TIMEOUT_RAW` | Invocation timeout string (e.g. `30m`, `1800s`, `2h`). Set by `--timeout`. |
| `RALPH_PLAN_CONTEXT_BUDGET` | `full`, `standard`, or `lean`; controls how much context is attached to prompts (default `standard`). Invalid values fall back to `standard`. |
| `RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME` | Cap on human-context bytes for fresh invocations when using standard/lean budget (default `2048`). |

## Shared UI and logging (all runtimes)

These names are normalized from runtime-specific variables by `ralph_run_plan_load_env_for_runtime` (see [`run-plan-env.sh`](../bundle/.ralph/bash-lib/run-plan-env.sh)).

| Pattern | Purpose |
|---------|---------|
| `<RUNTIME>_PLAN_VERBOSE` | `1` enables extra runner logging. |
| `<RUNTIME>_PLAN_NO_COLOR` | `1` disables ANSI colors in run-plan output. |
| `<RUNTIME>_PLAN_MAX_ITER` | Upper bound on iterations (with runtime fallback chain). |
| `<RUNTIME>_PLAN_GUTTER_ITER` | Gutter retries per TODO line. |
| `<RUNTIME>_PLAN_PROGRESS_INTERVAL` | Seconds between "still working" progress lines during a long invocation. |
| `<RUNTIME>_PLAN_LOG` | Override path for plan runner log (`plan-runner-*.log`). |
| `<RUNTIME>_PLAN_OUTPUT_LOG` | Override path for combined CLI output log. |
| `<RUNTIME>_PLAN_NO_CAFFEINATE` / `<RUNTIME>_PLAN_CAFFEINATED` | Control macOS `caffeinate` wrapping (Cursor-oriented; see core). |
| `<RUNTIME>_PLAN_DISABLE_HUMAN_PROMPT` | Suppress interactive human prompts when set. |
| `<RUNTIME>_PLAN_NO_OPEN` | Avoid opening URLs or external viewers from the runner when set. |

Replace `<RUNTIME>` with `CURSOR`, `CLAUDE`, `CODEX`, or `OPENCODE` as appropriate.

## Models

| Variable | Purpose |
|----------|---------|
| `CURSOR_PLAN_MODEL` | Model id for Cursor CLI (also fallback for other runtimes when their override unset). |
| `CLAUDE_PLAN_MODEL` | Model id for Claude Code CLI; falls back to `CURSOR_PLAN_MODEL`. |
| `CODEX_PLAN_MODEL` | Model id for Codex; falls back to `CURSOR_PLAN_MODEL`. |
| `OPENCODE_PLAN_MODEL` | Model id for OpenCode; falls back chain through Codex/Claude/Cursor. |

Non-interactive runs require `--agent`, `--model`, or `CURSOR_PLAN_MODEL` (see run-plan-core).

## Codex-specific

| Variable | Purpose / options |
|----------|-------------------|
| `CODEX_PLAN_CLI` | Codex executable name or path (also `CODEX_CLI` may set this in invoke helper). |
| `CODEX_PLAN_SANDBOX` | Codex sandbox mode passed to `codex exec --sandbox` (set via `--codex-sandbox` in [`bundle/.ralph/bash-lib/run-plan-args.sh`](../bundle/.ralph/bash-lib/run-plan-args.sh) or by exporting `CODEX_PLAN_SANDBOX`; consumed by [`bundle/.codex/ralph/codex-exec-prompt.sh`](../bundle/.codex/ralph/codex-exec-prompt.sh)). Allowed values: `read-only`, `workspace-write` (default), `danger-full-access` (high risk; see `codex exec --help`). Not applied on `codex exec resume` paths the same way. |
| `CODEX_PLAN_FULL_AUTO` | `1` (default) emits `--full-auto`, which sets both sandbox preset (to `workspace-write`) and approvals preset (to `on-request`). `0` omits `--full-auto` and relies on explicit `--sandbox` instead. **Interaction with CODEX_PLAN_SANDBOX:** Combining `--full-auto` with `--sandbox` values other than `workspace-write` may be order-dependent per Codex CLI semantics. If you need a strict `read-only` or `danger-full-access` sandbox, set `CODEX_PLAN_FULL_AUTO=0` to avoid the full-auto preset. |
| `CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX` | `1` appends `--dangerously-bypass-approvals-and-sandbox` (also known as `--yolo`) to Codex exec calls, removing all sandbox and approval controls. Default `0`. Use only in isolated, trusted environments. **Caveat:** Resume paths may not honor this flag consistently; see [openai/codex#9144](https://github.com/openai/codex/issues/9144). |
| `CODEX_PLAN_NO_ADD_AGENTS_DIR` | `1` omits `--add-dir` on `.ralph-workspace` for non-resume runs. |
| `CODEX_PLAN_EXEC_EXTRA` | Extra words appended to the `codex` argv before the prompt (space-separated). |
| `RALPH_PLAN_CAPTURE_USAGE` | When `1` (default), Codex wrapper passes `--json` so token usage can be recorded. |

## Claude-specific (invoke)

| Variable | Purpose |
|----------|---------|
| `CLAUDE_PLAN_CLI` | Claude Code CLI executable. |
| `CLAUDE_PLAN_NO_ALLOWED_TOOLS` | `1` omits `--allowedTools`. |
| `CLAUDE_PLAN_ALLOWED_TOOLS` | Overrides default tool list (comma-separated or as CLI expects). |
| `CLAUDE_TOOLS_FROM_AGENT` | Tools string from agent config when not overridden. |
| `RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS` | When `1` (default), passes `--exclude-dynamic-system-prompt-sections`. |
| `RALPH_CLAUDE_MAX_BUDGET_USD` / `RALPH_AGENT_MAX_BUDGET` | Soft budget caps passed as `--max-budget-usd` when set. |
| `CLAUDE_PLAN_BARE` | `1`/truthy enables `claude --bare` (also via `--claude-bare`), `0` disables it (also via `--no-claude-bare`). Upstream says `--bare` "skips hooks, LSP, plugin sync, attribution, auto-memory, prefetches, keychain reads, and CLAUDE.md auto-discovery." This axis defaults to `0` and should be treated as an opt-in API-key mode. `CLAUDE_PLAN_MINIMAL` defaults to `1` and enables auth-safe flag composition (`--disable-slash-commands`, `--strict-mcp-config`, `--mcp-config '{"mcpServers":{}}'`, `--setting-sources project,local`, `--tools ...`). When reset mode is actively using a reset command, Ralph omits `--disable-slash-commands` so the reset command can run. `CLAUDE_PLAN_MINIMAL_TOOLS` defaults to `Bash,Read,Edit,Write` and overrides the tools list used in minimal mode. |
| `CLAUDE_PLAN_MINIMAL_DISABLE_MCP` | When `1` (default) and Claude minimal mode is active, Ralph passes `--strict-mcp-config` and an empty `--mcp-config`. Set to `0` or use `--claude-allow-mcp` so project-defined MCP servers still load while other minimal flags remain. `--no-claude-allow-mcp` sets `1` explicitly. |
| `CLAUDE_PLAN_PERMISSION_MODE` | Claude permission mode passed to `claude --permission-mode` (also via `--claude-permission-mode`). Allowed values: `default`, `acceptEdits`, `auto`, `bypassPermissions`, `dontAsk`, `plan`. Default: omit the flag and let Claude use its own default. Modes such as `auto`, `bypassPermissions`, and `dontAsk` can skip or auto-approve prompts, so use them only in trusted workspaces. |

## Orchestrator

| Variable | Purpose |
|----------|---------|
| `ORCHESTRATOR_VERBOSE` | `1` mirrors orchestrator log lines to stderr. |
| `ORCHESTRATOR_DRY_RUN` | `1` prints steps without executing runners. |
| `ORCHESTRATOR_RUNNER_TO_CONSOLE` | When `0`, runner output goes only to the orchestrator log (no live `tee` to console). |
| `ORCHESTRATOR_HUMAN_ACK` | `1` enforces per-stage `humanAck` gates. |
| `ORCHESTRATOR_NO_COLOR` | Disable color in orchestrator messages (see orchestrator script). |

## MCP server

| Variable | Purpose |
|----------|---------|
| `RALPH_MCP_AUTH_TOKEN` | When set, JSON-RPC calls must include matching `authToken`. |
| `RALPH_MCP_ALLOWLIST` | Comma-separated allowed workspace/orchestration path prefixes. |
| `RALPH_MCP_WORKSPACE` | Workspace root for the MCP server (example in AGENTS.md). |

## Safety and usage prompt

| Variable | Purpose |
|----------|---------|
| `RALPH_USAGE_RISKS_ACKNOWLEDGED` | Set to `1` to skip the interactive usage-risk prompt (CI and automation). |

## Dashboard (Node)

| Variable | Purpose |
|----------|---------|
| `PORT` | HTTP port for `npm start` in `ralph-dashboard` (default if unset is package-specific). |

---

Maintainers: when adding new env-driven behavior, update this file and the short list in [`AGENTS.md`](../AGENTS.md) so agents and users have one canonical reference.
