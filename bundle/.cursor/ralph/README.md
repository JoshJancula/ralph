# Ralph plan runner (Cursor)

This directory holds the Cursor-backed plan loop. The following audit records **reusable logic** in `run-plan.sh` and **Cursor-only assumptions** to abstract when adding Claude (or other) CLI support.

## Reusable functions and portable behavior

These blocks are largely toolchain-agnostic; only their callers or env names tie them to Cursor.

| Piece | Role |
|-------|------|
| **Caffeinate re-exec** (Darwin) | Re-runs script under `caffeinate` unless disabled; env gate `CURSOR_PLAN_CAFFEINATED` prevents loops. Portable with optional rename of env prefix. |
| **Argument parsing** | `--plan <path>` plus optional workspace directory; resolves absolute paths and `~`. |
| **`log`** | Timestamped append to `LOG_FILE`; optional stderr mirror via verbose flag. |
| **`get_plan_path`** | Reads default plan path from JSON config via grep/sed (no `jq`). Path resolution: absolute, `~`, or relative to workspace. |
| **`plan_log_basename`** | Sanitizes plan filename for log file suffixes. |
| **`get_config_model`** | Reads optional default model id from same JSON pattern as `plan`. |
| **`get_next_todo`** | First markdown line matching unchecked checkbox `- [ ]` (space inside brackets). |
| **`count_todos`** | Counts `- [ ]` and `- [x]` lines for progress and completion. |
| **Plan path resolution** | Override vs config vs `PLAN.md` default. |
| **Per-plan log paths** | `LOG_FILE` / `OUTPUT_LOG` with env overrides. |
| **Gutter detection** | Same TODO line repeated past `CURSOR_PLAN_GUTTER_ITER` exits for human intervention. |
| **Progress loop** | Background agent process; polls output log size for “first output”; periodic elapsed messages. |
| **`prompt_cleanup_on_exit`** | EXIT trap offering `.ralph/cleanup-plan.sh <artifact-namespace>`. |
| **`run_agent` (inline)** | Invokes CLI with prompt, pipes through `tee` to output log, records exit code. Pattern is reusable for any CLI that accepts a prompt string. |

**Portable surrounding behavior:** TTY detection for colors; `MAX_ITERATIONS`; workspace `cd` before agent run; iteration banner and structured append to output log.

## Cursor-specific assumptions to abstract for Claude

1. **Executable discovery**  
   Only `cursor-agent` or `agent` on PATH. Claude support needs a configurable binary (env or flag), e.g. `CLAUDE_PLAN_CLI` / `claude`, with parallel install/login messaging.

2. **CLI invocation contract**  
   Assumes: `-p --force`, optional `--model <id>`, and prompt as final argument. Claude CLI may use different flags, stdin vs argv, or subcommands; this must be pluggable.

3. **Model listing and selection**  
   `list_agents` runs `$CURSOR_CLI --list-models` and parses lines with ` - `. Menus and `get_config_model` assume Cursor model ids. Claude needs its own list/discovery or a static config map.

4. **Naming and paths**  
   - Config file fixed at `$WORKSPACE/.cursor/ralph/plan-runner.json`.  
   - Logs under `$WORKSPACE/.cursor/ralph/`.  
   - Env prefix `CURSOR_PLAN_*` everywhere.  
   For Claude, mirror under `.claude/ralph/` or make base dir configurable.

5. **User-facing copy**  
   Errors and help text reference Cursor CLI, cursor.com docs, `~/.local/bin`, and “cursor-agent default”. Replace with Claude-specific docs and binary names where appropriate.

6. **Embedded prompt template**  
   The loop injects rules about toolchain discovery, verification, and marking `[x]` in the plan file. The *mechanism* is reusable; *wording* may diverge per product.

7. **`cleanup-plan.sh`**  
   Shared cleanup script located at `.ralph/cleanup-plan.sh` requires an artifact namespace and deletes `.agents/logs/<namespace>/plan-runner-*` plus `.agents/artifacts/<namespace>/` to clear plan output regardless of runtime.

## `plan.template` and `plan-runner.json` notes

- **`plan.template`**: Example TODO lines use `- []`. `get_next_todo` only matches `- [ ]` (space between brackets). Templates should use `- [ ]` so items are picked up.
- **`plan-runner.json`**: Currently `{ "plan": "PLAN.md" }`. The script also supports optional `"model"` (not present in repo). Schema is informal JSON; validation and a Claude twin config should stay aligned.

## Summary for Claude ralph

Preserve: plan parsing, gutter/max iteration, logging layout pattern, progress UX, cleanup trap, caffeinate. Replace or parameterize: CLI binary, invoke flags, model discovery, config/log directory roots, env prefix, and user-facing strings.

## Codex Ralph runner

Multi-runtime pipelines use **`.ralph/orchestrator.sh`** with JSON `.orch.json`; each stage sets `"runtime"` to `cursor`, `claude`, or `codex`. Codex stages invoke `.codex/ralph/run-plan.sh` (same `--plan` / `--agent` / `--non-interactive` contract). Logs: `.agents/logs/<artifact-namespace>/plan-runner-*.log`. Sample all-Codex orchestration: `.agents/orchestration-plans/codex-ralph-support/codex-ralph-support-codex.orch.json`.
