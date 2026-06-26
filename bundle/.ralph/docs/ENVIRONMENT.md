# Ralph environment variables

This document lists environment variables recognized by Ralph tooling (run-plan, orchestrator, MCP server, and related wrappers). Values shown as defaults are typical when unset; see the referenced scripts for exact behavior.

For **runtime-specific** knobs (`CURSOR_PLAN_*`, `CLAUDE_PLAN_*`, `CODEX_PLAN_*`, `OPENCODE_PLAN_*`, `ANTIGRAVITY_PLAN_*`), precedence is defined in [`bundle/.ralph/bash-lib/run-plan/run-plan-env.sh`](../bundle/.ralph/bash-lib/run-plan/run-plan-env.sh): Cursor-only for `cursor`; each later runtime falls back to the chain (for example Antigravity uses `ANTIGRAVITY_*` then `OPENCODE_*` then `CODEX_*` then `CLAUDE_*` then `CURSOR_*`).

## Core plan runner and workspace

Ralph distinguishes three roots (see also [AGENTS.md](../AGENTS.md#three-root-model)):

| Root | Variable / flag | Default |
|------|-----------------|---------|
| Project root | `RALPH_PROJECT_ROOT` (exported); `--workspace` / `--project-root` | Current directory when cwd is the project |
| State root | `RALPH_PLAN_WORKSPACE_ROOT`; `--workspace-root` | `<project-root>/.ralph-workspace` |
| Agent workspace | `RALPH_AGENT_WORKSPACE`; `--agent-workspace` | Directory that invoked `run-plan.sh` |

`RALPH_MCP_WORKSPACE` is the project root passed to the MCP server. Plan-run injection also forwards `RALPH_PROJECT_ROOT`, `RALPH_AGENT_WORKSPACE`, and `RALPH_PLAN_WORKSPACE_ROOT` when set. Standalone servers that set only `RALPH_MCP_WORKSPACE` keep backward-compatible behavior.

| Variable | Purpose |
|----------|---------|
| `RALPH_PLAN_RUNTIME` | Default CLI runtime when `--runtime` is omitted (`cursor`, `claude`, `codex`, `opencode`, `antigravity`). |
| `RALPH_PROJECT_ROOT` | Exported Ralph project root; same as `--workspace` / `--project-root` after canonicalization. Locates `.ralph/` and resolves project-relative plan paths. |
| `RALPH_PLAN_WORKSPACE_ROOT` | State root for `.ralph-workspace/` (logs, artifacts, sessions, security sentinels). Default: `<project-root>/.ralph-workspace` unless `--workspace-root` overrides. |
| `RALPH_AGENT_WORKSPACE` | Agent sandbox root for model execution and MCP proxy path policy. Default: directory that invoked `run-plan.sh`. Set via `--agent-workspace` or env before launch. |
| `RALPH_ARTIFACT_NS` | Namespace for logs and templated artifact paths. Default: plan basename; orchestration may set from JSON `namespace`. |
| `RALPH_PLAN_KEY` | Plan namespace (session dir name, metrics keys). Default: plan file basename (sanitized). |
| `RALPH_STAGE_ID` | Set by orchestration per stage; forwarded into logs and usage JSON when present. |
| `RALPH_ORCH_FILE` | Absolute path to the active orchestration file (set by the orchestrator; used for handoff injection). |
| `WORKSPACE_ROOT_OVERRIDE` | Same meaning as `--workspace-root` on run-plan and orchestrator: directory that should contain (or be) `.ralph-workspace` data. |

## Plan format and consolidation

Plan templates should use one logical, independently verifiable todo per checkbox (typical feature plans: about 8–30 todos). Open tasks must use `- [ ]` (space before `]`); `- []` is ignored.

| Variable | Purpose |
|----------|---------|
| `RALPH_PLAN_FORMAT` | Force `default` (markdown checkbox) or `cursor` (YAML frontmatter with `todos[]`). Auto-detect when unset. |
| `RALPH_PLAN_CONSOLIDATE` | `1` runs a one-time pass at plan load that collapses adjacent unchecked todos sharing the same obvious verb and target; off by default. |
| `RALPH_PLAN_RESUME_HINT` | `0` suppresses the stderr hint to enable `RALPH_PLAN_CLI_RESUME` on long plans. |
| `RALPH_PLAN_RESUME_HINT_THRESHOLD` | Unchecked todo count that triggers the resume hint when resume is off (default `25`). |
| `RALPH_PLAN_AGENT_POLL_INTERVAL` | Seconds between polls while monitoring the background agent process (default `1`; Bats sets `0.1`). |
| `RALPH_PLAN_AGENT_MARKS_TODOS` | off (default `0`). When `1`, per-TODO prompts instruct the agent to edit the plan file and mark `- [x]` on the open line. Default runner-owned marking (print `AGENT_INVOCATION_COMPLETE` only; the runner marks the TODO) is preferred. |

## Session, resume, and human interaction

| Variable | Purpose |
|----------|---------|
| `RALPH_PLAN_SESSION_STRATEGY` | Session behavior between TODOs: `fresh` (default strict isolation), `resume` (continue context), `reset` (reuse session id and prefix a runtime reset command when configured), or `compact` (reuse session id and prefix a runtime-specific compact command before each TODO prompt). Interactive TTY runs prompt for session strategy unless already set via flag or env var. |
| `RALPH_PLAN_RESET_COMMAND` | Optional global reset command prefix used in reset mode before each TODO prompt (example: `/clear`). When set, overrides runtime-specific reset command defaults. |
| `RALPH_PLAN_RESET_COMMAND_CLAUDE` / `RALPH_PLAN_RESET_COMMAND_CURSOR` / `RALPH_PLAN_RESET_COMMAND_CODEX` / `RALPH_PLAN_RESET_COMMAND_OPENCODE` / `RALPH_PLAN_RESET_COMMAND_ANTIGRAVITY` | Runtime-specific reset command prefix. Default for Claude is `/clear`; other runtimes default empty. |
| `RALPH_PLAN_COMPACT_COMMAND` | Optional global compact command prefix used in compact mode before each TODO prompt. When set, overrides runtime-specific compact command defaults. |
| `RALPH_PLAN_COMPACT_COMMAND_CURSOR` / `RALPH_PLAN_COMPACT_COMMAND_CODEX` / `RALPH_PLAN_COMPACT_COMMAND_OPENCODE` | Runtime-specific compact command prefix. Default for Cursor is `/compress`; default for Codex is `/compact`; OpenCode and Antigravity do not support compact mode (must use fresh/resume/reset). |
| `RALPH_PLAN_CLI_RESUME` | `1` enables CLI session resume (`session-id.<runtime>.txt` and stream parsing). Often set via `--cli-resume` / `--no-cli-resume`. |
| `RALPH_PLAN_SESSION_HOME` | Directory containing `sessions/<plan-key>/` (or equivalent). Default: `${RALPH_PLAN_WORKSPACE_ROOT}/sessions`. |
| `RALPH_PLAN_ALLOW_UNSAFE_RESUME` | `1` allows resume without a stored session id (unsafe on shared machines). `--allow-unsafe-resume` sets this. |
| `RALPH_PLAN_HINT_FEED_FORWARD` | `1` (default) enables the prompt-efficiency feed-forward optimization: Ralph saves the prior invocation's `tool_call_target_telemetry.optimization_hint_line` into `.ralph-workspace/sessions/<plan-key>/last-efficiency-hint.txt` and appends it to the next prompt; set `0` to disable capture and replay. |
| `RALPH_HUMAN_POLL_INTERVAL` | Seconds between polls for `operator-response.txt` when waiting offline (default commonly `2`). |
| `RALPH_HUMAN_OFFLINE_EXIT` | When `1`, non-TTY human wait may exit instead of blocking (see run-plan-core). |
| `RALPH_HANDOFFS_ENABLED` | `1` (default) injects handoff tasks into plans; `0` disables injection. |
| `RALPH_SKIP_FZF_HINT` | `1` silences the fzf install hint in interactive prompts (set automatically when `fzf` is installed). |
| `RALPH_PLAN_SESSION_MAX_TURNS` | Claude-specific session rotation threshold (default `8`). After this many invocations, the CLI session rotates to cap cache growth. Set `0` to disable rotation. Other runtimes are unaffected. |
| `RALPH_CACHE_READ_PER_TURN_WARN` | `60000` | Threshold for the context-bloat hint emitted by `tool_call_target_telemetry.optimization_hint_line`. When the derived `cache_read_per_tool_turn` exceeds this integer cache-read token limit, Ralph emits the optimization hint that suggests trimming cached context or reducing tool turns. Cache-read fields are model/provider dependent and are telemetry only; they are not Ralph's primary context-control mechanism (see [OpenCode hybrid contract](TOOLING.md#opencode-hybrid-contract)). |
| `RALPH_OPENCODE_SET_CACHE_KEY` | OpenCode-specific prompt-cache injection (default `1`). Injection runs in every `--ralph-mode` (`native`, `hybrid`, `ralph`, or unset), independent of MCP or native-hooks gating. When enabled and the merged ambient OpenCode config declares no cache settings for the selected provider, Ralph deep-merges `provider.<id>.options.setCacheKey: true` into the per-run temp `OPENCODE_CONFIG` (provider id is the segment of the model before the first `/`, e.g. `ollama-cloud/kimi-k2.6` -> `ollama-cloud`). For openai-compatible passthrough providers (currently `ollama-cloud`) Ralph additionally injects a per-model `prompt_cache_key` (`ralph-<plan-slug>`) because OpenCode's `setCacheKey` emits camelCase `promptCacheKey`, which those providers pass through verbatim and the upstream API ignores. A string-form ambient `provider` field (instead of null or object) causes a clean logged skip with no config changes. Ambient provider options are never overwritten. Set `0` to opt out. When opted out or when Ralph makes no changes (no injection, no MCP merge, no hooks staging), the user-supplied `OPENCODE_CONFIG` is passed through untouched. See the cache strategy notes in [`.opencode/README.md`](../.opencode/README.md#cache-strategy). |

## Limits, budgets, and timeouts

| Variable | Purpose |
|----------|---------|
| `CURSOR_PLAN_MAX_ITER` | Max plan iterations (outer loop). Default in core is often `50` unless overridden per runtime chain. |
| `CURSOR_PLAN_GUTTER_ITER` / `CLAUDE_PLAN_GUTTER_ITER` / `CODEX_PLAN_GUTTER_ITER` / `OPENCODE_PLAN_GUTTER_ITER` / `ANTIGRAVITY_PLAN_GUTTER_ITER` | Per-TODO retry gutter (attempts on the same open item). `--max-iterations` sets `RALPH_PLAN_TODO_MAX_ITERATIONS`. |
| `RALPH_PLAN_INVOCATION_TIMEOUT_RAW` | Invocation timeout string (e.g. `30m`, `1800s`, `2h`). Set by `--timeout`. |
| `RALPH_PLAN_CONTEXT_BUDGET` | `full`, `standard`, or `lean`; controls how much context is attached to prompts (default `standard`). Invalid values fall back to `standard`. |
| `RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME` | Cap on human-context bytes for fresh invocations when using standard/lean budget (default `2048`). |

## Post-TODO verification

When a TODO is marked complete, Ralph runs a declared verification command after the model invocation (via `run-plan-post-verify.sh`) instead of leaving it to the agent in-context. Verification output is captured and suppressed from the next prompt; byte counts feed `verification_bytes_suppressed` in the plan usage summary. Failing verifications reopen the TODO and inject only a compact summary plus an artifact path.

Runner-first policy: whenever a TODO lists commands that prove completion, declare them via the YAML/TODO `verification:` / `verify:` metadata so the runner executes them out-of-process, stores the transcript under `.ralph-workspace/artifacts/<PLAN_KEY>/verification/`, and keeps large outputs out of the next prompt. Resist rerunning those commands through agent-side async loops (`ralph_proxy_shell_start` + `ralph_proxy_shell_status`)—those tools are a manual fallback surface for when a human is directly monitoring a job, not the primary automation path.

- Prefer plan/TODO verification for every command that proves TODO completion so the runner handles the heavy work out-of-process and the next prompt stays focused on the remaining tasks.
- When you rerun a declared verification manually, start it with `ralph_proxy_shell_start` and block on completion with `ralph_proxy_shell_wait` (pass `waitSeconds` to limit how long the server waits). The async shell tools are a manual fallback—`shell_wait` is the blocking call only when a human is directly monitoring a job.
- Treat `ralph_proxy_shell_status` as an occasional manual spot check and never use it as a polling loop; inspect output via `ralph_proxy_shell_read` and cancel via `ralph_proxy_shell_cancel` if you must intervene.

Post-verification runs by default when any of these declare a command: plan YAML frontmatter `verify:`, a TODO `Post-Verify:` / `Verify:` / `Verification:` line, or `RALPH_VERIFY_AFTER_TODO`. Set `RALPH_POST_VERIFY=0` to opt out.

The runner marks a completed TODO first and then runs a single verification gate, so behavior is identical whether or not the agent emitted the `AGENT_INVOCATION_COMPLETE` sentinel. Every runner-executed verification command is isolated from stdin (it reads from `/dev/null`) and bounded by `RALPH_VERIFY_TIMEOUT` (default `300` seconds) so an interactive or hung command — for example an installer that prompts on `/dev/tty` — fails fast and reopens the TODO instead of freezing the run. A timed-out command is reported as a failure with a `verification command timed out` summary. The runner prints a `Running verification checks now (line N)` status line to the terminal before each check and a pass/fail/timeout line after, so a long check is never a silent gap.

When a TODO declares a runnable verification command but the agent emits no completion sentinel, that command also acts as the completion signal that lets the runner mark the TODO. Set `RALPH_PLAN_VERIFY_TO_COMPLETE=0` to disable using a verification command as the completion signal for sentinel-less runs.

### Prose verification and the `VERIFICATION_RESULT` contract

When a TODO declares a verification step that is not a runnable shell command (prose such as "open the page and confirm the panel renders"), the runner cannot machine-check it, so it asks the agent to run the steps and report the result. The agent must end such a TODO with a single `VERIFICATION_RESULT` line:

- `VERIFICATION_RESULT: PASS` when every step passes. Print `VERIFICATION_RESULT: PASS` even when there were no steps or nothing required checking.
- `VERIFICATION_RESULT: FAIL: <reason>` when any step fails.

Followed by `AGENT_INVOCATION_COMPLETE`. The verdict is requested on the first invocation, so a compliant agent reports it in one pass with no extra round-trip.

Rules:
- A TODO with **no** declared verification step never demands a verdict; it completes on the `AGENT_INVOCATION_COMPLETE` sentinel alone.
- A TODO **with** a declared verification step that ends with no `VERIFICATION_RESULT` line (or an explicit `FAIL`) is reopened and retried, bounded by the gutter limit (`CURSOR_PLAN_GUTTER_ITER` / `CLAUDE_PLAN_GUTTER_ITER` / `CODEX_PLAN_GUTTER_ITER` / `OPENCODE_PLAN_GUTTER_ITER` / `ANTIGRAVITY_PLAN_GUTTER_ITER`, default `3`). Omitting the verdict on a verified TODO is the agent's omission, not a runner quirk — always print one `VERIFICATION_RESULT` line to avoid the rerun.

| Variable | Purpose |
|----------|---------|
| `RALPH_PLAN_VERIFY_TO_COMPLETE` | Default `1`. When `1`, a declared runnable verification command can serve as the completion signal for a successful agent invocation that emitted no completion sentinel, letting the runner mark the TODO. Set `0` to require the sentinel. The unified verification gate still runs afterward. |
| `RALPH_POST_VERIFY` | Default `1`. When `0`, skip the verification gate entirely even when the plan or TODO declares a verify command. |
| `RALPH_VERIFY_TIMEOUT` | Default `300` (seconds). Per-command wall-clock limit for every runner-executed verification command. On timeout the command is killed and reported as a failure (the TODO reopens). Uses `timeout`/`gtimeout` when available and a homegrown bash watchdog otherwise. |
| `RALPH_VERIFY_TRUST_AGENT_PASS` | Default `1`. When `1`, if the runner's own re-run of a verification command fails or times out but the agent reported `VERIFICATION_RESULT: PASS`, the runner accepts the agent's verdict and keeps the TODO complete (logged as an advisory mismatch). Set `0` to always treat a failed runner re-run as a failure. |
| `RALPH_PLAN_VERIFY_AFTER_TODO` | Legacy `1` enables post-TODO verification even without an explicit declared command (extraction may still find none). Declared commands no longer require this flag. |
| `RALPH_VERIFY_AFTER_TODO` | Explicit shell command string to run as post-verification. Overrides extraction from TODO text or plan frontmatter when set. **Warning:** This runs in the workspace after the TODO is marked complete; set to operator-provided or plan-frontmatter-provided commands only. |

Plan-level verification can be declared in the YAML frontmatter:
```yaml
---
verify: bash scripts/run-bats.sh
---
```

TODO-level verification can be declared with a `Post-Verify:` or `Verify:` line in the TODO text:
```markdown
- [ ] Implement feature X

Post-Verify: bash scripts/integration-test.sh
```

**Safety notes:** Post-verification commands run in the workspace root after the TODO is marked complete, but before the next model invocation. Verification output is counted toward `verification_bytes_suppressed` metrics. Failed verifications store full output under `.ralph-workspace/artifacts/<PLAN_KEY>/verification/` and return only a compact summary to the next prompt, allowing the model to retry or acknowledge the failure.

## Shared UI and logging (all runtimes)

These names are normalized from runtime-specific variables by `ralph_run_plan_load_env_for_runtime` (see [`run-plan-env.sh`](../bundle/.ralph/bash-lib/run-plan/run-plan-env.sh)).

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

Replace `<RUNTIME>` with `CURSOR`, `CLAUDE`, `CODEX`, `OPENCODE`, or `ANTIGRAVITY` as appropriate.

## Models

Ralph no longer ships bundled default model lists for Claude or Codex. Prebuilt agents may leave `model` empty in `config.json`; resolution then uses saved models or interactive prompts.

### Saved models (Claude and Codex)

| Item | Purpose |
|------|---------|
| `ralph models` / `.ralph/models.sh` | `list`, `add`, and `remove` subcommands for `claude` and `codex` runtimes. |
| `${RALPH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph}/models.json` | Ordered saved-model store (`schema_version`, per-runtime arrays). First entry is the default fallback. |
| `RALPH_CONFIG_HOME` | Override Ralph config root (defaults to `${XDG_CONFIG_HOME:-$HOME/.config}/ralph`). |

Examples:

```bash
ralph models add claude claude-sonnet-4-6
ralph models list codex
bash .ralph/models.sh remove claude claude-sonnet-4-6
```

### Environment variables

| Variable | Purpose |
|----------|---------|
| `CURSOR_PLAN_MODEL` | Model id for Cursor CLI (also fallback for other runtimes when their override unset). |
| `CLAUDE_PLAN_MODEL` | Model id for Claude Code CLI; falls back to `CURSOR_PLAN_MODEL`. |
| `CODEX_PLAN_MODEL` | Model id for Codex; falls back to `CURSOR_PLAN_MODEL`. |
| `OPENCODE_PLAN_MODEL` | Model id for OpenCode; falls back chain through Codex/Claude/Cursor. |
| `ANTIGRAVITY_PLAN_MODEL` | Model id for Antigravity (`agy`); falls back through `OPENCODE_PLAN_MODEL` then `CURSOR_PLAN_MODEL`. Must be an exact display string from `agy models` when passed to the CLI. |

### Antigravity model contract

Ralph lists available models via `agy models`, preserves each exact display string returned by that command, and invokes the CLI with `agy --model "<exact model string from agy models>"`. Model ids are never normalized or remapped. Interactive selection uses the same strings; when `agy` is unavailable the menu falls back to placeholders such as `auto`.

### Claude/Codex resolution order

When `run-plan` selects a model for Claude or Codex (highest wins):

1. `--model <id>` CLI flag
2. `CLAUDE_PLAN_MODEL` or `CODEX_PLAN_MODEL` (each falls back to `CURSOR_PLAN_MODEL` when unset)
3. Non-empty agent config `model`
4. First saved model from `models.json` (`ralph models add`)
5. Interactive prompt (saved-model menu or manual entry; offers to save new ids)

Orchestration stage `model` in the pipeline plan overrides agent config for that stage only.

### Antigravity resolution order

When `run-plan` selects a model for Antigravity (highest wins):

1. `--model <id>` CLI flag
2. `ANTIGRAVITY_PLAN_MODEL` (then `OPENCODE_PLAN_MODEL`, then `CURSOR_PLAN_MODEL` when unset)
3. Non-empty agent config `model`
4. Interactive `agy models` menu (TTY only)

Saved `ralph models` entries do not apply to Antigravity.

**Non-interactive:** Claude/Codex runs fail when none of steps 1-4 resolve a model. Add a saved default with `ralph models add <runtime> <id>`, or pass `--model` / set the runtime env var. Cursor/OpenCode/Antigravity non-interactive runs require `--model`, the runtime env var chain, or a non-empty agent-config model. For Antigravity, the model must be an exact display string from `agy models` so Ralph can pass it to `agy --model "<exact model string from agy models>"` unchanged.

## Cursor-specific

| Variable | Purpose / options |
|----------|-------------------|
| `CURSOR_PLAN_OUTPUT_FORMAT` | Cursor CLI output format used when `RALPH_PLAN_CAPTURE_USAGE=1` or CLI resume is active. Defaults to `stream-json` so Ralph can capture streamed tool-call events when Cursor emits them. Set to `json` to restore the older summary-only output mode. |

## Codex-specific

| Variable | Purpose / options |
|----------|-------------------|
| `CODEX_PLAN_CLI` | Codex executable name or path (also `CODEX_CLI` may set this in invoke helper). |
| `CODEX_PLAN_SANDBOX` | Codex sandbox mode passed to `codex exec --sandbox` (set via `--codex-sandbox` in [`bundle/.ralph/bash-lib/run-plan/run-plan-args.sh`](../bundle/.ralph/bash-lib/run-plan/run-plan-args.sh) or by exporting `CODEX_PLAN_SANDBOX`; consumed by the Codex run-plan invoke helper under [`bundle/.ralph/bash-lib/run-plan/`](../bundle/.ralph/bash-lib/run-plan/)). This is the single Codex sandbox control. Allowed values: `read-only`, `workspace-write` (default), `danger-full-access` (high risk; see `codex exec --help`). Resume sessions receive it via `-c sandbox_mode=...`. |
| `CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX` | `1` appends `--dangerously-bypass-approvals-and-sandbox` (also known as `--yolo`) to Codex exec calls, removing all sandbox and approval controls. Default `0`. Use only in isolated, trusted environments. **Caveat:** Resume paths may not honor this flag consistently; see [openai/codex#9144](https://github.com/openai/codex/issues/9144). |
| `CODEX_PLAN_NO_ADD_AGENTS_DIR` | `1` omits `--add-dir` on `.ralph-workspace` for non-resume runs. |
| `CODEX_PLAN_EXEC_EXTRA` | Extra words appended to the `codex` argv before the prompt (space-separated). |
| `CODEX_PLAN_MCP_TOOLS_APPROVAL_MODE` | Per-server MCP tool approval for the Ralph-owned Codex MCP entry (`mcp_servers.ralph.default_tools_approval_mode`). Default `approve` in `--ralph-mode ralph` runs. Allowed values: `approve`, `prompt`, `auto`. Set to `omit`, `unset`, or empty to skip injecting the field. Invalid values log a warning and fall back to `approve`. |
| `CODEX_PLAN_MCP_OMIT_TOOLS_APPROVAL_MODE` | `1` skips injecting `mcp_servers.ralph.default_tools_approval_mode` even when the CLI supports it (same effect as `CODEX_PLAN_MCP_TOOLS_APPROVAL_MODE=omit`). |
| `CODEX_PLAN_MCP_OMIT_TYPE` | `1` skips probing/injecting `mcp_servers.ralph.type` (force fallback for older Codex builds). |
| `CODEX_PLAN_MCP_OMIT_REQUIRED` | `1` skips probing/injecting `mcp_servers.ralph.required`. |
| `RALPH_PLAN_CAPTURE_USAGE` | When `1` (default), Codex wrapper passes `--json` so token usage can be recorded. |

## Claude-specific (invoke)

| Variable | Purpose |
|----------|---------|
| `CLAUDE_PLAN_CLI` | Claude Code CLI executable. |
| `CLAUDE_PLAN_NO_ALLOWED_TOOLS` | `1` omits `--allowedTools`. |
| `CLAUDE_PLAN_ALLOWED_TOOLS` | Overrides default tool list (comma-separated or as CLI expects). |
| `CLAUDE_TOOLS_FROM_AGENT` | Tools string from agent config when not overridden. |
| `RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS` | When `1` (default), passes `--exclude-dynamic-system-prompt-sections` only when Ralph does not pass `--system-prompt` (resume/reset turns with empty `PROMPT_STATIC`). Claude ignores this flag when `--system-prompt` is supplied; fresh/checkpoint caching uses `--system-prompt "$PROMPT_STATIC"` instead. |
| `RALPH_CLAUDE_MAX_BUDGET_USD` / `RALPH_AGENT_MAX_BUDGET` | Soft budget caps passed as `--max-budget-usd` when set. |
| `CLAUDE_PLAN_BARE` | `1`/truthy enables `claude --bare` (also via `--claude-bare`), `0` disables it (also via `--no-claude-bare`). Upstream says `--bare` "skips hooks, LSP, plugin sync, attribution, auto-memory, prefetches, keychain reads, and CLAUDE.md auto-discovery." This axis defaults to `0` and should be treated as an opt-in API-key mode. `CLAUDE_PLAN_MINIMAL` defaults to `1` and enables auth-safe flag composition (`--disable-slash-commands`, `--strict-mcp-config`, `--mcp-config '{"mcpServers":{}}'`, `--setting-sources project,local`, `--tools ...`). When reset mode is actively using a reset command, Ralph omits `--disable-slash-commands` so the reset command can run. `CLAUDE_PLAN_MINIMAL_TOOLS` defaults to `Bash,Read,Edit,Write` and overrides the tools list used in minimal mode. |
| `CLAUDE_PLAN_MINIMAL_DISABLE_MCP` | When `1` (default) and Claude minimal mode is active, Ralph passes `--strict-mcp-config` and an empty `--mcp-config`. Set to `0` or use `--claude-allow-mcp` so project-defined MCP servers still load while other minimal flags remain. `--no-claude-allow-mcp` sets `1` explicitly. |
| `CLAUDE_PLAN_PERMISSION_MODE` | Claude permission mode passed to `claude --permission-mode` (also via `--claude-permission-mode`). Allowed values: `default`, `acceptEdits`, `auto`, `bypassPermissions`, `dontAsk`, `plan`. Default: omit the flag and let Claude use its own default. Modes such as `auto`, `bypassPermissions`, and `dontAsk` can skip or auto-approve prompts, so use them only in trusted workspaces. |

## Antigravity-specific

| Variable | Purpose |
|----------|---------|
| `ANTIGRAVITY_PLAN_CLI` | Antigravity executable name or path (default: `agy` on `PATH`). |
| `ANTIGRAVITY_PLAN_MODEL` | Exact model string for `agy --model` (see [Antigravity model contract](#antigravity-model-contract)). |
| `ANTIGRAVITY_PLAN_SKIP_PERMISSIONS` | Pass `agy --dangerously-skip-permissions` for non-interactive runs (default `1`; set `0` to require approvals). |
| `RALPH_GEMINI_HOME` | Base of agy's data dir for conversation-id capture (default `~/.gemini`). |

`agy` reads project configuration from `.agents/` (agents, rules, skills), not `.antigravity/`. The headless prompt is delivered with `agy --print`, and Ralph widens `agy --print-timeout` to the per-invocation timeout.

`agy` emits no JSON stream, so resume does not parse stdout. After each TODO, Ralph reads the conversation id agy recorded in `${RALPH_GEMINI_HOME:-~/.gemini}/antigravity-cli/cache/last_conversations.json` and stores it at `.ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.antigravity.txt`. The next TODO resumes that conversation with `agy --conversation <id>`, keeping agy's session-tied prompt cache warm.

## Orchestrator

| Variable | Purpose |
|----------|---------|
| `ORCHESTRATOR_VERBOSE` | `1` mirrors orchestrator log lines to stderr. |
| `ORCHESTRATOR_DRY_RUN` | `1` prints steps without executing runners. |
| `ORCHESTRATOR_RUNNER_TO_CONSOLE` | When `0`, runner output goes only to the orchestrator log (no live `tee` to console). |
| `ORCHESTRATOR_HUMAN_ACK` | `1` enforces per-stage `humanAck` gates. |
| `ORCHESTRATOR_NO_COLOR` | Disable color in orchestrator messages (see orchestrator script). |

### Console output and logs

Per-plan output logs (`.ralph-workspace/logs/<ns>/plan-runner-<plan>-output.log`) are written in compact TUI form (ASCII glyphs, no color) when JSON streaming demux is active. Console output follows `RALPH_PLAN_PRETTY` separately.

| Variable | Purpose |
|----------|---------|
| `RALPH_PLAN_PRETTY` | Controls pretty console output for `run-plan.sh`. `auto` (default) enables pretty output only when stdout is a TTY and colors are enabled. `1` forces pretty output. `0` forces plain output. |
| `RALPH_PLAN_PRETTY_ASCII` | When set to `1`, uses ASCII-friendly pretty output instead of Unicode glyphs. |
| `RALPH_PLAN_PRETTY_NO_HIGHLIGHT` | When set to `1`, disables syntax highlighting inside diff blocks. Diffs still render with line-number gutters and added/removed line backgrounds. |
| `RALPH_PRETTY_RESULT_BODY_LINES` | Maximum number of lines shown in a tool-result body before the overflow pointer when the result is large (more than 6 non-empty lines). Default `2`. Increase to see a longer head preview; decrease to keep the TUI more compact. |
| `RALPH_PLAN_RAW_OUTPUT_LOG` | `0` (default). When `1`, the JSON demux helper also appends every raw NDJSON line from the CLI stream to `plan-output-raw.log` for debugging. |
| `RALPH_PLAN_RAW_OUTPUT_LOG_PATH` | Optional explicit file path for the raw JSONL stream when `RALPH_PLAN_RAW_OUTPUT_LOG=1`. When set, this exact path is used and is not surfaced in the agent prompt or compact output log. |
| `RALPH_PLAN_RAW_OUTPUT_DIR` | Optional directory override for raw JSONL capture when `RALPH_PLAN_RAW_OUTPUT_LOG=1`. Ralph writes `plan-output-raw.log` into this directory instead of beside the compact log. Ignored when `RALPH_PLAN_RAW_OUTPUT_LOG_PATH` is set. |
| `ORCHESTRATOR_RUNNER_TO_CONSOLE` | When `0`, orchestrator stage runner output is written only to log files instead of being mirrored live to the console. |

When an orchestration is launched without a TTY, follow a stage runner log directly:

```bash
tail -F .ralph-workspace/logs/<ns>/plan-runner-<plan>-output.log
```

## Ralph mode (plan runs)

Single selector for Ralph tooling (MCP injection, proxy catalog, prompt guidance) and native adapters (hook overlays). Default when unset and non-interactive: **`no`**. Interactive TTY runs still prompt when no flag, env var, or saved preference selects a mode.

| Variable | Purpose |
|----------|---------|
| `RALPH_MODE` | `no`, `native`, `ralph`, or `hybrid`. Same as `--ralph-mode`. |
| `RALPH_PROMPT_STABLE_PREFIX` | Cache-friendly prompt ordering. Default follows the rollout convention: enabled in `ralph`/`hybrid` unless set to `0`, disabled in `no`/`native` unless set to `1` (invalid values fail early). When enabled, every non-Claude runtime (Cursor, Codex, OpenCode, Antigravity) places the byte-identical stable block (agent context + namespace + guidance) before the per-TODO volatile text so the shared prefix is reused across TODOs. When disabled, OpenCode keeps its existing stable-first order and Cursor/Codex/Antigravity keep the legacy stable-last order. Claude always passes the stable block via `--system-prompt`. The stable-prefix byte count and a content-free fingerprint are recorded on invocation usage records (`stable_prefix_bytes`, `stable_prefix_fingerprint`). |
| `RALPH_REASONING_EFFORT` | Per-agent and per-stage reasoning effort mapping. Default follows the rollout convention: enabled in `ralph`/`hybrid` unless set to `0`, disabled in `no`/`native` unless set to `1` (invalid values fail early). Portable values: `low`, `medium`, `high`, `xhigh`, `max`, `inherit`. Precedence: `--reasoning-effort` / `PLAN_REASONING_EFFORT_CLI` > runtime env (`CLAUDE_PLAN_REASONING_EFFORT`, `CODEX_PLAN_REASONING_EFFORT`, `CURSOR_PLAN_REASONING_EFFORT`, `OPENCODE_PLAN_REASONING_EFFORT`, `ANTIGRAVITY_PLAN_REASONING_EFFORT`, including orchestration stage overrides) > agent `reasoning_effort` in frontmatter/config > `inherit`. Claude maps supported values to `--effort` after capability detection. Codex maps to `model_reasoning_effort` via `exec --config` when the installed CLI accepts that key; otherwise logs once and uses `inherit`. Cursor, OpenCode, and Antigravity log once and use `inherit` until an adapter exposes a supported control. Invocation usage records include `reasoning_effort_resolved` and `reasoning_effort_applied`. |
| `RALPH_CLAUDE_SPECULATIVE_CACHE_WARM` | Speculative Claude prompt-cache warming during the post-verification idle window. **Default off everywhere** (including `ralph`/`hybrid`); set to `1` to opt in. Ralph probes the installed Claude CLI for both `--cache-control` (explicit cache breakpoint) and `--max-output-tokens` (bounded output). Claude Code 2.1.x-style surfaces without `cache_control` report unsupported and perform no warm request. When enabled and supported, Ralph fires a bounded background warm using the stable `--system-prompt` prefix and records usage with `invocation_kind=speculative_cache_warm` separately from productive invocations. Invalid values fail early. |
| `RALPH_CONTINUATION_SUMMARY` | Between-TODO continuation summary. Default follows the rollout convention: enabled in `ralph`/`hybrid` unless set to `0`, disabled in `no`/`native` unless set to `1` (invalid values fail early). When enabled, Ralph stores runner-verifiable state at `.ralph-workspace/sessions/<plan-key>/continuation-summary.json` and injects a deterministic Markdown block after the stable prompt prefix and before the current TODO (never before the first TODO). Disabled mode preserves current prompts and creates no summary state. Invocation usage records include `continuation_summary_bytes`, `continuation_summary_entry_count`, and `continuation_summary_truncation_count` (content-free metrics). |
| `RALPH_CONTINUATION_SUMMARY_MAX_COMPLETED_TODOS` | Max completed TODO entries retained in continuation state (default `20`). Invalid or non-positive values fall back to the default. |
| `RALPH_CONTINUATION_SUMMARY_MAX_TODO_EXCERPT_BYTES` | Max bytes per stored TODO content excerpt (default `2048`). |
| `RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_PER` | Max bytes per stored verification error (default `2048`). |
| `RALPH_CONTINUATION_SUMMARY_MAX_ERROR_BYTES_TOTAL` | Max total bytes across stored verification errors (default `8192`). |
| `RALPH_CONTINUATION_SUMMARY_MAX_HUMAN_DECISIONS` | Max human decision records retained (default `10`). |
| `RALPH_CONTINUATION_SUMMARY_MAX_COMPLETION_SUMMARY_BYTES` | Max bytes for the agent structured completion summary line (default `512`). |
| `RALPH_CONTINUATION_SUMMARY_HIERARCHICAL` | Guided/hierarchical continuation summary for long plans. Default follows the rollout convention: enabled in `ralph`/`hybrid` unless set to `0`, disabled in `no`/`native` unless set to `1` (invalid values fail early). When enabled, older completed TODOs are consolidated into deterministic grouped summaries at render time; recent detail, unresolved failures, errors, and human decisions are preserved. Consolidation is rebuilt from source state only (no LLM). |
| `RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT` | Number of most recent completed TODOs rendered with full detail when hierarchical mode is enabled (default `5`). |
| `RALPH_CONTINUATION_SUMMARY_GROUP_WINDOW` | Fixed TODO window size for deterministic consolidation when `RALPH_CONTINUATION_SUMMARY_GROUP_BY=window` (default `5`). |
| `RALPH_CONTINUATION_SUMMARY_GROUP_BY` | Consolidation grouping mode: `window` (ordinal/line windows) or `stage` (orchestration `RALPH_STAGE_ID`). Default `window`. |
| `RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES` | Max bytes for the rendered continuation Markdown block when hierarchical mode is enabled (default `16384`). Omitted sections are listed explicitly in the block. |
| `RALPH_PROGRESSIVE_CONTEXT` | Progressive rule/skill disclosure for prebuilt agent context. Default follows the rollout convention: enabled in `ralph`/`hybrid` unless set to `0`, disabled in `no`/`native` unless set to `1` (invalid values fail early). When enabled, rules with `alwaysApply: true` always load in full in the stable prompt; optional rules and skills expose Tier 1 metadata (name, description, globs, path) in the stable prompt and load full bodies only when BM25-ranked as relevant or explicitly mentioned in the TODO (volatile prompt). Malformed or missing metadata falls back to legacy full loading with a warning. Native Claude `--agent` passthrough skips Ralph context assembly entirely. Set to `0` to restore legacy full loading. |
| `RALPH_PROGRESSIVE_CONTEXT_THRESHOLD` | Minimum BM25 score for selecting an optional rule or skill body into the volatile prompt (default `1.5`). Invalid values fall back to the default. |
| `RALPH_PROGRESSIVE_CONTEXT_MAX_ITEMS` | Maximum optional rule/skill bodies selected per TODO after explicit TODO mentions (default `8`). Invalid or non-positive values fall back to the default. |
| `RALPH_PLAN_MEMORY` | Per-plan MCP memory store (`ralph_proxy_memory_*`). Default follows the rollout convention: enabled in `ralph`/`hybrid` unless set to `0`, disabled in `no`/`native` unless set to `1` (invalid values fail early). Memory lives under `.ralph-workspace/memory/<plan-key>/`, is isolated to the active plan key and state root, and treats stored content as untrusted model-authored data. Disabled mode advertises no memory tools and writes no memory directory. |
| `RALPH_PLAN_MEMORY_MAX_ENTRIES` | Max memory entries per plan (default `100`). Invalid or non-positive values fall back to the default. |
| `RALPH_PLAN_MEMORY_MAX_BYTES_PER_ENTRY` | Max bytes per memory entry (default `65536`). |
| `RALPH_PLAN_MEMORY_MAX_TOTAL_BYTES` | Max total stored bytes per plan (default `1048576`). |
| `RALPH_PLAN_MEMORY_MAX_KEY_LENGTH` | Max memory key length in characters (default `128`). |
| `RALPH_CLAUDE_RALPH_STRICT_PROXY` | Defaults to `1` in `ralph` or `hybrid` once MCP preflight succeeds, stripping native `Bash` from Claude's schema so commands run through the bounded `ralph_proxy_shell` (set to `0` temporarily if you still need native `Bash`). Native `Read`/`Edit`/`Write` are kept: Claude Code requires a native `Read` before it will `Edit`/`Write` a file, so stripping `Read` would deadlock edits. |
| `RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ` | Opt-in (`1`/`true`/`yes`/`on`, default off). When strict proxy is active, also strips native `Read` from Claude's schema. Use only for read-only/analysis plans that never modify existing files. |
| `RALPH_MCP_CLI_PREFLIGHT` | When set (`1`/`true`/`yes`/`on`) and runtime is `claude`, runs an extra end-to-end gate after the deterministic preflight. Off by default. |
| `RALPH_CODEX_ALLOW_STRICT_PROXY_BESTEFFORT` | When set and runtime is `codex` with strict proxy (`RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=1` or `RALPH_STRICT_PROXY=1`), skips the mandatory live Codex MCP preflight and logs a warning instead of aborting. |
| `RALPH_CODEX_SKIP_LIVE_MCP_PREFLIGHT` | When set and runtime is `codex`, skips the live `ralph_proxy_read` Codex CLI probe entirely. |
| `RALPH_CODEX_PREFLIGHT_READ_PATH` | Workspace-relative file path for the Codex live MCP probe (default `AGENTS.md`). |

Workspace preference key: `ralph_mode_default` in `.ralph-workspace/preferences.json` (`"no"`, `"native"`, `"ralph"`, or `"hybrid"`).

### Runtime overlay controls

Operator guide (per-runtime setup, troubleshooting): [TOOLING.md](TOOLING.md#native-adapters-per-runtime).

Native adapters activate automatically only after you explicitly select `native` or `hybrid`. When Ralph mode is **`ralph`** or **`hybrid`**, Ralph auto-enables `RALPH_PROXY_SHELL_COMPACT=1` unless you already set the variable (opt out with `RALPH_PROXY_SHELL_COMPACT=0`). When Ralph mode is **`native`** or **`hybrid`**, Ralph auto-enables `RALPH_BASH_COMPACT=1` unless you already set the variable (opt out with `RALPH_BASH_COMPACT=0`; Claude PostToolUse:Bash path only). See [TOOLING.md](TOOLING.md#enabling-and-disabling).

### Native runtime configuration preservation

Ralph preserves each runtime's native user, project, and local/private configuration chain. Configurations are discovered from the Ralph project root, not the state root or agent workspace. All mutations use reversible workspace overlays or temporary config files. Byte-exact originals are restored on success, failure, timeout, and signal cleanup.

| Runtime | Native config sources (precedence order) | Ralph additions |
|---------|------------------------------------------|-----------------|
| **Claude** | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, user/global rules, skills, hooks, plugins, permissions, memory | Agent `mcp_servers` merged over ambient, then Ralph's protected `ralph` server in `ralph`/`hybrid` mode |
| **Cursor** | `.cursor/` rules, skills, hooks, settings; existing `.cursor/mcp.json` | Agent `mcp_servers` merged with agent precedence, then Ralph's protected `ralph` server |
| **Codex** | `~/.codex/config.toml`, trusted project `.codex/config.toml` (if project trusted) | Agent `mcp_servers` translated to `--config mcp_servers.<name>.*` overrides after native load |
| **OpenCode** | Global, custom, project `opencode.json` (JSONC preserved) | Agent `mcp_servers` merged into temporary `OPENCODE_CONFIG` with native settings preserved |
| **Antigravity** | `.agents/agents.md`, rules, skills, workflows; existing `.agents/mcp_config.json` | Agent `mcp_servers` merged into temporary `ANTIGRAVITY_CONFIG` only when needed |

**Precedence** (highest to lowest): Native ambient > Agent definitions > Ralph's protected `ralph` server. Agent definitions with the same name as ambient servers override the ambient definition.

**Reserved name**: The server name `ralph` is reserved; agents cannot reference, redefine, or replace it.

**Secret policy**: Credential values in portable definitions must use `${ENV_VAR}` references. Literal secrets are rejected at validation.

**Failure behavior**: Unresolved references, invalid definitions, missing environment variables, or attempts to use the reserved `ralph` name cause validation failures before model invocation. Error messages include the runtime, agent, missing server/env name, and searched source paths.

See [AGENTS.md](../AGENTS.md) and [TOOLING.md](../docs/TOOLING.md) for full details.

### Runtime overlay cleanup

Every runtime overlay mutation is journaled under `.ralph-workspace/runtime-config/<plan-key>/journals`. Each journal entry records the runtime, PID, start time, generated temp files, and the workspace files mutated in place (with backup locations) so the runner can restore them later.

`run-plan.sh` now invokes `runtime_overlay_restore_stale_runs` at startup to replay any journal whose owner PID is dead or whose start time is older than the safe threshold. Customize the threshold with `RALPH_RUNTIME_OVERLAY_STALE_THRESHOLD_SECONDS` (default `3600`) or the alias `RALPH_RUNTIME_OVERLAY_STALE_THRESHOLD` (e.g., `30m`, `1h`). The same restore happens when you run `.ralph/cleanup-plan.sh --runtime-config <namespace>` or `--runtime-config --all`.

Because `SIGKILL` (or Activity Monitor force-kill) cannot invoke trap handlers, the stale overlay journal is the only reliable way to recover a killed run. The next plan invocation or a `cleanup-plan.sh --runtime-config` run replays the journal, restoring mutated configs (`.cursor/mcp.json`, nested `.claude` settings overlays, and the temporary Codex/OpenCode configs) before the next CLI actually runs.

## MCP server

| Variable | Purpose |
|----------|---------|
| `RALPH_MCP_AUTH_TOKEN` | When set, JSON-RPC calls must include matching `authToken`. |
| `RALPH_MCP_ALLOWLIST` | Comma-separated allowed workspace/orchestration path prefixes beyond the built-in project, agent, state, and `/tmp` roots. |
| `RALPH_MCP_WORKSPACE` | Workspace root for the MCP server (example in AGENTS.md). |
| `RALPH_MCP_POLICY_VIOLATION_MODE` | Controls violation handling: `fatal` (default) writes a kill-switch sentinel and exits, `error` returns a recoverable JSON-RPC error without touching sentinels, and `approve` pauses for operator input before retrying the denied proxy call. The approval mode only takes effect when the unified `.ralph/mcp-server.sh` runs under the plan-runner tool-access path (`RALPH_AGENT_TOOL_ACCESS=ralph`) with a watcher that can read/write `$RALPH_PLAN_WORKSPACE_ROOT/security/approvals/<plan-key-safe>`; direct or headless server use (including `.ralph/mcp-proxy-server.sh`) still falls back to `fatal` unless `error` is explicitly configured. |
| `RALPH_MCP_ENFORCE_KILL_SWITCH_NATIVE` | Defaults off. Set truthy to make RALPH_MODE=no or native plan runs abort on Ralph MCP kill-switch sentinels. |
| `RALPH_MCP_PROXY_POLICY` | Selects a named profile from a supplied policy file/inline JSON. Its `proxyOwnedTools` block drives caps, timeouts, and the `allowAllCommands` / `allowShellOperators` guards. |
| `RALPH_MCP_PROXY_POLICY_FILE` | Path to a JSON policy file used to override the built-in default (forwarded to the spawned MCP server so it actually takes effect in ralph mode). Use this to tighten or customize tool/shell permissions. |
| `RALPH_MCP_PROXY_POLICY_INLINE` | Inline JSON policy (same purpose as `RALPH_MCP_PROXY_POLICY_FILE`, no file needed). |
| `RALPH_PROXY_SHELL_ASYNC` | Defaults `1`. When Ralph MCP proxy tools are active, advertises `ralph_proxy_shell_start/wait/status/read/cancel` as a manual fallback surface for when a human is directly monitoring a long-running job—they are not the primary automation path. Runner-first verification remains the default path for commands proving TODO completion. Prefer `ralph_proxy_shell_wait` as the blocking call when manual monitoring is needed, treat `ralph_proxy_shell_status` as an occasional manual status check (never a polling loop), and inspect/cancel output through `ralph_proxy_shell_read` and `ralph_proxy_shell_cancel`. Set `0` to hide the async shell tools. |
| `RALPH_PROXY_DEDUPE_READS` | on (default `1`). When proxy owned tools are active, suppress duplicate `ralph_proxy_read` responses for identical path/offset/limit when file size and mtime are unchanged within a single MCP server process. Returns a compact message with the prior `resultId` instead of replaying the file body. Set `0` to disable. |
| `RALPH_PROXY_DEDUPE_SEARCH` | on (default `1`). When proxy owned tools are active, suppress duplicate `ralph_proxy_grep` and `ralph_proxy_glob` responses for identical canonicalized arguments while the in-process mutation counter is unchanged. A duplicate returns a compact envelope with the prior `resultId` instead of replaying the body; if the first response was small and had no `resultId`, the proxy stores it and returns a new `resultId`. Set `0` to disable. |
| `RALPH_MCP_PROXY_BATCH_MAX_OPERATIONS` | Max operations per `ralph_proxy_batch` call (default `8`). |
| `RALPH_MCP_PROXY_BATCH_PREVIEW_CHARS` | Max preview characters per operation in `ralph_proxy_batch` results (default `200`). |
| `RALPH_APPROVAL_TIMEOUT` | How long the unified MCP server waits for operator-approved tool calls before timing out. Defaults to `120` seconds and is raised to `RALPH_APPROVAL_TIMEOUT_CLAUDE` or `RALPH_APPROVAL_TIMEOUT_CODEX` (default `300`) for Claude and Codex so their CLI timeouts survive the approval wait; Cursor keeps the shorter window and relies on progress notifications. |
| `RALPH_APPROVAL_TIMEOUT_CLAUDE` | Optional override for `RALPH_APPROVAL_TIMEOUT` when running Claude (defaults to `300`). |
| `RALPH_APPROVAL_TIMEOUT_CODEX` | Optional override for `RALPH_APPROVAL_TIMEOUT` when running Codex (defaults to `300`). |
| `RALPH_APPROVAL_TIMEOUT_CURSOR` | Optional override for `RALPH_APPROVAL_TIMEOUT` when running Cursor (defaults to `120`). |
| `RALPH_APPROVAL_PROGRESS_INTERVAL` | Progress notification interval (seconds) while the server waits for decisions (`ralph_mcp_approvals.sh` default `10`). |
| `RALPH_APPROVAL_POLL_INTERVAL` | Poll interval (seconds) for scanning the approval directory (`ralph_mcp_approvals.sh` default `1`). |

## Operator approvals

Operator approvals are a v1 feature limited to the unified `.ralph/mcp-server.sh` plus the plan-runner watcher; they do not apply to the standalone `.ralph/mcp-proxy-server.sh` or ad hoc MCP instances that lack an approval listener. When `RALPH_AGENT_TOOL_ACCESS=ralph` and `RALPH_MCP_POLICY_VIOLATION_MODE=approve`, violations of the owned proxy reads (`ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_search`, and when `repoMapEnabled` is true `ralph_proxy_repomap`) create `request.<id>.json` inside `$RALPH_PLAN_WORKSPACE_ROOT/security/approvals/<plan-key-safe>/`. The unified server waits for a matching `decision.<id>.json` (with `{"id":"<request id>","decision":"approve","reason":"..."}` or `"decision":"deny"`) before retrying only that denied call; all other policy guards remain unchanged. Decision files must be owned by the same UID as the plan runner, and every final outcome appends a JSONL audit entry to `approvals.log` in the approvals directory so operators and automation can track approvals and timeouts.

The watcher located in `bundle/.ralph/bash-lib/run-plan/run-plan-approvals.sh` polls the approvals directory, emits progress notifications, and keeps artifacts fresh. Interactive runs print a notice to `/dev/tty`; headless runs write `APPROVAL-REQUIRED.md` and `approvals.md` into `.ralph-workspace/artifacts/{{ARTIFACT_NS}}/`. Those artifacts summarize the pending request IDs, the paths to `decision.<id>.json`, and the tool summaries, making it easy to respond by writing `{"id":"<request id>","decision":"approve","reason":"..."}` or a deny with an optional reason. Approved calls retry once, a repeat denial surfaces as a recoverable tool error rather than looping, and the watcher keeps updating the artifacts until all decisions exist so the plan run can continue.

Because the approval flow depends on the watcher being able to read and write requests, any other context (manual `.ralph/mcp-server.sh` launches, native/hybrid MCP without the watcher, and `.ralph/mcp-proxy-server.sh`) keeps using the existing `fatal` / `error` behavior and never waits for operator input.

The **built-in default policy is permissive**: `proxyOwnedTools.allowAllCommands` and `allowShellOperators` are `true` with a generous `shellTimeoutSeconds`, so `ralph_proxy_shell` runs arbitrary commands and operators in a trusted local loop. The proxy still bounds output (policy caps + stored-result envelopes) and the kill-switch still fires on real tripwires. To tighten, supply a stricter policy via `RALPH_MCP_PROXY_POLICY_FILE` / `RALPH_MCP_PROXY_POLICY_INLINE` (set `proxyOwnedTools.allowAllCommands` to `false` with a `shellAllowlist`); `bundle/.ralph/mcp-proxy-policy.example.json` includes `readonly`, `minimal`, and `trusted-local` profiles as starting points.

For long commands that cannot be declared as verification, use `ralph_proxy_shell_start` instead of a single blocking `ralph_proxy_shell` call. These async shell tools are a manual fallback surface for when a human is directly monitoring a job—they are not the primary automation path. The runner-first policy still prefers metadata-driven verification, so only fall back to these async helpers when the job truly needs manual intervention. `ralph_proxy_shell_start` returns a `jobId` immediately; use `ralph_proxy_shell_wait` (optionally with `waitSeconds`) as the blocking call to wait for completion. Treat `ralph_proxy_shell_status` as an occasional manual spot check—never use it as a polling loop—inspect output with `ralph_proxy_shell_read`, and cancel with `ralph_proxy_shell_cancel` if needed. The same shell policy and `proxyOwnedTools.shellTimeoutSeconds` limit apply.

When proxy owned tools are active, `ralph_proxy_batch` runs multiple read-only operations (`ralph_proxy_read`, `ralph_proxy_grep`, `ralph_proxy_glob`, `ralph_proxy_search`, and `ralph_proxy_result_*`) in one MCP call. Shell, async shell, edit, write, and repomap are not allowed inside a batch; keep shell invocations separate for policy and side-effect safety. Duplicate `ralph_proxy_grep` and `ralph_proxy_glob` calls can also be suppressed by `RALPH_PROXY_DEDUPE_SEARCH=1` until the next mutating shell or async shell call. Ralph mode prompt guidance advertises batching for independent read/search/glob/result work.

### Tool result storage retention

When Ralph MCP proxy tools store truncated results under `.ralph-workspace/tool-results/<plan-key>/`, retention runs after each write. Non-negative integer overrides; invalid values fall back to defaults. Stored results are generated artifacts under `.ralph-workspace/` and must not be committed. See [TOOLING.md](TOOLING.md#stored-tool-results) for storage layout, privacy/security notes, and `cleanup-plan.sh` behavior.

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_MCP_PROXY_RESULT_STORE_MAX_BYTES` | `52428800` (50 MiB) | Maximum total stored result bytes kept per plan key. |
| `RALPH_MCP_PROXY_RESULT_STORE_MAX_AGE_DAYS` | `7` | Maximum age in days for stored results. Set `0` to disable age-based pruning. |
| `RALPH_MCP_PROXY_RESULT_STORE_MAX_ENTRIES` | `100` | Maximum number of stored results kept per plan key (secondary cap). |

### Shell output compaction runtime matrix (PLAN49 outcome)

Ralph implements shell-output compaction once in shared libraries, then exposes it through MCP (all runtimes) and native adapters (where version-pinned hooks can provide output reduction before or instead of post-tool replacement). In `hybrid`, both layers are active, but MCP compaction remains authoritative whenever a runtime's native hook path is unproven. Shared implementation: [`bundle/.ralph/bash-lib/compactors.sh`](../bundle/.ralph/bash-lib/compactors.sh) and [`shell-output-compact.py`](../bundle/.ralph/python/shell-output-compact.py). Full MCP workflow (families, envelope, capture, retrieval): [TOOLING.md](TOOLING.md#shell-output-compaction).

| Layer | Applies to | Mechanism | Gate |
|-------|------------|-----------|------|
| **Universal (MCP)** | Claude, Cursor, Codex, OpenCode | `ralph_proxy_shell` calls the shared compactor; full stdout/stderr stored under `.ralph-workspace/tool-results/<plan-key>/`; agents page with `ralph_proxy_result_read`, `ralph_proxy_result_search`, `ralph_proxy_result_summary` | `RALPH_MODE=ralph` or `hybrid` (auto `RALPH_PROXY_SHELL_COMPACT=1` when unset); explicit `RALPH_PROXY_SHELL_COMPACT=0` opts out |
| **True post-tool mutation (native)** | Claude only | `PostToolUse:Bash` hook [`bundle/.claude/hooks/compact-bash-output.sh`](../bundle/.claude/hooks/compact-bash-output.sh) returns `hookSpecificOutput.updatedToolOutput` (proven on 2.1.162); full originals stored in `.ralph-workspace/tool-results/<plan-key>/`; fails open. | `RALPH_MODE=native` or `hybrid` (auto `RALPH_BASH_COMPACT=1` when unset); explicit `RALPH_BASH_COMPACT=0` opts out; non-zero exits do not trigger output replacement |
| **Pre-tool wrapper (native)** | Cursor, Codex | Shell `preToolUse` input rewrite to invoke `native-shell-wrapper` (proven Cursor 2026.06.03-0bbb28e; Codex 0.136.0 via T5). Wrapper captures, compacts, stores originals in `.ralph-workspace/tool-results/<plan-key>/`. Fails open; falls back to raw command or simple rewrite when wrapper unavailable. Hybrid enables this layer alongside MCP compaction, but the stored original remains shared with the proxy path. | `RALPH_NATIVE_SHELL_WRAPPER=1` (default on when native adapters (via `--ralph-mode native` or `hybrid`) and not explicitly disabled); `RALPH_BASH_REWRITE=1` for fallback simple rewrite |
| **MCP hook supplement (Cursor)** | Cursor | Ralph MCP `postToolUse` output compaction via `updated_mcp_tool_output` (proven on tested build) for Ralph MCP tool results when `RALPH_PROXY_SHELL_COMPACT=1` (or `RALPH_CURSOR_MCP_HOOK_COMPACT=1`). Shell native `postToolUse` output replacement is not proven, so `hybrid` still treats the proxy path as authoritative. | `RALPH_MODE=hybrid` or `ralph` with `RALPH_PROXY_SHELL_COMPACT=1` |
| **MCP fallback (recommended)** | OpenCode | Plugin staging and code verified (T6/T7), but headless hook invocation and output mutation unproven (OpenCode 1.14.35). In `hybrid`, native OpenCode tools and Ralph MCP tools are both available; MCP-proxy native-result compaction (`result_windowing`) is authoritative unless revalidation records `headless_mutation_reaches_model: yes`. | `--ralph-mode hybrid` or `ralph` with `RALPH_PROXY_SHELL_COMPACT=1` and `RALPH_NATIVE_RESULT_COMPACT=1` |

**Command rewriting** (Phase 5) is documented separately in [Shell command rewrite runtime matrix](#shell-command-rewrite-runtime-matrix-phase-5-outcome) below. Universal rewrite runs through `ralph_proxy_shell`; Claude ships native `PreToolUse:Bash` adapter; Cursor and Codex use wrapper invocation when applicable.

#### Universal via MCP (all runtimes)

When Ralph mode is **`ralph`** or **`hybrid`**, every runtime receives MCP compaction through the unified MCP server:

- **`ralph_proxy_shell`** with compaction enabled (`RALPH_PROXY_SHELL_COMPACT=1`). Ralph auto-sets this in **`ralph`** or **`hybrid`** mode unless you already exported the variable (including `0` to opt out).
- **Stored-result follow-up** via `ralph_proxy_result_*` (same store and retention as other proxy truncations; see [tool result storage](#tool-result-storage-retention) above).
- **Policy and caps** from `RALPH_MCP_PROXY_POLICY*` and `toolResultByteCaps.ralph_proxy_shell` apply uniformly; native Edit/Write tools are unchanged.

This path does not depend on runtime hooks or plugins. It is the supported compaction surface for Cursor, Codex, and OpenCode plan runs, and for Claude runs that use `ralph_proxy_shell` instead of native `Bash`.

#### Native adapters

**Claude** ships a true PostToolUse:Bash adapter and optional PreToolUse:Bash rewrite adapter. **Cursor and Codex** use pre-tool wrapper invocation (T1, T3, T5). All adapters reuse the same compactor code as MCP; they do not duplicate compaction logic. **OpenCode** plugin is staged to documented local path but unproven headless (T6/T7).

| Runtime | Adapter | Status | Mechanism |
|---------|---------|--------|-----------|
| Claude | `.claude/hooks/compact-bash-output.sh` | **Shipped** (2.1.162) | PostToolUse:Bash output mutation via `updatedToolOutput` (proven); gated by `RALPH_BASH_COMPACT=1` |
| Claude | `.claude/hooks/rewrite-bash-command.sh` | **Shipped** (2.1.162) | PreToolUse:Bash input rewrite via `updatedInput` (proven); gated by `RALPH_BASH_REWRITE=1` |
| Cursor | `.cursor/hooks/pre-tool-shell-policy.sh` | **Proven** (2026.06.03-0bbb28e) | PreToolUse Shell wrapper-based compaction plus fallback input rewrite; gated by `RALPH_NATIVE_SHELL_WRAPPER=1` (default on with hooks) |
| Cursor | `.cursor/hooks/post-tool-mcp-compact.sh` | **Proven** (2026.06.03-0bbb28e) | PostToolUse Ralph MCP output compaction via `updated_mcp_tool_output`; does not apply to native Shell |
| Codex | `.codex/hooks/pre-tool-bash-policy.sh` | **Proven** (0.136.0) | PreToolUse Bash wrapper-based compaction plus fallback input rewrite; gated by `RALPH_NATIVE_SHELL_WRAPPER=1` (default on with hooks) |
| Codex | `.codex/hooks/post-tool-bash-telemetry.sh` | **Lifecycle present; mutation unproven** (0.136.0) | PostToolUse:Bash lifecycle hooks fire (T4 proven) but model-visible output mutation not proven on headless invocation; telemetry-only |
| OpenCode | `.opencode/plugins/ralph-runtime-hooks.ts` | **Staged; invocation unproven** (1.14.35) | Plugin staged to workspace `.opencode/plugins/` (documented path proven T6); code implements `tool.execute.before`/`after` (T7 verified); headless hook invocation and output mutation unproven |

#### Native shell output replacement contract summary

| Runtime | PreToolUse input rewrite | PostToolUse/Post-tool output replacement | Authoritative path | Notes |
|---------|--------------------------|-------------------------------------------|-------------------|-------|
| **Claude** (2.1.162) | PROVEN (optional, `RALPH_BASH_REWRITE=1`) | PROVEN (`PostToolUse:Bash`, `RALPH_BASH_COMPACT=1`) | True post-tool mutation | Strongest native path; full originals stored `.ralph-workspace/tool-results/` |
| **Cursor** (2026.06.03-0bbb28e) | PROVEN wrapper + fallback rewrite (`RALPH_NATIVE_SHELL_WRAPPER=1`) | NOT PROVEN for Shell `postToolUse` | Wrapper-based pre-tool rewrite | Also: Ralph MCP `postToolUse` proven for Ralph proxy tools only |
| **Codex** (0.136.0) | PROVEN wrapper + fallback rewrite (`RALPH_NATIVE_SHELL_WRAPPER=1`) | UNPROVEN (lifecycle present, real smoke pending) | Wrapper-based pre-tool rewrite | PostToolUse lifecycle fires but agent-visible mutation not proven |
| **OpenCode** (1.14.35) | UNPROVEN headless invocation | UNPROVEN headless invocation | MCP-proxy native-result compaction (default) | Plugin code implements both hooks; staging proven; headless firing unproven. `hybrid` keeps native and Ralph tools; see [TOOLING.md#opencode-hybrid-contract](TOOLING.md#opencode-hybrid-contract) |

### Proxy shell output compaction (`RALPH_PROXY_SHELL_COMPACT`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_PROXY_SHELL_COMPACT` | off in `no`/`native`; auto `1` in `ralph`/`hybrid` when unset | When `1`, `true`, `yes`, or `on`, `ralph_proxy_shell` summarizes noisy allowlisted command output (for example `git status`, `bats`, `grep`, `find`) and stores full originals for retrieval. When off, returns raw stdout/stderr (inline error text on non-zero exit). Requires Ralph MCP active (`ralph` or `hybrid`). Ralph sets `RALPH_PROXY_SHELL_COMPACT=1` in `ralph` and `hybrid` modes unless you already exported the variable; opt out with `RALPH_PROXY_SHELL_COMPACT=0`. Full architecture, supported families, DSL rules, safety contract, telemetry, and retrieval workflow: [TOOLING.md#shell-output-compaction](TOOLING.md#shell-output-compaction). Capture path, retention, cleanup: [TOOLING.md#stored-tool-results](TOOLING.md#stored-tool-results). |

### Contextual BM25 search (`RALPH_MCP_CONTEXTUAL_SEARCH`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_MCP_CONTEXTUAL_SEARCH` | off in `no`/`native`; auto `1` in `ralph`/`hybrid` when unset | When enabled, `ralph_proxy_search` ranks candidates with separate boosts for project-relative path, nearest enclosing symbol, and nearest Markdown/AsciiDoc heading (path-only fallback when Python or symbol extraction is unavailable). Returned hits keep the original `path:line` and source line text. Opt out with `RALPH_MCP_CONTEXTUAL_SEARCH=0`. Context indexes cache under `$RALPH_PLAN_WORKSPACE_ROOT/search-context/`. |

### Native exploration result compaction (`RALPH_NATIVE_RESULT_COMPACT`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_NATIVE_RESULT_COMPACT` | off in `no`/`ralph`; auto `1` in `native`/`hybrid` when unset | When `1`, `true`, `yes`, or `on`, compact native exploration tool output (`read`, `grep`, `glob`, `bash`, and compatible aliases) through the shared `native-result-compact` path. Output is windowed into the same stored-result envelope used by MCP proxy tools; full originals live under `.ralph-workspace/tool-results/<plan-key>/` and agents page with `ralph_proxy_result_*`. Savings are recorded as `result_windowing` telemetry. Ralph sets `RALPH_NATIVE_RESULT_COMPACT=1` in `native` and `hybrid` modes unless you already exported the variable; opt out with `RALPH_NATIVE_RESULT_COMPACT=0`. On OpenCode, this is the authoritative compaction path unless revalidation records `headless_mutation_reaches_model: yes` (see [TOOLING.md#opencode-hybrid-contract](TOOLING.md#opencode-hybrid-contract)). |

### Runtime-native bash output compaction (`RALPH_BASH_COMPACT`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_BASH_COMPACT` | off in `no`/`ralph`; auto `1` in `native`/`hybrid` when unset | When `1`, `true`, `yes`, or `on`, compact native shell tool output via Claude PostToolUse:Bash hook that calls the shared compactors in `bundle/.ralph/bash-lib/compactors.sh`. Ralph sets `RALPH_BASH_COMPACT=1` in `native` and `hybrid` modes unless you already exported the variable; opt out with `RALPH_BASH_COMPACT=0`. Failed hooks must fail open and never block the agent. Only Claude ships a true PostToolUse:Bash adapter. Cursor and Codex use wrapper-based compaction instead (see `RALPH_NATIVE_SHELL_WRAPPER` below). |
| `RALPH_BASH_COMPACT_LOG` | unset | Optional JSONL audit path for each PostToolUse:Bash compaction attempt (Claude only): `commandHash`, `originalBytes`, `compactedBytes`, `storagePath` (when stored), `compactionSkipped`, `planKey`, `workspace`. No log lines when compaction is off or the event is not PostToolUse:Bash with a `tool_response`. |

### Generic compaction fallback (`RALPH_COMPACT_GENERIC_THRESHOLD_BYTES`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_COMPACT_GENERIC_THRESHOLD_BYTES` | `8192` | Byte threshold for the `generic_large` size-triggered fallback in [`shell-output-compact.py`](../bundle/.ralph/python/shell-output-compact.py). When no command family or output-shape rule matches, combined stdout/stderr above this size is compacted to head + tail plus error/failure lines extracted from the elided middle (progress walls, compiler warnings, test floods, stack traces). Output at or below the threshold passes through unchanged. Non-integer or negative values fall back to `8192`. Applies to MCP proxy shell compaction and native adapter compactors that call the shared library. |

### Wrapper-based native shell compaction (`RALPH_NATIVE_SHELL_WRAPPER`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_NATIVE_SHELL_WRAPPER` | on (when explicit `--ralph-mode native` or `--ralph-mode hybrid` is active) | When `1`, `true`, `yes`, or `on`, eligible shell commands are rewritten to invoke the shared native-shell-wrapper (`bundle/.ralph/bash-lib/native-shell-wrapper.sh`). The wrapper captures stdout/stderr, applies shared compaction logic, stores full originals in `.ralph-workspace/tool-results/<plan-key>/`, and displays a compact preview with storage path. Default off unless `RALPH_MODE=native` or `RALPH_MODE=hybrid` activates hooks for Cursor or Codex. Wrapper path is pre-tool rewrite (updates `updated_input.command` in PreToolUse); it does not replace post-tool output. Failed wrapper invocation fails open and returns the raw command for normal execution. |
| `RALPH_NATIVE_SHELL_WRAPPER_LOG` | unset | Optional JSONL audit path for each wrapper invocation: `command`, `compacted`, `originalBytes`, `compactedBytes`, `storagePath`, `planKey`, `workspace`, `runtime`. Appended when wrapper runs and compaction applies or command exits non-zero. |

**Wrapper-based compaction applies to:** Cursor (PreToolUse input rewrite, proven on 2026.06.03-0bbb28e) and Codex (PreToolUse input rewrite, verified in T5). Stored originals are retrievable through the same `ralph_proxy_result_*` tools used for MCP compaction and Claude PostToolUse compaction.

**Eligibility:** Only simple, allowlisted commands that the shared Ralph rewrite registry recognizes as safe for rewrite. Compounds, pipelines, redirections, and unchanged commands bypass wrapper rewrite and run normally.

**Fail-open:** If the wrapper cannot load Ralph libs, storage fails, or `RALPH_NATIVE_SHELL_WRAPPER=0` explicitly disables it, the command runs unwrapped. Rewrite failures never block the agent.

<a id="opencode-native-hook-status"></a>

**OpenCode hybrid contract (documented local plugin path; native adapters unproven headless):** Verified on OpenCode **1.14.35** (2026-06-04): Ralph stages `bundle/.opencode/plugins/ralph-runtime-hooks.ts` to workspace `.opencode/plugins/` (documented auto-discovery path proven via T6). Plugin code implements `tool.execute.before` and `tool.execute.after` (T7 verified). In `--ralph-mode hybrid`, native OpenCode tools (`read`, `grep`, `glob`, `bash`) and Ralph MCP tools are both available; Ralph does not deny native tools to control context. Native exploration output is compacted/windowed through Ralph's shared `native-result-compact` path with `result_windowing` telemetry.

**Authoritative compaction:** **MCP-proxy compaction** (`RALPH_NATIVE_RESULT_COMPACT=1`, `RALPH_PROXY_SHELL_COMPACT=1`, `native-result-compact-cli.sh`) is authoritative by default. Ralph checks `.ralph-workspace/artifacts/PLAN13/opencode-hook-revalidation.md` when present; only when that artifact records `headless_mutation_reaches_model: yes` does the **plugin-hook mutation** path become authoritative instead. Without that verdict, headless `opencode run` hook invocation and agent-visible output mutation remain unproven; overlay records `native_hooks_configured=true`, `native_hooks_effective=false`, `native_hooks_reason=plugin_injected_unproven_headless`, `fallback_path_active=true`, and `native_shell_compaction_authoritative=mcp_proxy_compaction`.

**Cache-read reporting:** Provider cache-read token fields are model/provider dependent and are telemetry only (optimization hints, not the primary context-control mechanism). See [TOOLING.md#opencode-hybrid-contract](TOOLING.md#opencode-hybrid-contract) and `bundle/.opencode/plugins/SPIKE-output-mutation.md`.

### Shell command rewrite runtime matrix (Phase 5 outcome)

Ralph rewrites a small allowlist of noisy shell commands once in shared registry libraries ([`shell_command_registry.py`](../bundle/.ralph/python/shell_command_registry.py), [`shell-command-rewrite.py`](../bundle/.ralph/python/shell-command-rewrite.py), [`command-rewriter.sh`](../bundle/.ralph/bash-lib/command-rewriter.sh)), then exposes rewrite through MCP (all runtimes) and an optional native adapter (Claude only). Cursor plan runs use the MCP registry path only—no runtime-specific rewrite hooks. Full rules, policy order, and agent workflow: [TOOLING.md](TOOLING.md#shell-command-rewriting).

| Layer | Applies to | Mechanism | Gate |
|-------|------------|-----------|------|
| **Universal (MCP)** | Claude, Cursor, Codex, OpenCode | `ralph_proxy_shell` rewrites after the original command passes policy, then re-validates the rewritten command against the shell allowlist before execution | `--ralph-mode ralph` and `RALPH_PROXY_SHELL_REWRITE=1` |
| **Adapter-backed (native shell)** | Claude only | `PreToolUse:Bash` hook [`bundle/.claude/hooks/rewrite-bash-command.sh`](../bundle/.claude/hooks/rewrite-bash-command.sh) returns `hookSpecificOutput.updatedInput` with a new `command` (other `tool_input` keys preserved) | `RALPH_BASH_REWRITE=1` (wired in [`bundle/.claude/settings.json`](../bundle/.claude/settings.json)); hook failures fail open |
| **Unsupported / deferred (native shell)** | Cursor (Shell output only), Codex, OpenCode | Cursor Shell output replace unproven; Codex/OpenCode deferrals match compaction matrix above | Use `RALPH_PROXY_SHELL_REWRITE=1` with `--ralph-mode ralph` |

Rewriting cannot broaden policy: if the rewritten command is not on the shell allowlist, the MCP call fails. Compound pipelines are denied by policy before rewrite runs; the pure rewriter also bails unchanged on compounds and other unsafe forms (see [TOOLING.md](TOOLING.md#shell-command-rewriting)).

#### Universal via MCP (all runtimes)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_PROXY_SHELL_REWRITE` | off | When `1`, `true`, `yes`, or `on`, `ralph_proxy_shell` may rewrite allowlisted commands before execution. Default off. Requires Ralph mode `ralph`. |
| `RALPH_PROXY_SHELL_REWRITE_LOG` | unset | When set to a file path, append one JSON object per applied rewrite (original command, rewritten command, `ruleId`, UTC `timestamp`, `planKey`, `workspace`). No log lines when rewrite is off, the rewriter bails unchanged, or python3 is unavailable (rewriter returns unchanged). |

The shell compact envelope's `command` field reflects the command actually executed (after rewrite when enabled).

#### Adapter-backed (native shell command rewrite)

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_BASH_REWRITE` | off | When `1`, `true`, `yes`, or `on`, enables simple command rewrite fallback. Claude `PreToolUse:Bash` runs the shared rewriter and may replace `tool_input.command` via `updatedInput`. Cursor and Codex use this as fallback when `RALPH_NATIVE_SHELL_WRAPPER=0` or wrapper unavailable. Default off. Fail-open: hook errors never block the agent. |
| `RALPH_BASH_REWRITE_LOG` | unset | Optional JSONL audit path: `originalCommandHash`, `rewrittenCommandHash`, `reason` (rule id), `rewriteApplied` (`true` when `updatedInput` is emitted; no suggest-only path), plus `command`, `rewrittenCommand`, `planKey`, `workspace`, `runtime`. Appended for both Claude PreToolUse rewrites and Cursor/Codex fallback rewrites. |

**Runtime-specific rewrite behavior:**
- **Claude:** PreToolUse:Bash input rewrite (proven on 2.1.162) via `rewrite-bash-command.sh`; gated by `RALPH_BASH_REWRITE=1`.
- **Cursor:** Shell `preToolUse` input rewrite proven on headless plan runs (2026.06.03-0bbb28e). Primary path is wrapper-based compaction (`RALPH_NATIVE_SHELL_WRAPPER=1`); simple rewrite only via fallback when wrapper is off.
- **Codex:** Bash `PreToolUse` input rewrite proven on CLI 0.136.0 (T5). Primary path is wrapper-based compaction (`RALPH_NATIVE_SHELL_WRAPPER=1`); simple rewrite only via fallback when wrapper is off.
- **OpenCode:** No native rewrite adapter. Use MCP proxy rewrite (`RALPH_PROXY_SHELL_REWRITE=1` with `--ralph-mode ralph`).

## Cookbook feature gates (Tier 1 through Tier 3)

Cookbook optimizations follow the [rollout convention](#ralph-mode-plan-runs) above: enabled in `ralph`/`hybrid` unless the listed variable is `0`; disabled in `no`/`native` unless set to `1`. Invalid boolean values fail early. Migration and promotion rules: [docs/cookbook-review/MIGRATION.md](cookbook-review/MIGRATION.md).

| Variable | Purpose |
|----------|---------|
| `RALPH_MCP_COMPACT_TOOL_CATALOG` | Compact MCP `tools/list` (default `1` in Ralph/hybrid). Set `0` to advertise the full proxy catalog. |
| `RALPH_MCP_CORE_TOOLS` | Comma/semicolon-separated override for core tool names when compact catalog is active. |
| `RALPH_ARTIFACT_SCHEMA_VALIDATION` | Post-stage JSON Schema validation for orchestration artifacts that declare `schema`. |
| `RALPH_ARTIFACT_PROVENANCE` | Post-stage citation validation when artifacts declare `provenance: required\|optional`. |
| `RALPH_EVALUATOR_JSON_CONTRACT` | Parse loop-check artifacts as `{status, feedback[]}` when an evaluator schema is declared. |
| `RALPH_RUBRIC_GRADER` | Independent rubric grading with deterministic checks first (`sessionStrategy: fresh` stages). |
| `RALPH_ROUTER_STAGE` | Schema-validated forward-only router dispatch between orchestration stages. |
| `RALPH_DYNAMIC_PLANNER` | Bounded dynamic planner/decomposition stage (`planner` block in orchestration JSON). |
| `RALPH_FINAL_OUTPUT_SCHEMA` | Structured final-output enforcement via capability-detected CLI flags plus Ralph validation. |
| `RALPH_STRUCTURED_OUTPUT_SCHEMA` | Project-root-relative JSON Schema path for final-output validation when gate is enabled. |
| `RALPH_RESULT_REDUCE` | Advertises `ralph_proxy_result_reduce` for bounded local reduction of stored proxy results. |
| `RALPH_RESULT_REDUCE_MAX_INPUT_BYTES` | Max bytes read from a stored result per reduce call (default from reducer module). |
| `RALPH_SKILL_PACKAGE_VALIDATION` | Validates SKILL.md package layout during sync and agent-config validation. |
| `RALPH_TOOL_EVAL` | Set to `live` for live cross-runtime tool-eval harness (offline replay is the CI default). |
| `RALPH_TOOL_EVAL_FORCE_LIVE` | Set to `1` to allow live tool-eval in CI (default blocked). |

Related variables documented elsewhere in this file: `RALPH_PROMPT_STABLE_PREFIX`, `RALPH_CONTINUATION_SUMMARY*`, `RALPH_PROGRESSIVE_CONTEXT*`, `RALPH_PLAN_MEMORY*`, `RALPH_MCP_CONTEXTUAL_SEARCH`, `RALPH_REASONING_EFFORT`, `RALPH_CLAUDE_SPECULATIVE_CACHE_WARM` (default off; capability-gated warm path).

## Knowledge graph (experimental, disabled by default)

The workspace knowledge graph is hidden from plan runs unless `RALPH_KNOWLEDGE_FEATURE=on`. With the master gate off (default), `run-plan.sh` does not expose knowledge MCP tools, inject knowledge into prompts, or auto-capture post-TODO records.

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_KNOWLEDGE_FEATURE` | off | Master gate. When off, all plan-run knowledge surfaces stay hidden regardless of `--knowledge-tools` or per-capability `RALPH_KNOWLEDGE_*` vars. Set to `on` to re-enable experimental knowledge behavior. |
| `RALPH_KNOWLEDGE_TOOLS` | off | With `--ralph-mode ralph` and `RALPH_KNOWLEDGE_FEATURE=on`, enables knowledge MCP tools and related env for the plan run. Ignored when the master gate is off. |
| `RALPH_KNOWLEDGE_ENABLED` | off | When on (and master gate on), includes `ralph_knowledge_*` in MCP `tools/list`. |
| `RALPH_KNOWLEDGE_RECORD_ENABLED` | off | Allows `ralph_knowledge_record`. |
| `RALPH_KNOWLEDGE_QUERY_ENABLED` | off | Allows `ralph_knowledge_query` and `ralph_knowledge_status`. |
| `RALPH_KNOWLEDGE_INJECT_ENABLED` | off | Injects matching knowledge into each TODO prompt in `run-plan.sh`. |
| `RALPH_KNOWLEDGE_MAX_BYTES` | `2048` | Max bytes of injected markdown per TODO. |
| `RALPH_PLAN_POST_TODO_KNOWLEDGE` | off | Post-TODO auto-capture mode (`0`, `1`, or `auto`). No-op when `RALPH_KNOWLEDGE_FEATURE` is off. |

`knowledge-tool.sh` is not gated by `RALPH_KNOWLEDGE_FEATURE`; operators invoke it directly for init/record/query/status/cleanup/export.

## Killswitch

The killswitch blocks dangerous commands, tools, or file paths before they execute. Configuration is loaded from `killswitch.json` (per-workspace, global, or bundle default). Full configuration reference: [SECURITY.md](SECURITY.md#kill-switch).

| Variable | Purpose |
|----------|---------|
| `RALPH_KILLSWITCH_DISABLED` | Set to `1` to disable the killswitch entirely. |
| `RALPH_BANNED_TOOLS` | Comma-separated tool names or glob patterns to block (added to config). |
| `RALPH_BANNED_PATHS` | Comma-separated file path patterns to block (added to config). |
| `RALPH_BANNED_PATTERNS` | Comma-separated regex patterns for command matching (uses bash ERE, added to config). |

Configuration file search order:
1. `$WORKSPACE/.ralph-workspace/killswitch.json`
2. `$RALPH_HOME/killswitch.json`
3. Bundle default (`bundle/.ralph/killswitch.json`)

## Safety and usage prompt

| Variable | Purpose |
|----------|---------|
| `RALPH_USAGE_RISKS_ACKNOWLEDGED` | Set to `1` to skip the interactive usage-risk prompt (CI and automation). |

## Dashboard (Node)

| Variable | Purpose |
|----------|---------|
| `PORT` | HTTP port for `npm start` in `ralph-dashboard` (default if unset is package-specific). |

---

Maintainers: when adding new env-driven behavior, update this file as the canonical reference; keep [`AGENTS.md`](../AGENTS.md) Reference map pointers in sync when agents need a new docs target.
