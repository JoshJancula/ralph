# shellcheck shell=bash
## Core run-plan logic moved here; source from run-plan.sh.
## Do not execute directly.
##
## Environment exported for child CLIs and helpers:
##   RALPH_PLAN_KEY -- stable id for this plan (logs, sessions, defaults).
##   RALPH_ARTIFACT_NS -- artifact namespace (defaults to plan key).
##   OUTPUT_LOG -- file path for tee'd assistant CLI output.
##   RALPH_PLAN_SESSION_STRATEGY -- fresh | resume | reset | compact.
##   RALPH_PLAN_CLI_RESUME -- derived compatibility flag (1 for resume/reset/compact or todo-continue).
##   RALPH_PLAN_INVOCATION_REASON -- todo-start | todo-continue (supervisor-owned).
##   RALPH_TODO_SESSION_MANIFEST_PATH -- per-TODO session manifest for the active attempt.
##   RALPH_TODO_SESSION_MANIFEST_KEY -- sanitized manifest key for the active TODO.
##   RALPH_TODO_SESSION_MANIFEST_DIR -- todo-sessions directory under RALPH_SESSION_DIR.
##   RALPH_PLAN_RESET_COMMAND(_<RUNTIME>) -- optional reset command prefix for reset strategy prompts.
##   RALPH_PLAN_COMPACT_COMMAND(_<RUNTIME>) -- optional prefix for compact strategy prompts
##
## Public interface (functions): ralph_run_plan_log, ralph_ensure_*_cli, ralph_path_to_file_uri,
## ralph_human_* / ralph_operator_* for human-in-the-loop flows, and related helpers below.
WORKSPACE="$(pwd)"
PLAN_OVERRIDE=""
PREBUILT_AGENT=""
PLAN_MODEL_CLI=""
PLAN_REASONING_EFFORT_CLI=""
INTERACTIVE_SELECT_AGENT_FLAG=0
INTERACTIVE_SELECT_MODEL_FLAG=0
NON_INTERACTIVE_FLAG=0
SKIP_MCP_PREFLIGHT_FLAG=0
CLI_RESUME_FLAG=0
NO_CLI_RESUME_FLAG=0
ALLOW_UNSAFE_RESUME_FLAG=0
RESUME_SESSION_ID_OVERRIDE=""
SESSION_STRATEGY_FLAG=""
RUNTIME=""
RALPH_PLAN_TODO_MAX_ITERATIONS=""
CLAUDE_TOOLS_FROM_AGENT=""
_RALPH_CLI_RESUME_ENV_WAS_SET=0
[[ "${RALPH_PLAN_CLI_RESUME+x}" == x ]] && _RALPH_CLI_RESUME_ENV_WAS_SET=1

# SCRIPT_DIR already used in other helpers; set it early so helpers can load additional libs.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/ralph-wait.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-approvals.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-loopback.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/rubric-grader.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/orchestrator/orchestrator-router.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-structured-output.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/runtime-normalize.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/permission-classify.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/human-interaction.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/ui-prompt.sh"
# Loaded for graph nodes only at the claim gate below; the helper itself is
# inert unless scheduler identity variables are present.
source "$SCRIPT_DIR/bash-lib/graph/graph-delegation-completion.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-bg-completion-gate.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-bg-teardown.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-bg-invocation-wait.sh"

# The main runner sources run-plan-args.sh before this file. Some tests source
# run-plan-core.sh directly, so tolerate that load order and skip argument
# parsing when the helper has not been defined yet.
if declare -F ralph_run_plan_parse_args >/dev/null 2>&1; then
  ralph_run_plan_parse_args "$@"
fi

# Colors before any interactive menu (runtime picker runs before ralph_run_plan_log() exists).
# Disable with CURSOR_PLAN_NO_COLOR=1 (honored across runtimes).
if [[ -t 1 && "${CURSOR_PLAN_NO_COLOR:-0}" != "1" ]]; then
  C_R=$'\033[31m'
  C_G=$'\033[32m'
  C_Y=$'\033[33m'
  C_B=$'\033[34m'
  C_C=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RST=$'\033[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
fi

ralph_normalize_tool_access() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    native|ralph)
      printf '%s' "$value"
      return 0
      ;;
    1|true|yes|on)
      printf 'ralph'
      return 0
      ;;
    0|false|no|off)
      printf 'native'
      return 0
      ;;
  esac
  return 1
}

ralph_mode_prompt_guidance_stored_result_protocol() {
  local read_tool="${1:-ralph_proxy_result_read}"
  local search_tool="${2:-ralph_proxy_result_search}"
  local summary_tool="${3:-ralph_proxy_result_summary}"
  cat <<EOF
When a tool response is truncated or the compact envelope includes a \`resultId\`, treat the inline \`preview\` as the compacted first-pass answer. For more context use \`${read_tool}\` with \`view=compacted\` (default); use \`view=raw\` only when you need exact or full inspection. \`${search_tool}\` and \`${summary_tool}\` help page and locate content. Page with byte or line ranges instead of repeating broad reads or shell calls.

Choose the stored-result view by information need:
- Use \`view=compacted\` first for build/test/lint output, package-manager installs, CI logs, server logs, watcher output, and long log files; the compacted view is designed to surface recent failures, summaries, and useful tails without rereading the full stream.
- Use \`${search_tool}\` before raw reads when you only need errors, stack traces, filenames, test names, warnings, or one section of a stored result.
- Use byte/line ranges with \`view=compacted\` for follow-up paging through logs.
- Use \`view=raw\` for source files, generated code, structured data, exact diffs, or when the compacted view/search does not contain the exact content needed.
EOF
}

# Cost model for waits and verification (runtime-neutral). Cheapest first.
# Background-job guidance is separate and gated on RALPH_BG_JOBS=1.
ralph_mode_prompt_guidance_cost_model() {
  cat <<'EOF'
## Verification and wait cost model (cheapest first)
1. Prefer strict runner-owned `verify:` / plan-level `verify:` for final proof. The runner executes those out-of-process; do not rerun them through agent-side shell helpers.
2. For any other command that fits in one tool call, use **one blocking call** and wait inside that call. Do not background work that a single blocking wait can finish.
3. **Agent-authored polling loops are forbidden** (for example `while grep -c ...; sleep` over a log file). Never spend model turns polling a log or job status — that pattern wastes conversation turns.
- `ralph_proxy_shell` (synchronous) is for short bounded exploratory commands only (e.g., `ls`, `cat`, `grep`, `git status`). Do not run test/lint/build/install/docs-check commands through `ralph_proxy_shell`; those block the MCP transport and risk dropping the connection.
- Async proxy shell tools (`ralph_proxy_shell_start` / `wait` / `status` / `read` / `cancel`) are a **manual human-monitoring fallback only**, not the automation path. Prefer runner-first `verify:` and one blocking call.
- When you must use async tools manually (including agent-run `verification:` only), launch once with `ralph_proxy_shell_start` and block with `ralph_proxy_shell_wait`, passing `waitSeconds` near its **600** cap (the default is only 60). Treat `ralph_proxy_shell_status` as an occasional spot check — never a polling loop. Inspect output with `ralph_proxy_shell_read`; cancel with `ralph_proxy_shell_cancel` when needed.
EOF
}

# Opt-in background-job guidance. Emitted only when RALPH_BG_JOBS=1.
ralph_mode_prompt_guidance_background() {
  [[ "${RALPH_BG_JOBS:-0}" == "1" ]] || return 0
  cat <<'EOF'
## Background jobs (opt-in; RALPH_BG_JOBS=1)
When work would outlive the tool timeout, start one background job via `.ralph/ralph-bg.sh '<command>'`, then end your turn without claiming completion. Do not convert a single blocking call into a background job. The runner or Stop hook continues this same TODO with a compact result — do not redo the TODO from scratch and do not poll the job.
EOF
}

ralph_mode_prompt_guidance_common_footer() {
  cat <<'EOF'
Prefer targeted search and partial file/log reads first.
If the TODO already names exact commands or files, start there before rereading README/AGENTS or remapping the repo.
EOF
  ralph_mode_prompt_guidance_cost_model
  ralph_mode_prompt_guidance_background
  cat <<'EOF'
- Verification ownership: long-running verification and completion checks belong to the runner, not the agent loop. TODO `verification:` is agent-run verification instructions; TODO `verify:` and plan-level `verify:` are strict runner-executed commands. The runner executes strict verify commands out-of-process, stores full output as a compact artifact, and reopens the TODO with a short failure summary when verification fails—do not rerun strict verify commands through agent-side shell helpers.
EOF
}

# Guidance for what an agent should do when Ralph tooling (MCP transport,
# proxy shell, etc.) fails mid-run. The correct behavior depends on whether
# native runtime tools are available as a fallback:
#   full    - hybrid mode: native read/search/shell/edit all available.
#             Cut over to native tools; do not stop to ask the operator.
#   partial - non-strict ralph mode: native Read/Edit/Write available but
#             native shell/search are not. Use native tools for what they
#             cover; only escalate to the operator when the remaining work
#             genuinely needs shell/search that no native tool can provide.
#   none    - strict proxy: native fallback is forbidden by policy, so the
#             only recourse is a structured human-request record.
# Arg $1 selects the variant (default: none, the conservative choice).
ralph_mode_prompt_guidance_ralph_failure_footer() {
  local native_fallback="${1:-none}"
  case "$native_fallback" in
    full)
      cat <<'EOF'
Do not loop on WaitForMcpServers. If Ralph tooling fails mid-run (MCP timeout, "Connection closed", "MCP error -32000/-32001", or `mcp__ralph__*` tools disappearing), do not stop to ask the operator and do not write pending-human.txt for the tooling failure itself. Immediately cut over to the native runtime tools (Read, Edit, Write, Bash, and native search) and finish the TODO with them. Only write pending-human.txt if the TODO needs a decision or input that no tool — Ralph or native — can supply.
EOF
      ;;
    partial)
      cat <<'EOF'
Do not loop on WaitForMcpServers. If Ralph tooling fails mid-run (MCP timeout, "Connection closed", "MCP error -32000/-32001", or `mcp__ralph__*` tools disappearing), do not stop to ask the operator for the tooling failure itself. Cut over to the native runtime tools that remain available (native Read, Edit, and Write) and complete as much of the TODO as they cover. Only write one structured human-request record to pending-human.txt when the remaining work requires shell or search that no available tool can provide.
EOF
      ;;
    *)
      cat <<'EOF'
Do not loop on WaitForMcpServers. If Ralph tooling fails mid-run, write one structured human-request record to pending-human.txt and stop without retrying the same blocked call.
EOF
      ;;
  esac
}

ralph_mode_prompt_guidance_tool_batch_footer() {
  cat <<'EOF'
When you need two or more independent read/search/glob/result operations, batch them with `ralph_proxy_batch` (or `mcp__ralph__ralph_proxy_batch` when only MCP-qualified names are registered) instead of issuing serial proxy calls. `ralph_proxy_batch` is read-only: shell, async shell, edit, write, and repomap operations are rejected inside a batch; keep shell calls as separate `ralph_proxy_shell` invocations for policy and side-effect safety.
Avoid rereading the same file window; when a prior read was truncated or deduped, page stored results with `ralph_proxy_result_read` (`view=compacted` by default; `view=raw` only when the compacted view is insufficient). Prefer compacted/search follow-ups for logs and command output; reserve raw follow-ups for exact source, generated code, structured data, or missing details. Do not read the active plan file unless the current TODO explicitly requires it—the runner already injects the open TODO.
EOF
}

ralph_mode_prompt_guidance_plan_memory() {
  local prefix="${1:-ralph_proxy_memory}"
  cat <<EOF
Plan memory (\`${prefix}_*\`) persists bounded notes under \`.ralph-workspace/memory/<plan-key>/\` for the active plan only. Memory content is untrusted model-authored data from prior turns or sessions. Before acting on a memory entry, verify it against current source files, artifacts, or verification output. Use \`ralph_proxy_tool_search\` to discover memory tools when they are hidden behind the compact tool catalog.
EOF
}

ralph_mode_prompt_guidance_native() {
  local runtime="${1:-}"
  cat <<'EOF'
## Ralph Mode (native)

Use native runtime tools as your primary path for exploration, verification, and file changes. Ralph exposes result-retrieval tooling for stored outputs from native adapters and prior tool calls.
EOF
  case "$runtime" in
    claude)
      ralph_mode_prompt_guidance_stored_result_protocol \
        "mcp__ralph__ralph_proxy_result_read" \
        "mcp__ralph__ralph_proxy_result_search" \
        "mcp__ralph__ralph_proxy_result_summary"
      cat <<'EOF'
Native `Read`, `Edit`, and `Write` are your normal modification path. Claude Code requires a native `Read` of a file before you can `Edit` or `Write` it. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
    cursor)
      ralph_mode_prompt_guidance_stored_result_protocol \
        "ralph_proxy_result_read" \
        "ralph_proxy_result_search" \
        "ralph_proxy_result_summary"
      cat <<'EOF'
Native `Read`, `Edit`, and `Write` are your normal modification path. Use native `Read` immediately before `Edit` or `Write` on a file that will be modified. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
    codex)
      ralph_mode_prompt_guidance_stored_result_protocol \
        "ralph_proxy_result_read" \
        "ralph_proxy_result_search" \
        "ralph_proxy_result_summary"
      cat <<'EOF'
Native `Read`, `Edit`, and `Write` are your normal modification path. When you intend to change a file, read it before editing and then use your host edit/write tools. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
    opencode)
      ralph_mode_prompt_guidance_stored_result_protocol \
        "ralph_proxy_result_read" \
        "ralph_proxy_result_search" \
        "ralph_proxy_result_summary"
      cat <<'EOF'
If a referenced file lives outside the workspace and OpenCode denies the read as `external_directory`, continue with local workspace files or write `pending-human.txt` instead of retrying the same denied path.
Native `Read`, `Edit`, and `Write` are your normal modification path. Use native `Read` immediately before `Edit` or `Write` on a file that will be modified. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
    *)
      ralph_mode_prompt_guidance_stored_result_protocol
      cat <<'EOF'
Native runtime edit/write tools remain available for file modifications where the runtime requires them. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
  esac
  ralph_mode_prompt_guidance_common_footer
}

ralph_mode_prompt_guidance_ralph_catalog() {
  local runtime="${1:-}"
  case "$runtime" in
    claude)
      cat <<'EOF'
Ralph tooling is preflight-checked before this invocation. Native `Read`, `Grep`, and `Glob` are the primary exploration tools.
- Run every shell command through `mcp__ralph__ralph_proxy_shell` (native `Bash` is unavailable in ralph mode; in hybrid it is discouraged for noisy output).
- Use `mcp__ralph__ralph_proxy_result_*` to page stored shell output.
- `mcp__ralph__ralph_proxy_read` is for files outside the agent workspace (the read-only plan roots) and for batched multi-file reads via `mcp__ralph__ralph_proxy_batch`.
- The async shell tools (`mcp__ralph__ralph_proxy_shell_start/wait/status/read/cancel`) are a manual human-monitoring fallback only—not the primary automation path. Prefer runner-first `verify:` and one blocking call. When async tools are needed, block with `mcp__ralph__ralph_proxy_shell_wait` and pass `waitSeconds` near its 600 cap (default is only 60); `mcp__ralph__ralph_proxy_shell_status` is an occasional spot check, never a polling loop.
EOF
      ralph_mode_prompt_guidance_stored_result_protocol \
        "mcp__ralph__ralph_proxy_result_read" \
        "mcp__ralph__ralph_proxy_result_search" \
        "mcp__ralph__ralph_proxy_result_summary"
      cat <<'EOF'
Native `Read`, `Edit`, and `Write` remain available for modifying files. Claude Code requires a native `Read` of a file before you can `Edit` or `Write` it. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
    cursor)
      cat <<'EOF'
Ralph tooling is preflight-checked before this invocation. Cursor registers Ralph tools as `ralph_proxy_*` (or `mcp__ralph__ralph_proxy_*` when only MCP-qualified names appear). Native `Read`, `Grep`, and `Glob` are the primary exploration tools.
- Run every shell command through `ralph_proxy_shell` (or `mcp__ralph__ralph_proxy_shell` when only MCP-qualified names appear); native `Shell` is discouraged for noisy output in ralph/hybrid.
- Use `ralph_proxy_result_*` to page stored shell output.
- `ralph_proxy_read` is for files outside the agent workspace (the read-only plan roots) and for batched multi-file reads via `ralph_proxy_batch`.
- The async shell tools (`ralph_proxy_shell_start/wait/status/read/cancel`) are a manual human-monitoring fallback only—not the primary automation path. Prefer runner-first `verify:` and one blocking call. When async tools are needed, block with `ralph_proxy_shell_wait` and pass `waitSeconds` near its 600 cap (default is only 60); `ralph_proxy_shell_status` is an occasional spot check, never a polling loop.
EOF
      ralph_mode_prompt_guidance_stored_result_protocol \
        "ralph_proxy_result_read" \
        "ralph_proxy_result_search" \
        "ralph_proxy_result_summary"
      cat <<'EOF'
Native `Read`, `Edit`, and `Write` remain available for modifying files. When you intend to change a file, read it before editing, then use your host edit/write tools. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
    opencode)
      cat <<'EOF'
Ralph tooling is preflight-checked before this invocation. Native `Read`, `Grep`, and `Glob` are the primary exploration tools.
- Run every shell command through `ralph_proxy_shell` (or `mcp__ralph__ralph_proxy_shell` when only MCP-qualified names appear); native shell is discouraged for noisy output in ralph/hybrid.
- Use `ralph_proxy_result_*` to page stored shell output.
- `ralph_proxy_read` is for files outside the agent workspace (the read-only plan roots) and for batched multi-file reads via `ralph_proxy_batch`.
- The async shell tools (`ralph_proxy_shell_start/wait/status/read/cancel`) are a manual human-monitoring fallback only—not the primary automation path. Prefer runner-first `verify:` and one blocking call. When async tools are needed, block with `ralph_proxy_shell_wait` and pass `waitSeconds` near its 600 cap (default is only 60); `ralph_proxy_shell_status` is an occasional spot check, never a polling loop.
EOF
      ralph_mode_prompt_guidance_stored_result_protocol \
        "ralph_proxy_result_read" \
        "ralph_proxy_result_search" \
        "ralph_proxy_result_summary"
      cat <<'EOF'
If a referenced file lives outside the workspace and OpenCode denies the read as `external_directory`, continue with local workspace files or write `pending-human.txt` instead of retrying the same denied path.
Native `Read`, `Edit`, and `Write` remain available for modifications. When you intend to change a file, read it before editing and then use your host edit/write tools. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
    codex)
      ralph_mode_prompt_guidance_ralph_catalog_codex "ralph"
      ;;
    *)
      cat <<'EOF'
Ralph tooling is preflight-checked before this invocation. The host may expose Ralph tools with direct names (`ralph_proxy_*`) or MCP-qualified names (`mcp__ralph__ralph_proxy_*`); use whichever names the host registers. Native `Read`, `Grep`, and `Glob` are the primary exploration tools.
- Run every shell command through `ralph_proxy_shell` (or `mcp__ralph__ralph_proxy_shell` when only namespaced tools exist); native `Bash` is unavailable in ralph mode and discouraged for noisy output in hybrid.
- Use `ralph_proxy_result_*` (or `mcp__ralph__ralph_proxy_result_*`) to page stored shell output.
- `ralph_proxy_read` / `mcp__ralph__ralph_proxy_read` is for files outside the agent workspace (the read-only plan roots) and for batched multi-file reads via `ralph_proxy_batch` / `mcp__ralph__ralph_proxy_batch`.
- The async shell tools (`ralph_proxy_shell_start/wait/status/read/cancel` or `mcp__ralph__ralph_proxy_shell_start/wait/status/read/cancel`) are a manual human-monitoring fallback only—not the primary automation path. Prefer runner-first `verify:` and one blocking call. When async tools are needed, block with `ralph_proxy_shell_wait` (or the MCP-qualified wait tool) and pass `waitSeconds` near its 600 cap (default is only 60); status tools are an occasional spot check, never a polling loop.
EOF
      ralph_mode_prompt_guidance_stored_result_protocol
      cat <<'EOF'
Native `Read`, `Edit`, and `Write` remain available for modifying files; when only direct names are exposed, read a file first before editing it, then use your host's edit/write tools. Never tell the operator you lack edit access -- you have it.
EOF
      ;;
  esac
}

ralph_mode_prompt_guidance_ralph_catalog_codex() {
  local mode="${1:-ralph}"
  local strict=""
  if [[ "${RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY:-0}" == "1" ]] || [[ "${RALPH_STRICT_PROXY:-0}" == "1" ]]; then
    strict=1
  fi
  cat <<'EOF'
Ralph tooling is preflight-checked before this invocation. Native `Read`, `Grep`, and `Glob` (including `read_file` where the host exposes that name) are the primary exploration tools.
- Run every shell command through `ralph_proxy_shell` / `mcp__ralph__ralph_proxy_shell` (native `command_execution` is discouraged for noisy output in ralph/hybrid).
- Use `ralph_proxy_result_*` to page stored shell output.
- `ralph_proxy_read` / `mcp__ralph__ralph_proxy_read` is for files outside the agent workspace (the read-only plan roots) and for batched multi-file reads via `ralph_proxy_batch`.
- The async shell tools (`ralph_proxy_shell_start/wait/status/read/cancel`) are a manual human-monitoring fallback only—not the primary automation path. Prefer runner-first `verify:` and one blocking call. When async tools are needed, block with `ralph_proxy_shell_wait` and pass `waitSeconds` near its 600 cap (default is only 60); `ralph_proxy_shell_status` is an occasional spot check, never a polling loop.
EOF
  if [[ "$mode" == "hybrid" ]]; then
    cat <<'EOF'
When Ralph tooling is slow, failing, or unsuitable for a given call, use native adapters freely, including native edit flows and other runtime-specific needs.
EOF
  fi
  ralph_mode_prompt_guidance_stored_result_protocol \
    "ralph_proxy_result_read" \
    "ralph_proxy_result_search" \
    "ralph_proxy_result_summary"
  if [[ "$strict" == "1" ]]; then
    cat <<'EOF'
Strict proxy is active: do not fall back to native shell when Ralph shell tooling is required. If the first Ralph shell call fails, stop and write one structured request to `pending-human.txt` rather than probing with native `command_execution`. Native Read/Grep/Glob remain the primary exploration path.
EOF
  fi
  cat <<'EOF'
Native `Read`, `Edit`, and `Write` remain available for modifying files. When you intend to change a file, read it before editing and then use your host edit/write tools. Never tell the operator you lack edit access -- you have it.
EOF
}

ralph_mode_prompt_guidance_ralph() {
  local runtime="${1:-}"
  printf '%s\n\n' "## Ralph Mode (ralph)"
  ralph_mode_prompt_guidance_ralph_catalog "$runtime"
  if ralph_run_plan_plan_memory_enabled; then
    case "$runtime" in
      claude) ralph_mode_prompt_guidance_plan_memory "mcp__ralph__ralph_proxy_memory" ;;
      *) ralph_mode_prompt_guidance_plan_memory "ralph_proxy_memory" ;;
    esac
    printf '\n'
  fi
  ralph_mode_prompt_guidance_tool_batch_footer
  ralph_mode_prompt_guidance_common_footer
  # Non-strict ralph mode keeps native Read/Edit/Write available (only native
  # Bash/search are withheld), so tooling failures can partially cut over to
  # native tools. Strict proxy forbids any native fallback.
  if [[ "${RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY:-0}" == "1" ]] || [[ "${RALPH_STRICT_PROXY:-0}" == "1" ]]; then
    ralph_mode_prompt_guidance_ralph_failure_footer none
  else
    ralph_mode_prompt_guidance_ralph_failure_footer partial
  fi
}

ralph_mode_prompt_guidance_hybrid() {
  local runtime="${1:-}"
  printf '%s\n\n' "## Ralph Mode (hybrid)"
  case "$runtime" in
    codex)
      ralph_mode_prompt_guidance_ralph_catalog_codex "hybrid"
      ;;
    *)
      ralph_mode_prompt_guidance_ralph_catalog "$runtime"
      cat <<'EOF'

When Ralph tooling is slow, failing, or unsuitable for a given call, use native runtime tools freely, including native edit flows and other runtime-specific needs.
EOF
      ;;
  esac
  if ralph_run_plan_plan_memory_enabled; then
    case "$runtime" in
      claude) ralph_mode_prompt_guidance_plan_memory "mcp__ralph__ralph_proxy_memory" ;;
      *) ralph_mode_prompt_guidance_plan_memory "ralph_proxy_memory" ;;
    esac
    printf '\n'
  fi
  ralph_mode_prompt_guidance_tool_batch_footer
  ralph_mode_prompt_guidance_common_footer
  # Hybrid mode has native tools (read/search/shell/edit) fully available as a
  # fallback, so a tooling failure should cut over to native rather than pause.
  ralph_mode_prompt_guidance_ralph_failure_footer full
}

ralph_mode_prompt_guidance() {
  local runtime="${1:-}"
  local mode="${2:-no}"
  case "$mode" in
    native) ralph_mode_prompt_guidance_native "$runtime" ;;
    ralph) ralph_mode_prompt_guidance_ralph "$runtime" ;;
    hybrid) ralph_mode_prompt_guidance_hybrid "$runtime" ;;
    no|*) return 0 ;;
  esac
}

ralph_apply_mode_prompt_guidance() {
  local runtime="${1:-}"
  local mode="${2:-no}"
  if [[ "$mode" == "no" ]]; then
    return 0
  fi
  local guidance
  guidance="$(ralph_mode_prompt_guidance "$runtime" "$mode")"
  if [[ -z "$guidance" ]]; then
    return 0
  fi
  if [[ "$runtime" == "claude" ]]; then
    if [[ -n "${PROMPT_STATIC:-}" ]]; then
      PROMPT_STATIC="${PROMPT_STATIC}"$'\n\n'"${guidance}"
    else
      PROMPT+=$'\n\n'"${guidance}"
    fi

  else
    PROMPT+=$'\n\n'"${guidance}"
  fi
}

ralph_runtime_prompt_guidance() {
  local runtime="${1:-}"
  case "$runtime" in
    opencode)
      cat <<'EOF'
OpenCode runtime note:
- Non-interactive OpenCode runs can auto-reject reads outside the workspace as `external_directory`.
- If the TODO mentions optional reference files outside the workspace, treat them as best-effort context and continue with local workspace files when possible.
- If the task truly depends on an inaccessible external file, write one concise question to `pending-human.txt` instead of retrying the same denied path.
EOF
      ;;
  esac
}

ralph_apply_runtime_prompt_guidance() {
  local runtime="${1:-}"
  local guidance
  guidance="$(ralph_runtime_prompt_guidance "$runtime")"
  if [[ -z "$guidance" ]]; then
    return 0
  fi
  PROMPT+=$'\n\n'"${guidance}"
}

# Append why a resumed turn was interrupted, when the runner knows.
# A permission pause exits the CLI mid-task; the resumed session still holds the
# whole transcript, so say what happened rather than let the agent infer that it
# failed and start the TODO over.
ralph_run_plan_resume_intro_with_reason() {
  local intro="${1:-}"
  if [[ "${RALPH_CONTINUATION_ROUTE:-}" == "permission" ]]; then
    printf '%s\n' "${intro} The previous turn stopped on a permission request that the operator has now approved; continue from where it stopped and do not redo work you already completed."
    return 0
  fi
  printf '%s\n' "$intro"
}

# Agent completion instructions for per-TODO prompts (paragraph style for resume/reset/compact).
# Optional 4th arg: pass "1" to also request VERIFICATION STATUS / VERIFICATION_RESULT: PASS/FAIL from the agent.
ralph_run_plan_agent_completion_prompt_block() {
  local line_num="$1"
  local plan_path="$2"
  local pending_abs="$3"
  local request_verify_verdict="${4:-0}"
  if [[ "${RALPH_PLAN_AGENT_MARKS_TODOS:-0}" == "1" ]]; then
    cat <<EOF
Open \`${plan_path}\`, complete this TODO, change \`- [ ]\` to \`- [x]\` on that line, save, and stop. Prefer a structured completion footer on its own lines:

\`\`\`
TODO_COMPLETION: COMPLETE
TODO_VERIFICATION: PASS
\`\`\`

If verification was not needed, use \`TODO_VERIFICATION: SKIPPED\`. \`AGENT_INVOCATION_COMPLETE\` is still accepted for compatibility, but the runner reads the structured footer directly. Do not start the next item.

If no code or file change is needed because the TODO is already satisfied, say that explicitly before marking it done. Include the files or commands you checked and the reason no edit was necessary.

If you need operator input before finishing, write your question to \`${pending_abs}\` and stop without marking [x]. The runner will capture it as a structured human-request record. Do not print \`AGENT_INVOCATION_COMPLETE\` unless you completed and checked off the TODO.
EOF
  else
    cat <<EOF
After finishing the TODO, emit a structured completion footer on its own lines:

\`\`\`
TODO_COMPLETION: COMPLETE
TODO_VERIFICATION: PASS
\`\`\`

If verification was not needed, use \`TODO_VERIFICATION: SKIPPED\`. \`AGENT_INVOCATION_COMPLETE\` remains accepted for compatibility. If the runtime also supports \`mcp__ralph__ralph_complete_todo\`, you may call it as a compatibility fallback, but the runner does not depend on MCP for normal completion. Do not read or edit the plan file; the runner will mark this TODO complete from the completion signal.

If no code or file change is needed because the TODO is already satisfied, say that explicitly before calling the helper. Include the files or commands you checked and the reason no edit was necessary.

If verification fails, emit \`TODO_VERIFICATION: FAIL: <reason>\` so the runner reopens the TODO, or call the helper with \`outcome=needs_retry\` and \`verification_status=fail\` plus a short reason. If you need operator input before finishing, write your question to \`${pending_abs}\` and stop; the runner will write a structured human-request record and wait for the next invocation.
EOF
  fi
  if [[ "$request_verify_verdict" == "1" ]]; then
    cat <<EOF

Run each verification step listed for this TODO yourself now. When you report the result through the completion footer, use \`TODO_VERIFICATION: PASS\` if every step passes (also use pass if there were no steps or nothing required checking), \`TODO_VERIFICATION: FAIL: <reason>\` if any fail, or \`TODO_VERIFICATION: SKIPPED\` if verification was not needed. \`VERIFICATION_RESULT: PASS|FAIL\` and \`mcp__ralph__ralph_complete_todo\` are also accepted. Omitting a verification verdict or helper call reopens this TODO.
EOF
  fi
}

# Agent completion instructions for fresh per-TODO prompts (bullet style).
# Optional 3rd arg: pass "1" to also request VERIFICATION STATUS / VERIFICATION_RESULT: PASS/FAIL from the agent.
ralph_run_plan_fresh_completion_rules_block() {
  local line_num="$1"
  local pending_human="$2"
  local request_verify_verdict="${3:-0}"
  if [[ "${RALPH_PLAN_AGENT_MARKS_TODOS:-0}" == "1" ]]; then
    cat <<EOF
- When done, mark \`- [ ]\` on line ${line_num} as \`- [x]\` and stop.
- If no code or file change is needed because the TODO is already satisfied, say that explicitly before marking it done. Include the files or commands you checked and the reason no edit was necessary.
- After completing and checking off the TODO, print \`TODO_COMPLETION: COMPLETE\` on its own line. \`AGENT_INVOCATION_COMPLETE\` is still accepted for compatibility.
EOF
    if declare -F ralph_run_plan_operator_input_prompt_suffix >/dev/null 2>&1 \
      && ralph_run_plan_operator_input_prompt_suffix; then
      :
    else
      printf '%s\n' "- If operator input is needed first, write your question to \`${pending_human}\` and stop without marking [x]. The runner will capture it as a structured human-request record. Do not print \`AGENT_INVOCATION_COMPLETE\` unless you completed and checked off the TODO."
    fi
  else
    cat <<EOF
- After finishing the TODO, emit a structured completion footer on its own lines:

  \`\`\`
  TODO_COMPLETION: COMPLETE
  TODO_VERIFICATION: PASS
  \`\`\`

  If verification was not needed, use \`TODO_VERIFICATION: SKIPPED\`. \`AGENT_INVOCATION_COMPLETE\` and \`mcp__ralph__ralph_complete_todo\` remain accepted for compatibility, but the runner reads the structured footer directly.
- If no code or file change is needed because the TODO is already satisfied, say that explicitly before calling the helper. Include the files or commands you checked and the reason no edit was necessary.
- If verification fails, emit \`TODO_VERIFICATION: FAIL: <reason>\` so the runner reopens the TODO, or call the helper with \`outcome=needs_retry\` and \`verification_status=fail\` plus a short reason. The completion helper is also accepted.
EOF
    if declare -F ralph_run_plan_operator_input_prompt_suffix >/dev/null 2>&1 \
      && ralph_run_plan_operator_input_prompt_suffix; then
      :
    else
      printf '%s\n' "- If operator input is needed first, write your question to \`${pending_human}\` and stop without calling the helper. The runner will capture it as a structured human-request record."
    fi
  fi
  if [[ "$request_verify_verdict" == "1" ]]; then
    printf '%s\n' "- Run each verification step listed for this TODO yourself now. When you report the result, use \`TODO_VERIFICATION: PASS\` if every step passes (also use pass if there were no steps or nothing required checking), \`TODO_VERIFICATION: FAIL: <reason>\` if any fail, or \`TODO_VERIFICATION: SKIPPED\` if verification was not needed. \`VERIFICATION_RESULT: PASS|FAIL\` and \`mcp__ralph__ralph_complete_todo\` are also accepted. Omitting a verification verdict reopens this TODO."
  fi
}

# ralph_run_plan_workflow_operator_input_active
# True when this plan invocation is under a workflow-owned ordinary stage.
ralph_run_plan_workflow_operator_input_active() {
  if declare -F ralph_workflow_active_for_operator_input >/dev/null 2>&1; then
    ralph_workflow_active_for_operator_input
    return $?
  fi
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -d "${RALPH_WORKFLOW_REGISTRY_RUN}" \
    && -n "${RALPH_WORKFLOW_RUN_ID:-}" \
    && -n "${RALPH_WORKFLOW_STAGE_ID:-}" \
    && -n "${RALPH_WORKFLOW_STAGE_ATTEMPT:-}" ]]
}

# ralph_run_plan_ensure_workflow_actions_lib
# Lazily source workflow-actions helpers when workflow identity is present.
ralph_run_plan_ensure_workflow_actions_lib() {
  declare -F workflow_action_prepare_attempt_capability_env >/dev/null 2>&1 && return 0
  local lib="${SCRIPT_DIR}/bash-lib/workflow/workflow-actions.sh"
  [[ -f "$lib" ]] || return 1
  # shellcheck source=/dev/null
  source "$lib"
}

# ralph_run_plan_prepare_workflow_operator_input
# Mint/export attempt-bound capability + resolve optional response injection path
# for this TODO. Prints nothing that contains a nonce. Returns 0 when inactive.
ralph_run_plan_prepare_workflow_operator_input() {
  local todo_id="${1:-}" cap_path pending_rid
  unset RALPH_WORKFLOW_OPERATOR_INPUT_RESPONSE_FILE 2>/dev/null || true
  ralph_run_plan_workflow_operator_input_active || return 0
  ralph_run_plan_ensure_workflow_actions_lib || {
    ralph_run_plan_log "ERROR: workflow actions library missing for operator-input capability"
    return 1
  }
  cap_path="$(workflow_action_prepare_attempt_capability_env \
    --registry-run "$RALPH_WORKFLOW_REGISTRY_RUN" \
    --run-id "$RALPH_WORKFLOW_RUN_ID" \
    --stage-id "$RALPH_WORKFLOW_STAGE_ID" \
    --attempt-id "$RALPH_WORKFLOW_STAGE_ATTEMPT")" || return 1
  # Resolve answered-unconsumed injection for this TODO only (no nonce in logs).
  pending_rid="$(workflow_action_find_pending_input_request_id \
    "$RALPH_WORKFLOW_REGISTRY_RUN" "$RALPH_WORKFLOW_RUN_ID" \
    "$RALPH_WORKFLOW_STAGE_ID" "$RALPH_WORKFLOW_STAGE_ATTEMPT" 2>/dev/null || true)"
  if [[ -n "$pending_rid" ]]; then
    local decision inj
    decision="$(workflow_action_decision_read "$RALPH_WORKFLOW_REGISTRY_RUN" "$pending_rid" 2>/dev/null || true)"
    if [[ -n "$decision" && "$(printf '%s' "$decision" | jq -r '.decision // empty')" == "answer" ]]; then
      inj="$(workflow_action_injection_path "$RALPH_WORKFLOW_REGISTRY_RUN" "$pending_rid" 2>/dev/null || true)"
      if [[ -z "$inj" || ! -f "$inj" ]]; then
        inj="$(workflow_action_stage_input_injection "$RALPH_WORKFLOW_REGISTRY_RUN" "$pending_rid" \
          ${todo_id:+--todo-id "$todo_id"} 2>/dev/null || true)"
      fi
      if [[ -n "$inj" && -f "$inj" ]]; then
        export RALPH_WORKFLOW_OPERATOR_INPUT_RESPONSE_FILE="$inj"
      fi
    fi
  fi
  ralph_run_plan_log "workflow operator-input capability ready path=$(basename "$cap_path") stage=${RALPH_WORKFLOW_STAGE_ID} attempt=${RALPH_WORKFLOW_STAGE_ATTEMPT}"
  return 0
}

# ralph_run_plan_operator_input_prompt_suffix
# Text that replaces pending-human guidance when workflow operator-input is active.
ralph_run_plan_operator_input_prompt_suffix() {
  if ralph_run_plan_workflow_operator_input_active; then
    cat <<'EOF'
- If operator input is needed first, call `ralph workflow actions request --question <text> [--details <text>]`, stop without marking [x], and do not guess. Do not write pending-human.txt for product/credential/external decisions under an active workflow run.
EOF
    return 0
  fi
  return 1
}

# ralph_run_plan_revoke_workflow_operator_input_capability
ralph_run_plan_revoke_workflow_operator_input_capability() {
  ralph_run_plan_workflow_operator_input_active || return 0
  ralph_run_plan_ensure_workflow_actions_lib || return 0
  workflow_action_revoke_attempt_capability \
    "$RALPH_WORKFLOW_REGISTRY_RUN" \
    "$RALPH_WORKFLOW_RUN_ID" \
    "$RALPH_WORKFLOW_STAGE_ID" \
    "$RALPH_WORKFLOW_STAGE_ATTEMPT" 2>/dev/null || true
  workflow_action_clear_attempt_capability_env 2>/dev/null || true
  unset RALPH_WORKFLOW_OPERATOR_INPUT_RESPONSE_FILE 2>/dev/null || true
}

# ralph_run_plan_gate_workflow_operator_input_after_turn <plan-path> <plan-format> <todo-target> <line-num>
# After a model turn, refuse checkbox/stage success when this attempt has
# outstanding or answered-unconsumed input. Persists progress, revokes
# capability, tears down runtime overlays, and exits 3 (waiting).
ralph_run_plan_gate_workflow_operator_input_after_turn() {
  local plan_path="${1:-}" plan_format="${2:-}" todo_target="${3:-}" line_num="${4:-}"
  local pending_rid blocker
  ralph_run_plan_workflow_operator_input_active || return 0
  ralph_run_plan_ensure_workflow_actions_lib || return 0
  if ! workflow_action_attempt_blocks_success \
      "$RALPH_WORKFLOW_REGISTRY_RUN" "$RALPH_WORKFLOW_RUN_ID" \
      "$RALPH_WORKFLOW_STAGE_ID" "$RALPH_WORKFLOW_STAGE_ATTEMPT"; then
    return 0
  fi

  # Keep the TODO unchecked / reopen if the agent checked it.
  if [[ -n "$plan_path" && -n "$todo_target" ]] && declare -F plan_reopen_todo_by_format >/dev/null 2>&1; then
    plan_reopen_todo_by_format "$plan_path" "$plan_format" "$todo_target" 2>/dev/null || true
  fi

  pending_rid="$(workflow_action_find_pending_input_request_id \
    "$RALPH_WORKFLOW_REGISTRY_RUN" "$RALPH_WORKFLOW_RUN_ID" \
    "$RALPH_WORKFLOW_STAGE_ID" "$RALPH_WORKFLOW_STAGE_ATTEMPT" 2>/dev/null || true)"
  if [[ -n "$pending_rid" ]] && declare -F workflow_action_input_blocker_json >/dev/null 2>&1; then
    blocker="$(workflow_action_input_blocker_json \
      --request-id "$pending_rid" --run-id "$RALPH_WORKFLOW_RUN_ID" --retryable false 2>/dev/null || true)"
    if [[ -n "$blocker" ]]; then
      export RALPH_WORKFLOW_STAGE_BLOCKER_JSON="$blocker"
    fi
  fi

  ralph_run_plan_log "operator-input outstanding or answered-unconsumed; refusing completion and waiting (exit 3) line=${line_num:-unknown} request=${pending_rid:-unknown}"
  if declare -F workflow_action_continuation_persist_on_wait >/dev/null 2>&1; then
    workflow_action_continuation_persist_on_wait "$plan_path" "${RALPH_CURRENT_TODO_ID:-}" >/dev/null 2>&1 || true
  fi
  ralph_run_plan_revoke_workflow_operator_input_capability
  if declare -F ralph_runtime_overlay_cleanup_if_needed >/dev/null 2>&1; then
    ralph_runtime_overlay_cleanup_if_needed
  fi
  exit 3
}

# Stable per-plan namespace block for PROMPT_STATIC (no TODO text, timestamps, or temp paths).
#
# G12: delegates to the one prompt-helper owner, ralph_artifact_namespace_prompt_block
# (bash-lib/run-plan/run-plan-artifacts.sh), which also names any
# orchestrator-declared required artifact's resolved absolute destination
# (RALPH_REQUIRED_ARTIFACT_PATHS_JSON) and states plainly that those are
# supervisor outputs, not source edits. Falls back to the original bare
# namespace line only if that helper is unavailable for any reason.
ralph_run_plan_namespace_prompt_block() {
  if [[ -z "${RALPH_ARTIFACT_NS:-}" && -z "${RALPH_PLAN_KEY:-}" ]]; then
    return 0
  fi
  if declare -F ralph_artifact_namespace_prompt_block >/dev/null 2>&1; then
    ralph_artifact_namespace_prompt_block
    printf '\n'
    return 0
  fi
  printf '%s\n' "Artifact namespace: RALPH_ARTIFACT_NS=${RALPH_ARTIFACT_NS:-}  RALPH_PLAN_KEY=${RALPH_PLAN_KEY:-}"
  printf '%s\n' "Use namespace-aware artifact paths when writing handoff files."
}

# Join non-empty prompt parts with a blank line between each.
# Order is caller-defined; empty parts are omitted (no extra separators).
ralph_run_plan_join_prompt_parts() {
  local out=""
  local part
  for part in "$@"; do
    [[ -n "$part" ]] || continue
    if [[ -n "$out" ]]; then
      out+=$'\n\n'
    fi
    out+="$part"
  done
  printf '%s' "$out"
}

# Assemble the common prompt layers in contract order for every runtime:
#   preamble, contracts, task.
# Workflow stage instructions (when present) are already part of the task body,
# injected immediately before TODO content by the caller.
ralph_run_plan_assemble_prompt_ordered() {
  local preamble="${1:-}"
  local contracts="${2:-}"
  local task="${3:-}"
  ralph_run_plan_join_prompt_parts "$preamble" "$contracts" "$task"
}

# Assemble the stable prefix (PROMPT_STATIC): contracts (namespace) only.
# Profile/agent context is no longer included here (module retained, unused).
ralph_run_plan_assemble_prompt_static() {
  local ns_block="${1:-}"
  ralph_run_plan_assemble_prompt_ordered "" "$ns_block" ""
}

# Rebuild the stable prefix for resumed turns. Keep this in sync with the
# fresh-turn assembly below: runtime/mode guidance and the namespace contract
# are stable, while TODO and continuation details belong in PROMPT.
ralph_run_plan_rebuild_prompt_static() {
  local ns_block preamble mode_guidance
  ns_block="$(ralph_run_plan_namespace_prompt_block)"
  preamble="$(ralph_runtime_prompt_guidance "$RUNTIME")"
  mode_guidance=""
  if [[ "${RALPH_MODE:-no}" != "no" ]]; then
    mode_guidance="$(ralph_mode_prompt_guidance "$RUNTIME" "${RALPH_MODE:-no}")"
  fi
  if [[ -n "$preamble" && -n "$mode_guidance" ]]; then
    preamble="${preamble}"$'\n\n'"${mode_guidance}"
  elif [[ -n "$mode_guidance" ]]; then
    preamble="$mode_guidance"
  fi
  ralph_run_plan_assemble_prompt_ordered "$preamble" "$ns_block" ""
}

# Apply common prompt assembly at the shared boundary.
# Sets PROMPT / PROMPT_STATIC so delivered order is preamble, contracts, task
# for every runtime (Claude keeps the stable prefix in --system-prompt).
# Operates on the global PROMPT (task body already built by the caller).
ralph_run_plan_apply_ordered_prompt_assembly() {
  local runtime="${1:-}"
  local preamble="${2:-}"
  local contracts="${3:-}"
  local task="${PROMPT:-}"

  PROMPT_STATIC="$(ralph_run_plan_assemble_prompt_ordered "$preamble" "$contracts" "")"
  if [[ "$runtime" == "claude" ]]; then
    PROMPT="$task"
  else
    # Non-Claude CLIs get one fully ordered prompt; do not use stable-last merge.
    PROMPT="$(ralph_run_plan_assemble_prompt_ordered "$preamble" "$contracts" "$task")"
  fi
}

# Deterministic short fingerprint of the stable prefix for telemetry. Never logs
# the prompt contents; only a hash and the byte count are emitted.
ralph_run_plan_stable_prefix_fingerprint() {
  local text="${1:-}"
  [[ -z "$text" ]] && { printf '%s' ""; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | cut -c1-16
  else
    printf '%s' ""
  fi
}

# Rollout gate for between-TODO continuation summaries.
# Ralph/hybrid mode enables it unless RALPH_CONTINUATION_SUMMARY=0.
# Native/no mode leaves it disabled unless RALPH_CONTINUATION_SUMMARY=1.
ralph_run_plan_continuation_summary_enabled() {
  local gate="${RALPH_CONTINUATION_SUMMARY:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "RALPH_CONTINUATION_SUMMARY: invalid value '$gate' (use 0 or 1)"
        fi
        echo "RALPH_CONTINUATION_SUMMARY: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

# Rollout gate for per-plan MCP memory store.
# Ralph/hybrid mode enables it unless RALPH_PLAN_MEMORY=0.
# Native/no mode leaves it disabled unless RALPH_PLAN_MEMORY=1.
ralph_run_plan_plan_memory_enabled() {
  local gate="${RALPH_PLAN_MEMORY:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "RALPH_PLAN_MEMORY: invalid value '$gate' (use 0 or 1)"
        fi
        echo "RALPH_PLAN_MEMORY: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

# Rollout gate for progressive rule/skill disclosure.
# Ralph/hybrid mode enables it unless RALPH_PROGRESSIVE_CONTEXT=0.
# Native/no mode leaves it disabled unless RALPH_PROGRESSIVE_CONTEXT=1.
ralph_run_plan_progressive_context_enabled() {
  local gate="${RALPH_PROGRESSIVE_CONTEXT:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "RALPH_PROGRESSIVE_CONTEXT: invalid value '$gate' (use 0 or 1)"
        fi
        echo "RALPH_PROGRESSIVE_CONTEXT: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_run_plan_continuation_summary_state_path() {
  printf '%s/continuation-summary.json' "${RALPH_SESSION_DIR:-}"
}

ralph_run_plan_continuation_summary_py() {
  printf '%s/python/continuation_summary.py' "${SCRIPT_DIR:-}"
}

ralph_run_plan_continuation_summary_sync_plan() {
  local py state_path
  if ! ralph_run_plan_continuation_summary_enabled; then
    return 0
  fi
  py="$(ralph_run_plan_continuation_summary_py)"
  state_path="$(ralph_run_plan_continuation_summary_state_path)"
  [[ -f "$py" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$py" check-plan \
      --state "$state_path" \
      --plan-path "$PLAN_PATH" \
      --plan-key "${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}" \
      --write >/dev/null 2>&1 || true
}

ralph_run_plan_continuation_summary_fetch_block() {
  local py state_path block
  if ! ralph_run_plan_continuation_summary_enabled; then
    return 1
  fi
  py="$(ralph_run_plan_continuation_summary_py)"
  state_path="$(ralph_run_plan_continuation_summary_state_path)"
  [[ -f "$py" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  block="$(PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$py" render --state "$state_path" 2>/dev/null)" || return 1
  [[ -n "$block" ]] || return 1
  printf '%s' "$block"
}

ralph_run_plan_continuation_summary_refresh_metrics() {
  local py state_path metrics_json
  RALPH_CONTINUATION_SUMMARY_BYTES=0
  RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT=0
  RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT=0
  if ! ralph_run_plan_continuation_summary_enabled; then
    export RALPH_CONTINUATION_SUMMARY_BYTES RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT
    return 0
  fi
  py="$(ralph_run_plan_continuation_summary_py)"
  state_path="$(ralph_run_plan_continuation_summary_state_path)"
  [[ -f "$py" ]] || {
    export RALPH_CONTINUATION_SUMMARY_BYTES RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT
    return 0
  }
  command -v python3 >/dev/null 2>&1 || {
    export RALPH_CONTINUATION_SUMMARY_BYTES RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT
    return 0
  }
  metrics_json="$(PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$py" metrics --state "$state_path" 2>/dev/null)" || metrics_json=""
  if [[ -n "$metrics_json" ]]; then
    # One interpreter start for all three counters.
    _cont_fields="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
keys = ('continuation_summary_bytes', 'continuation_summary_entry_count',
        'continuation_summary_truncation_count')
print('\\x1f'.join(str(d.get(k, 0)) for k in keys))
" "$metrics_json" 2>/dev/null || printf '0\x1f0\x1f0')"
    IFS=$'\x1f' read -r RALPH_CONTINUATION_SUMMARY_BYTES RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT \
      RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT <<<"$_cont_fields"
    : "${RALPH_CONTINUATION_SUMMARY_BYTES:=0}" "${RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT:=0}"
    : "${RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT:=0}"
  fi
  export RALPH_CONTINUATION_SUMMARY_BYTES RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT
}

ralph_run_plan_continuation_summary_inject() {
  local block
  block="$(ralph_run_plan_continuation_summary_fetch_block 2>/dev/null || true)"
  [[ -n "$block" ]] || return 0
  PROMPT="${block}"$'\n\n'"${PROMPT}"
}

ralph_run_plan_continuation_summary_collect_output_artifacts() {
  local plan_path="$1"
  local todo_target="$2"
  local -a paths=()
  local required_flag raw_path resolved_path abs_path
  if ! declare -F ralph_run_plan_pipeline_artifact_entries >/dev/null 2>&1; then
    return 0
  fi
  while IFS=$'\t' read -r required_flag raw_path || [[ -n "$raw_path" ]]; do
    [[ -n "$raw_path" ]] || continue
    resolved_path="$(expand_artifact_tokens "$raw_path")"
    abs_path="$(ralph_run_plan_artifact_abs_path "$resolved_path")"
    if [[ -f "$abs_path" && -s "$abs_path" ]]; then
      paths+=("$resolved_path")
    elif [[ "$required_flag" == "1" ]]; then
      paths+=("$resolved_path")
    fi
  done < <(ralph_run_plan_pipeline_artifact_entries "$plan_path" "$todo_target" "produces" 2>/dev/null || true)
  ((${#paths[@]} == 0)) && return 0
  printf '%s\n' "${paths[@]}"
}

ralph_run_plan_continuation_summary_record_error() {
  local todo_line="$1"
  local error_text="$2"
  local error_source="${3:-verification}"
  local py state_path payload_file tmpdir
  if ! ralph_run_plan_continuation_summary_enabled; then
    return 0
  fi
  [[ -n "$error_text" ]] || return 0
  py="$(ralph_run_plan_continuation_summary_py)"
  state_path="$(ralph_run_plan_continuation_summary_state_path)"
  [[ -f "$py" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  tmpdir="$(mktemp -d "${RALPH_SESSION_DIR:-/tmp}/.ralph-cont-sum.XXXXXX")" || return 0
  payload_file="$tmpdir/update.json"
  jq -n \
    --arg plan_key "${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}" \
    --arg plan_path "$PLAN_PATH" \
    --argjson todo_line "$todo_line" \
    --arg text "$error_text" \
    --arg source "$error_source" \
    '{
      plan_key: $plan_key,
      plan_path: $plan_path,
      record_error: {todo_line: $todo_line, text: $text, source: $source}
    }' >"$payload_file"
  PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$py" update --state "$state_path" --input "$payload_file" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}

ralph_run_plan_continuation_summary_record_completion() {
  local todo_line="$1"
  local todo_ordinal="$2"
  local todo_id="$3"
  local todo_hash="$4"
  local todo_text="$5"
  local completion_summary="$6"
  local verify_status="$7"
  local verify_reason="$8"
  local verify_artifact="$9"
  local next_line="${10:-0}"
  local next_ordinal="${11:-0}"
  local next_id="${12:-}"
  local next_text="${13:-}"
  local py state_path tmpdir
  if ! ralph_run_plan_continuation_summary_enabled; then
    return 0
  fi
  py="$(ralph_run_plan_continuation_summary_py)"
  state_path="$(ralph_run_plan_continuation_summary_state_path)"
  [[ -f "$py" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  tmpdir="$(mktemp -d "${RALPH_SESSION_DIR:-/tmp}/.ralph-cont-sum.XXXXXX")" || return 0
  printf '%s' "$todo_text" >"$tmpdir/todo.txt"
  printf '%s' "$completion_summary" >"$tmpdir/summary.txt"
  printf '%s' "$next_text" >"$tmpdir/next.txt"
  ralph_run_plan_continuation_summary_collect_output_artifacts "$PLAN_PATH" "$todo_target" >"$tmpdir/artifacts.txt" 2>/dev/null || : >"$tmpdir/artifacts.txt"
  PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    PLAN_KEY="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}" \
    PLAN_PATH="$PLAN_PATH" \
    SESSION_DIR="${RALPH_SESSION_DIR:-}" \
    TODO_LINE="$todo_line" \
    TODO_ORDINAL="$todo_ordinal" \
    TODO_ID="${todo_id:-}" \
    TODO_HASH="${todo_hash:-}" \
    STAGE_ID="${RALPH_STAGE_ID:-}" \
    VERIFY_STATUS="${verify_status:-none}" \
    VERIFY_REASON="${verify_reason:-}" \
    VERIFY_ARTIFACT="${verify_artifact:-}" \
    NEXT_LINE="$next_line" \
    NEXT_ORDINAL="$next_ordinal" \
    NEXT_ID="${next_id:-}" \
    python3 - "$py" "$state_path" "$tmpdir" <<'PY'
import json
import os
import pathlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[1])))
import continuation_summary as cs

py_path, state_path, tmpdir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
artifacts = [line for line in (tmpdir / "artifacts.txt").read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
human = cs.load_human_decision(os.environ.get("SESSION_DIR", ""), int(os.environ.get("TODO_LINE", "0") or 0))
payload = {
    "plan_key": os.environ.get("PLAN_KEY", ""),
    "plan_path": os.environ.get("PLAN_PATH", ""),
    "completed_todo": {
        "id": os.environ.get("TODO_ID", ""),
        "ordinal": int(os.environ.get("TODO_ORDINAL", "0") or 0),
        "line": int(os.environ.get("TODO_LINE", "0") or 0),
        "hash": os.environ.get("TODO_HASH", ""),
        "content": (tmpdir / "todo.txt").read_text(encoding="utf-8", errors="replace"),
        "completion_summary": (tmpdir / "summary.txt").read_text(encoding="utf-8", errors="replace").strip(),
        **({"stage_id": os.environ.get("STAGE_ID", "")} if os.environ.get("STAGE_ID", "").strip() else {}),
    },
    "verification": {
        "status": os.environ.get("VERIFY_STATUS", "none"),
        "reason": os.environ.get("VERIFY_REASON", ""),
        "artifact_path": os.environ.get("VERIFY_ARTIFACT", ""),
    },
    "output_artifacts": artifacts,
}
if human:
    payload["human_decision"] = human
next_line = int(os.environ.get("NEXT_LINE", "0") or 0)
if next_line > 0:
    payload["next_todo"] = {
        "line": next_line,
        "ordinal": int(os.environ.get("NEXT_ORDINAL", "0") or 0),
        "id": os.environ.get("NEXT_ID", ""),
        "content": (tmpdir / "next.txt").read_text(encoding="utf-8", errors="replace"),
    }
input_path = tmpdir / "update.json"
input_path.write_text(json.dumps(payload), encoding="utf-8")
cs.update_state(state_path, payload, enabled=True)
PY
  rm -rf "$tmpdir"
}

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/usage-risk-ack.sh"
ralph_require_usage_risk_acknowledgment
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-cli-helpers.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-routing.sh"
# shellcheck source=/dev/null
if ! declare -F expand_artifact_tokens >/dev/null 2>&1; then
  source "$SCRIPT_DIR/bash-lib/artifacts.sh"
fi
# G12: the artifact namespace prompt helper (ralph_artifact_namespace_prompt_block)
# is the one owner of the artifact-namespace prompt block, including naming
# any orchestrator-declared required artifact's resolved absolute
# destination. ralph_run_plan_namespace_prompt_block below delegates to it.
# shellcheck source=/dev/null
if ! declare -F ralph_artifact_namespace_prompt_block >/dev/null 2>&1; then
  source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-artifacts.sh"
fi

ralph_parse_duration() {
  local duration_str="${1:-}"
  if [[ -z "$duration_str" ]]; then
    echo "Error: duration string is empty" >&2
    return 1
  fi

  local num unit seconds

  if [[ "$duration_str" =~ ^([0-9]+)(s|m|h)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    echo "Error: invalid duration format '$duration_str' (expected e.g. 30s, 5m, 2h)" >&2
    return 1
  fi

  if [[ "$num" -le 0 ]]; then
    echo "Error: duration must be positive (got '$duration_str')" >&2
    return 1
  fi

  case "$unit" in
    s) seconds="$num" ;;
    m) seconds=$((num * 60)) ;;
    h) seconds=$((num * 3600)) ;;
  esac

  echo "$seconds"
}

ralph_resolve_timeout() {
  local raw_timeout="${RALPH_PLAN_INVOCATION_TIMEOUT_RAW:-}"
  local timeout_seconds

  if [[ -n "$raw_timeout" ]]; then
    if ! timeout_seconds="$(ralph_parse_duration "$raw_timeout")"; then
      return 1
    fi
  else
    if ! timeout_seconds="$(ralph_parse_duration "30m")"; then
      return 1
    fi
  fi

  echo "$timeout_seconds"
}

run_plan_mark_and_confirm() {
  local plan_path="$1"
  local plan_format="$2"
  local todo_target="$3"
  local expected_first_field="$4"
  local next_after next_first_field

  if ! plan_mark_todo_done_by_format "$plan_path" "$plan_format" "$todo_target"; then
    if next_after=$(get_next_todo "$plan_path"); then
      next_first_field="${next_after%%|*}"
      if [[ "$next_first_field" == "$expected_first_field" ]]; then
        return 5
      fi
    fi
    return 1
  fi

  if ! next_after=$(get_next_todo "$plan_path"); then
    return 0
  fi

  next_first_field="${next_after%%|*}"
  if [[ "$next_first_field" == "$expected_first_field" ]]; then
    return 5
  fi

  return 0
}

# Graph mutating nodes provide a scheduler-owned baseline and scope policy.
# Validate the workspace before a TODO checkbox can advance, so an out-of-scope
# edit cannot be hidden by a later correction or a successful node exit.
ralph_graph_write_scope_verify_todo() {
  local todo_key="$1" safe_key output
  [[ -n "${RALPH_GRAPH_CHANGESET_BASELINE:-}" ]] || return 0
  [[ -n "${RALPH_GRAPH_CHANGESET_HELPER:-}" && -f "$RALPH_GRAPH_CHANGESET_HELPER" ]] || {
    ralph_run_plan_log "ERROR: graph changeset helper missing"
    return 1
  }
  safe_key="$(printf '%s' "$todo_key" | sed 's/[^A-Za-z0-9._-]/_/g')"
  output="$RALPH_PLAN_WORKSPACE_ROOT/artifacts/${RALPH_ARTIFACT_NS:-graph}/changeset-checkpoints/${RALPH_GRAPH_NODE_ID}/${RALPH_GRAPH_ATTEMPT_ID}/${safe_key}.json"
  if ! output="$(python3 "$RALPH_GRAPH_CHANGESET_HELPER" capture \
    --workspace "${RALPH_AGENT_WORKSPACE:-$WORKSPACE}" \
    --baseline "$RALPH_GRAPH_CHANGESET_BASELINE" \
    --output "$output" \
    --node-id "$RALPH_GRAPH_NODE_ID" \
    --attempt-id "$RALPH_GRAPH_ATTEMPT_ID" \
    --workspace-mode "$RALPH_GRAPH_WORKSPACE_MODE" \
    --base-identity "$RALPH_GRAPH_BASE_IDENTITY" \
    --write-scopes-json "$RALPH_GRAPH_WRITE_SCOPES_JSON" 2>&1)"; then
      output="${output//$'\n'/; }"
      if [[ "${#output}" -gt 2000 ]]; then
        output="${output:0:2000}..."
      fi
      ralph_run_plan_log "ERROR: graph write-scope verification failed before TODO completion: $todo_key${output:+; $output}"
      return 1
  fi
}

ralph_run_plan_artifact_abs_path() {
  local artifact_path="$1"
  if [[ "$artifact_path" == /* ]]; then
    printf '%s' "$artifact_path"
  else
    printf '%s/%s' "$WORKSPACE" "$artifact_path"
  fi
}

ralph_run_plan_pipeline_artifact_entries() {
  local plan_path="$1"
  local todo_target="$2"
  local artifact_field="$3"
  local raw_json
  raw_json="$(plan_pipeline_effective_metadata_json "$plan_path" "$todo_target")" || return 1
  python3 - "$artifact_field" "$raw_json" <<'PY'
import json
import sys

field = sys.argv[1]
data = json.loads(sys.argv[2])
entries = data.get(field, []) or []
seen = {}
for item in entries:
    path = str(item.get("path", ""))
    if not path:
        continue
    required = bool(item.get("required", True))
    if path in seen:
        if required:
            seen[path] = True
        continue
    seen[path] = required
for path, required in seen.items():
    print(f"{1 if required else 0}\t{path}")
PY
}

ralph_run_plan_seed_yaml_bootstrap_context() {
  local plan_path="$1"
  local plan_format next line_num todo_id todo_target _seed_next_rest
  local eff_stage="" eff_runtime="" eff_model=""
  local eff_session_strategy="" eff_context_budget="" eff_subagents="inherit" eff_plan_file=""

  plan_format="$(plan_detect_format "$plan_path" 2>/dev/null || printf 'default')"
  if ! plan_format_is_yaml "$plan_format"; then
    return 0
  fi
  if ! plan_pipeline_has_metadata "$plan_path" \
     && ! plan_pipeline_any_todo_has_routing "$plan_path"; then
    return 0
  fi

  next="$(get_next_todo "$plan_path" 2>/dev/null || true)"
  [[ -n "$next" ]] || return 0

  line_num="${next%%|*}"
  todo_id=""
  todo_target="$line_num"
  _seed_next_rest="${next#*|}"
  todo_id="${_seed_next_rest%%|*}"
  todo_target="${todo_id:-$line_num}"

  if ! IFS=$'\x1f' read -r eff_stage eff_runtime eff_model eff_session_strategy eff_context_budget eff_subagents eff_plan_file <<< "$(
    ralph_run_plan_routing_effective_metadata_fields "$plan_path" "$todo_target"
  )"; then
    return 1
  fi

  if [[ -z "${RUNTIME:-}" && -n "$eff_runtime" ]]; then
    RUNTIME="$eff_runtime"
  fi
  if [[ -z "${PLAN_MODEL_CLI:-}" && -n "$eff_model" ]]; then
    PLAN_MODEL_CLI="$eff_model"
  fi
  RALPH_PLAN_SUBAGENTS="$eff_subagents"
  export RALPH_PLAN_SUBAGENTS
}

ralph_run_plan_pipeline_input_artifacts_prepare() {
  local plan_path="$1"
  local todo_target="$2"
  local line_num="$3"
  local -a artifact_paths=()
  local -a artifact_required_flags=()
  local -a surfaced_paths=()
  local -a missing_required_paths=()
  local -a missing_optional_paths=()
  local required_flag raw_path resolved_path abs_path found_index idx surfaced_log

  RALPH_RUN_PLAN_INPUT_ARTIFACT_PATHS=()
  RALPH_RUN_PLAN_INPUT_ARTIFACT_SECTION=""

  while IFS=$'\t' read -r required_flag raw_path || [[ -n "$raw_path" ]]; do
    [[ -n "$raw_path" ]] || continue
    resolved_path="$(expand_artifact_tokens "$raw_path")"
    found_index=""
    for idx in "${!artifact_paths[@]}"; do
      if [[ "${artifact_paths[$idx]}" == "$resolved_path" ]]; then
        found_index="$idx"
        break
      fi
    done
    if [[ -n "$found_index" ]]; then
      [[ "$required_flag" == "1" ]] && artifact_required_flags[$found_index]=1
    else
      artifact_paths+=("$resolved_path")
      artifact_required_flags+=("$required_flag")
    fi
  done < <(ralph_run_plan_pipeline_artifact_entries "$plan_path" "$todo_target" "requires")

  for idx in "${!artifact_paths[@]}"; do
    resolved_path="${artifact_paths[$idx]}"
    required_flag="${artifact_required_flags[$idx]}"
    abs_path="$(ralph_run_plan_artifact_abs_path "$resolved_path")"
    if [[ "$required_flag" == "1" ]]; then
      if [[ -e "$abs_path" ]]; then
        surfaced_paths+=("$resolved_path")
      else
        missing_required_paths+=("$resolved_path")
      fi
    else
      if [[ -e "$abs_path" ]]; then
        surfaced_paths+=("$resolved_path")
      else
        missing_optional_paths+=("$resolved_path")
      fi
    fi
  done

  if ((${#missing_required_paths[@]} > 0)); then
    ralph_run_plan_log "FAIL line=$line_num missing required input artifacts: $(printf '%s ' "${missing_required_paths[@]}")"
    echo -e "${C_R}${C_BOLD}Missing required input artifact(s) for TODO line $line_num:${C_RST}" >&2
    for resolved_path in "${missing_required_paths[@]}"; do
      abs_path="$(ralph_run_plan_artifact_abs_path "$resolved_path")"
      echo "  $resolved_path (resolved: $abs_path)" >&2
    done
    return 1
  fi

  for resolved_path in "${missing_optional_paths[@]}"; do
    ralph_run_plan_log "optional input artifact missing line=$line_num path=$resolved_path"
  done

  RALPH_RUN_PLAN_INPUT_ARTIFACT_PATHS=("${surfaced_paths[@]}")
  if ((${#surfaced_paths[@]} > 0)); then
    RALPH_RUN_PLAN_INPUT_ARTIFACT_SECTION=$'Input artifacts'
    for resolved_path in "${surfaced_paths[@]}"; do
      RALPH_RUN_PLAN_INPUT_ARTIFACT_SECTION+=$'\n'"- $resolved_path"
    done
  fi

  surfaced_log=""
  for resolved_path in "${surfaced_paths[@]}"; do
    if [[ -n "$surfaced_log" ]]; then
      surfaced_log+=", "
    fi
    surfaced_log+="$resolved_path"
  done
  ralph_run_plan_log "input artifacts surfaced line=$line_num: ${surfaced_log:-none}"
}

ralph_run_plan_pipeline_output_artifacts_verify() {
  local plan_path="$1"
  local todo_target="$2"
  local line_num="$3"
  local -a artifact_paths=()
  local -a artifact_required_flags=()
  local -a missing_required_paths=()
  local -a present_optional_paths=()
  local required_flag raw_path resolved_path abs_path found_index idx failure_log

  while IFS=$'\t' read -r required_flag raw_path || [[ -n "$raw_path" ]]; do
    [[ -n "$raw_path" ]] || continue
    resolved_path="$(expand_artifact_tokens "$raw_path")"
    found_index=""
    for idx in "${!artifact_paths[@]}"; do
      if [[ "${artifact_paths[$idx]}" == "$resolved_path" ]]; then
        found_index="$idx"
        break
      fi
    done
    if [[ -n "$found_index" ]]; then
      [[ "$required_flag" == "1" ]] && artifact_required_flags[$found_index]=1
    else
      artifact_paths+=("$resolved_path")
      artifact_required_flags+=("$required_flag")
    fi
  done < <(ralph_run_plan_pipeline_artifact_entries "$plan_path" "$todo_target" "produces")

  for idx in "${!artifact_paths[@]}"; do
    resolved_path="${artifact_paths[$idx]}"
    required_flag="${artifact_required_flags[$idx]}"
    abs_path="$(ralph_run_plan_artifact_abs_path "$resolved_path")"
    if [[ "$required_flag" == "1" ]]; then
      if [[ ! -f "$abs_path" ]]; then
        missing_required_paths+=("$resolved_path|missing")
      elif [[ ! -s "$abs_path" ]]; then
        missing_required_paths+=("$resolved_path|empty")
      fi
    elif [[ -e "$abs_path" ]]; then
      present_optional_paths+=("$resolved_path")
    fi
  done

  if ((${#missing_required_paths[@]} > 0)); then
    failure_log=""
    for item in "${missing_required_paths[@]}"; do
      resolved_path="${item%%|*}"
      if [[ -n "$failure_log" ]]; then
        failure_log+=", "
      fi
      failure_log+="$resolved_path"
    done
    ralph_run_plan_log "FAIL line=$line_num missing required output artifacts: $failure_log"
    echo -e "${C_R}${C_BOLD}Missing required output artifact(s) for TODO line $line_num:${C_RST}" >&2
    for item in "${missing_required_paths[@]}"; do
      resolved_path="${item%%|*}"
      case "${item#*|}" in
        missing)
          echo "  $resolved_path (missing; resolved: $(ralph_run_plan_artifact_abs_path "$resolved_path"))" >&2
          ;;
        empty)
          echo "  $resolved_path (empty; resolved: $(ralph_run_plan_artifact_abs_path "$resolved_path"))" >&2
          ;;
      esac
    done
    return 1
  fi

  if ((${#present_optional_paths[@]} > 0)); then
    failure_log=""
    for resolved_path in "${present_optional_paths[@]}"; do
      if [[ -n "$failure_log" ]]; then
        failure_log+=", "
      fi
      failure_log+="$resolved_path"
    done
    ralph_run_plan_log "optional output artifacts present line=$line_num: $failure_log"
  fi
}

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/ralph-format-elapsed.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-opencode-cache-warning.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-post-verify.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/ralph-process-teardown.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/ralph-process-supervisor.sh"

ralph_plan_hint_feed_forward_enabled() {
  local raw="${RALPH_PLAN_HINT_FEED_FORWARD:-1}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    0|false|no|off)
      return 1
      ;;
  esac
  return 0
}

ralph_efficiency_hint_path() {
  if [[ -n "${RALPH_EFFICIENCY_HINT_FILE:-}" ]]; then
    printf '%s' "$RALPH_EFFICIENCY_HINT_FILE"
    return 0
  fi
  return 1
}

ralph_efficiency_hint_clear() {
  local _file
  if _file="$(ralph_efficiency_hint_path 2>/dev/null)"; then
    rm -f "$_file"
  fi
}

ralph_efficiency_hint_store() {
  local hint="$1"
  if [[ -z "$hint" ]]; then
    ralph_efficiency_hint_clear
    return 0
  fi
  if ! ralph_plan_hint_feed_forward_enabled; then
    ralph_efficiency_hint_clear
    return 0
  fi
  local _file
  if ! _file="$(ralph_efficiency_hint_path 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "$hint" > "$_file"
  chmod 600 "$_file"
}

ralph_efficiency_hint_load_and_clear() {
  local _file
  if ! _file="$(ralph_efficiency_hint_path 2>/dev/null)"; then
    return 0
  fi
  if [[ ! -s "$_file" ]]; then
    rm -f "$_file"
    return 0
  fi
  local _hint
  _hint="$(< "$_file")"
  ralph_efficiency_hint_clear
  printf '%s' "$_hint"
}

ralph_apply_previous_efficiency_hint_to_prompt() {
  if ! ralph_plan_hint_feed_forward_enabled; then
    ralph_efficiency_hint_clear
    return 0
  fi
  local _hint
  _hint="$(ralph_efficiency_hint_load_and_clear)"
  if [[ -n "$_hint" ]]; then
    if [[ "$_hint" == WARNING:* ]]; then
      PROMPT+=$'\nPrevious invocation policy: '"${_hint}"'. Use ralph_proxy_* for all exploration; native Read only once per file immediately before Edit/Write after ralph_proxy_read on that path.'
    else
      PROMPT+=$'\nPrevious invocation telemetry: '"${_hint}"'. Use ralph_proxy_batch (max 8 operations per call) for independent reads and do not re-read unchanged targets.'
    fi
  fi
}

if [[ "${RALPH_RUN_PLAN_LIBRARY_ONLY:-0}" == "1" ]]; then
  return 0
fi

# Bare `source run-plan-core.sh` (guidance dumps, ad-hoc function checks) does not
# load the run-plan.sh prelude where prompt_select_runtime lives. Stop after
# defining helpers instead of falling into the interactive runtime picker and
# exiting the caller's shell via `|| exit 1`.
if ! declare -F prompt_select_runtime >/dev/null 2>&1; then
  return 0
fi

# Read plan header runtime/model early (PLAN_OVERRIDE and WORKSPACE are set by arg parser).
# These serve as defaults when --runtime / --model / env vars are not provided.
_plan_header_runtime=""
_plan_header_model=""
_plan_model_from_cli="${PLAN_MODEL_CLI:-}"
if [[ -n "${PLAN_OVERRIDE:-}" ]]; then
  _early_plan_path="$(plan_normalize_path "$PLAN_OVERRIDE" "$WORKSPACE" 2>/dev/null || true)"
  if [[ -f "$_early_plan_path" ]] && head -1 "$_early_plan_path" 2>/dev/null | grep -q "^---"; then
    _plan_header_runtime="$(awk 'NR==1&&$0=="---"{f=1;next}f&&$0=="---"{exit}f&&/^runtime:/{v=$0;sub(/^runtime:[[:space:]]*/,"",v);gsub(/[[:space:]]*$/,"",v);if(length(v)>0)print v;exit}' "$_early_plan_path" 2>/dev/null || true)"
    _plan_header_model="$(awk 'NR==1&&$0=="---"{f=1;next}f&&$0=="---"{exit}f&&/^model:/{v=$0;sub(/^model:[[:space:]]*/,"",v);gsub(/[[:space:]]*$/,"",v);if(length(v)>0)print v;exit}' "$_early_plan_path" 2>/dev/null || true)"
  fi
fi

if [[ -z "$RUNTIME" ]]; then
  if [[ -n "${RALPH_PLAN_RUNTIME:-}" ]]; then
    RUNTIME="$(ralph_normalize_runtime_name "${RALPH_PLAN_RUNTIME}")"
    case "$RUNTIME" in
      cursor|claude|codex|opencode|antigravity)
        ;;
      *)
        ralph_die "Error: RALPH_PLAN_RUNTIME must be one of cursor, claude, codex, opencode, or antigravity."
        ;;
    esac
  elif [[ -n "${_plan_header_runtime:-}" ]]; then
    RUNTIME="$(ralph_normalize_runtime_name "${_plan_header_runtime}")"
    case "$RUNTIME" in
      cursor|claude|codex|opencode|antigravity)
        ;;
      *)
        ralph_die "Error: plan header 'runtime' must be one of cursor, claude, codex, opencode, or antigravity."
        ;;
    esac
  else
    RUNTIME="$(prompt_select_runtime)" || exit 1
  fi
fi
if [[ "$RUNTIME" == "opencode" && "${RALPH_PLAN_SESSION_STRATEGY:-}" == "compact" \
  && ( -n "$SESSION_STRATEGY_FLAG" || "${RALPH_PLAN_SESSION_STRATEGY_ENV_SPECIFIED:-0}" == "1" ) ]]; then
  ralph_die "Error: OpenCode does not support the compact session strategy when configured non-interactively; use fresh/resume/reset instead."
fi
HUMAN_ACTION_FILE="$WORKSPACE/HUMAN_ACTION_REQUIRED.md"

RUNTIME_ROOT="$(ralph_resolve_runtime_root "$RUNTIME" "$WORKSPACE")" || {
  ralph_die "Error: runtime config root not found for $RUNTIME. Checked $WORKSPACE/.$RUNTIME, ${RALPH_GLOBAL_RUNTIME_HOME:-$HOME}/.$RUNTIME, and ${RALPH_HOME:-$HOME/.ralph}/bundle/.$RUNTIME."
}
export RALPH_RUNTIME_ROOT="$RUNTIME_ROOT"
# Derive the display label from the runtime's config dirname so antigravity
# shows ".agents/agents" rather than the bogus ".antigravity/agents".
AGENTS_ROOT_REL="$(ralph_runtime_config_dirname "$RUNTIME")/agents"
AGENTS_ROOT="$RUNTIME_ROOT/agents"

RALPH_RUN_PLAN_RELATIVE=".ralph/run-plan.sh --runtime ${RUNTIME}"

SELECT_MODEL_SCRIPT="$(ralph_select_model_script "$RUNTIME" "$WORKSPACE" "$SCRIPT_DIR")" || {
  ralph_die "Error: select-model script not found for runtime $RUNTIME."
}
export RALPH_SHARED_RALPH_DIR="$SCRIPT_DIR"
# shellcheck disable=SC1090
source "$SELECT_MODEL_SCRIPT"

# Log to file and optionally stdout (if CURSOR_PLAN_VERBOSE=1)
# Logging runs dozens of times per invocation, so it must not fork. The
# timestamp uses bash's printf when the running bash supports %()T (4.2+) and
# falls back to date(1) on bash 3.2; the log directory is created once per
# path instead of on every line, and ${path%/*} replaces dirname(1).
_RALPH_LOG_TS_BUILTIN=""
_RALPH_LOG_DIR_READY=""
ralph_run_plan_log() {
  local ts
  local log_path="${LOG_FILE:-}"
  if [[ -z "$_RALPH_LOG_TS_BUILTIN" ]]; then
    if printf '%(%Y)T' -1 >/dev/null 2>&1; then
      _RALPH_LOG_TS_BUILTIN=1
    else
      _RALPH_LOG_TS_BUILTIN=0
    fi
  fi
  if [[ "$_RALPH_LOG_TS_BUILTIN" == "1" ]]; then
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
  else
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
  fi
  if [[ -n "$log_path" ]]; then
    if [[ "$_RALPH_LOG_DIR_READY" != "$log_path" ]]; then
      mkdir -p "${log_path%/*}"
      _RALPH_LOG_DIR_READY="$log_path"
    fi
    echo "[$ts] $*" >> "$log_path"
  fi
  if [[ "${CURSOR_PLAN_VERBOSE:-0}" == "1" ]]; then
    echo -e "${C_DIM}[$ts]${C_RST} $*" >&2
  fi
}

_RALPH_RUNTIME_OVERLAY_ACTIVE=0
_RALPH_RUNTIME_OVERLAY_CLEANUP_DONE=1

ralph_runtime_overlay_cleanup_if_needed() {
  if [[ "$_RALPH_RUNTIME_OVERLAY_ACTIVE" != "1" ]]; then
    return
  fi
  if [[ "${_RALPH_RUNTIME_OVERLAY_CLEANUP_DONE:-0}" -eq 1 ]]; then
    return
  fi
  _RALPH_RUNTIME_OVERLAY_CLEANUP_DONE=1
  if declare -F runtime_overlay_run_cleanup >/dev/null 2>&1; then
    runtime_overlay_run_cleanup || true
  fi
  if declare -F runtime_overlay_journal_mark_cleaned >/dev/null 2>&1; then
    runtime_overlay_journal_mark_cleaned || true
  fi
  if declare -F runtime_overlay_write_summary >/dev/null 2>&1; then
    local summary_path
    summary_path="$(runtime_overlay_summary_path 2>/dev/null || true)"
    # Always rewrite summary to ensure it reflects latest telemetry from jsonl files
    runtime_overlay_write_summary || true
    summary_path="$(runtime_overlay_summary_path 2>/dev/null || true)"
    if [[ -n "$summary_path" ]]; then
      ralph_run_plan_log "Runtime overlay summary: $summary_path"
    fi
  fi
}

ralph_runtime_overlay_chain_exit_trap() {
  local handler="$1"
  if [[ -z "$handler" ]]; then
    trap 'ralph_runtime_overlay_cleanup_if_needed' EXIT
    return
  fi
  trap "$handler; ralph_runtime_overlay_cleanup_if_needed" EXIT
}

ralph_runtime_overlay_signal_trap_handler() {
  ralph_runtime_overlay_cleanup_if_needed
}

ralph_run_plan_kill_switch_summary() {
  local sentinel_path="$1"
  if [[ -z "$sentinel_path" || ! -f "$sentinel_path" ]]; then
    return 1
  fi
  if command -v python3 &>/dev/null; then
    python3 - <<'PY' "$sentinel_path"
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    print("sentinel parse error", end="")
    sys.exit(0)
tool = data.get("tool", "unknown")
reason = data.get("reason", "policy violation")
plan_key = data.get("plan_key", "")
summary = f"tool={tool} reason={reason}"
if plan_key:
    summary += f" plan_key={plan_key}"
print(summary)
PY
    return 0
  fi
  local compact
  compact="$(tr '\n' ' ' < "$sentinel_path" | tr -s ' ' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' 2>/dev/null || true)"
  if [[ -n "$compact" ]]; then
    printf '%s\n' "$compact"
    return 0
  fi
  return 1
}

ralph_run_plan_abort_if_kill_switch() {
  local effective_mode
  effective_mode="$(ralph_mcp_policy_violation_mode_effective)"
  if [[ "$effective_mode" == "error" || "$effective_mode" == "approve" ]]; then
    return 0
  fi
  if [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" != "ralph" ]]; then
    case "${RALPH_MCP_ENFORCE_KILL_SWITCH_NATIVE:-0}" in
      1|true|yes|on) ;;
      *) return 0 ;;
    esac
  fi
  local sentinel_path
  sentinel_path="$(ralph_mcp_policy_sentinel_path)" || return 0
  if [[ -z "$sentinel_path" || ! -f "$sentinel_path" ]]; then
    return 0
  fi
  local sentinel_mtime=""
  if sentinel_mtime="$(stat -f '%m' "$sentinel_path" 2>/dev/null)"; then
    :
  elif sentinel_mtime="$(stat -c '%Y' "$sentinel_path" 2>/dev/null)"; then
    :
  else
    sentinel_mtime=""
  fi
  if [[ -n "${_plan_start_ts:-}" && "$_plan_start_ts" =~ ^[0-9]+$ && "$sentinel_mtime" =~ ^[0-9]+$ ]] && (( sentinel_mtime < _plan_start_ts )); then
    if [[ "${_RALPH_STALE_KILL_SWITCH_LOGGED:-}" != "$sentinel_path" ]]; then
      ralph_run_plan_log "Ignoring stale kill-switch sentinel from a previous run: $sentinel_path"
      _RALPH_STALE_KILL_SWITCH_LOGGED="$sentinel_path"
    fi
    return 0
  fi
  local summary
  summary="$(ralph_run_plan_kill_switch_summary "$sentinel_path" 2>/dev/null || true)"
  local log_msg="Kill-switch sentinel detected"
  if [[ -n "$summary" ]]; then
    log_msg+=" (${summary})"
  fi
  log_msg+="; aborting plan run."
  ralph_run_plan_log "$log_msg"
  if [[ -n "$summary" ]]; then
    echo -e "${C_R}${C_BOLD}Fatal kill-switch sentinel detected (${summary}).${C_RST}" >&2
  else
    echo -e "${C_R}${C_BOLD}Fatal kill-switch sentinel detected.${C_RST}" >&2
  fi
  local exit_code="${RALPH_MCP_POLICY_VIOLATION_EXIT_CODE:-64}"
  ralph_die "Kill-switch sentinel triggered: ${summary:-policy violation}" "$exit_code"
}

ralph_ensure_cursor_cli() {
  CURSOR_CLI=""
  local cli
  if ! cli="$(ralph_resolve_cursor_cli)"; then
    ralph_run_plan_log "ERROR: Cursor CLI not found (neither cursor-agent nor agent in PATH)"
    echo -e "${C_R}${C_BOLD}Cursor CLI is not installed or not logged in.${C_RST}"
    echo ""
    echo -e "This script requires the Cursor CLI. Please:"
    echo -e "  1. Install the CLI"
    echo -e "  2. Log in (e.g. run \`agent\` or \`cursor-agent\` and complete sign-in)"
    echo ""
    echo -e "Official installation and login instructions:"
    echo -e "  ${C_C}https://cursor.com/docs/cli/installation${C_RST}"
    echo ""
    echo -e "${C_DIM}After installing, add ~/.local/bin to your PATH, then run \`agent\` to log in and re-run this script.${C_RST}"
    exit 1
  fi
  CURSOR_CLI="$cli"
}

ralph_ensure_claude_cli() {
  local cli="${CLAUDE_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v claude 2>/dev/null)" ]]; then
    cli="claude"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Claude CLI not found (set CLAUDE_PLAN_CLI or install claude)"
    echo -e "${C_R}${C_BOLD}Claude Code CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install Claude Code, then ensure \`claude\` is available:"
    echo -e "  ${C_C}https://code.claude.com/docs/en/overview${C_RST}"
    echo -e "  ${C_C}https://code.claude.com/docs/en/headless${C_RST}"
    echo ""
    exit 1
  fi
  CLAUDE_CLI="$cli"
  : "$CLAUDE_CLI"
}

ralph_ensure_codex_cli() {
  local cli="${CODEX_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v codex 2>/dev/null)" ]]; then
    cli="codex"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Codex CLI not found (set CODEX_PLAN_CLI or install codex)"
    echo -e "${C_R}${C_BOLD}Codex CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install the Codex CLI and authenticate. Non-interactive runs use: codex exec"
    echo -e "  ${C_C}https://developers.openai.com/codex/noninteractive${C_RST}"
    echo -e "  ${C_C}https://developers.openai.com/codex/cli/reference${C_RST}"
    echo ""
    exit 1
  fi
  CODEX_CLI="$cli"
  : "$CODEX_CLI"
}

ralph_ensure_antigravity_cli() {
  local cli="${ANTIGRAVITY_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v agy 2>/dev/null)" ]]; then
    cli="agy"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Antigravity CLI not found (set ANTIGRAVITY_PLAN_CLI or install agy)"
    echo -e "${C_R}${C_BOLD}Antigravity CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install the Antigravity CLI and authenticate. Non-interactive runs use: agy"
    echo -e "  ${C_C}https://antigravity.google${C_RST}"
    echo ""
    exit 1
  fi
  ANTIGRAVITY_CLI="$cli"
  : "$ANTIGRAVITY_CLI"
}

# shellcheck source=bash-lib/run-plan/run-plan-agent.sh
_run_plan_agent_dir=""
if [[ -n "${SCRIPT_DIR:-}" ]]; then
  _run_plan_agent_dir="$SCRIPT_DIR"
elif [[ -n "${REPO_ROOT:-}" ]]; then
  _run_plan_agent_dir="$REPO_ROOT/.ralph"
else
  _run_plan_agent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
source "$_run_plan_agent_dir/bash-lib/run-plan/run-plan-agent.sh"
# shellcheck source=/dev/null
source "$_run_plan_agent_dir/bash-lib/run-plan/run-plan-reasoning-effort.sh"
# shellcheck source=/dev/null
source "$_run_plan_agent_dir/bash-lib/run-plan/run-plan-claude-speculative-cache-warm.sh"
unset _run_plan_agent_dir
# RUN_PLAN_AGENT_HELPERS_END

PLAN_PATH="$(plan_normalize_path "$PLAN_OVERRIDE" "$WORKSPACE")"

# Apply plan header model as PLAN_MODEL_CLI default so the non-interactive preflight
# and per-todo routing both see it. A --model flag always takes priority.
if [[ -z "${PLAN_MODEL_CLI:-}" && -n "${_plan_header_model:-}" ]]; then
  PLAN_MODEL_CLI="$_plan_header_model"
fi

if [[ -f "$PLAN_PATH" ]] && ! plan_pipeline_validate_plan "$PLAN_PATH"; then
  exit 1
fi

if ! ralph_run_plan_seed_yaml_bootstrap_context "$PLAN_PATH"; then
  ralph_die "Error: failed to resolve initial YAML todo routing context."
fi

# Per-plan logs and session files under .ralph-workspace/ (override with RALPH_PLAN_WORKSPACE_ROOT).
# Keeps agent-writable paths (pending-human.txt, etc.) out of .ralph-workspace, which some CLIs sandbox or restrict.
PLAN_LOG_NAME="$(plan_log_basename "$PLAN_PATH")"
# Plan namespace for logs, sessions, and templated paths; inherited by subprocesses.
export RALPH_PLAN_KEY="${RALPH_PLAN_KEY:-$PLAN_LOG_NAME}"
# Artifact namespace (often equals plan key); used for {{ARTIFACT_NS}} style paths.
export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-$RALPH_PLAN_KEY}"
export RALPH_RUN_PLAN_ACTIVE=1
DEFAULT_RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
  DEFAULT_RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE_ROOT_OVERRIDE"
fi
RALPH_PLAN_WORKSPACE_ROOT="${RALPH_PLAN_WORKSPACE_ROOT:-$DEFAULT_RALPH_PLAN_WORKSPACE_ROOT}"
export RALPH_PROJECT_ROOT="$WORKSPACE"
export RALPH_PLAN_WORKSPACE_ROOT
# Graph scheduler / Sequential workflow engine set RALPH_GRAPH_NODE_LOG_DIR to
# the contained attempt directory:
#   Dependency: <run-dir>/logs/nodes/<safe-node-id>/<attempt-id>/
#   Sequential: <registry-run>/engine/logs/stages/<stage>/attempt-<n>/
# Never create or append to the namespace-only logs/<namespace>/nodes/ tree.
if [[ -n "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]]; then
  RALPH_LOG_DIR="$RALPH_GRAPH_NODE_LOG_DIR"
elif [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]; then
  RALPH_LOG_DIR="$RALPH_PLAN_WORKSPACE_ROOT/logs/$RALPH_ARTIFACT_NS"
else
  RALPH_LOG_DIR="$RALPH_PLAN_WORKSPACE_ROOT/logs/$RALPH_ARTIFACT_NS"
fi
unset RALPH_MCP_PROXY_LOG_FILE

# Acquire the canonical plan lease and start (or structurally attach to) the
# detached process guardian before any runtime overlays or model processes are
# created. Python 3 is a required dependency because safe cross-platform
# session discovery cannot be implemented reliably in portable shell.
ralph_process_run_init "$RALPH_PLAN_WORKSPACE_ROOT" "$WORKSPACE" "$PLAN_PATH" plan || exit $?

RALPH_PLAN_HINT_FEED_FORWARD="${RALPH_PLAN_HINT_FEED_FORWARD:-1}"
export RALPH_PLAN_HINT_FEED_FORWARD

if declare -F runtime_overlay_restore_stale_runs >/dev/null 2>&1; then
  if overlay_restore_output="$(runtime_overlay_restore_stale_runs "$WORKSPACE" "${RALPH_PLAN_KEY:-}" "" "recovered_after_interruption" "$RUNTIME")"; then
    if [[ -n "$overlay_restore_output" ]]; then
      while IFS= read -r line; do
        ralph_run_plan_log "$line"
      done <<< "$overlay_restore_output"
    fi
  else
    ralph_run_plan_log "Runtime overlay stale restore failed for workspace $WORKSPACE"
  fi
fi

if declare -F runtime_overlay_init_state >/dev/null 2>&1; then
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  _RALPH_RUNTIME_OVERLAY_ACTIVE=1
  if declare -F ralph_bg_tier_probe_apply >/dev/null 2>&1; then
    if ! ralph_bg_tier_probe_apply "$RUNTIME"; then
      echo "Error: background tier probe failed (RALPH_BG_TIER=hook requires tier-1 hook support)" >&2
      exit 1
    fi
  fi
  # Mark cleanup as not-yet-done so EXIT/signal traps run registered cleanup.
  _RALPH_RUNTIME_OVERLAY_CLEANUP_DONE=0
  ralph_runtime_overlay_chain_exit_trap ""
  trap 'ralph_runtime_overlay_signal_trap_handler' INT TERM HUP
  if [[ -n "${RALPH_RUNTIME_OVERLAY_TEST_CLEANUP_MARKER:-}" ]]; then
    _RALPH_RUNTIME_OVERLAY_TEST_CLEANUP_CMD="$(printf 'touch %q' "$RALPH_RUNTIME_OVERLAY_TEST_CLEANUP_MARKER")"
    runtime_overlay_register_cleanup "$_RALPH_RUNTIME_OVERLAY_TEST_CLEANUP_CMD"
    unset _RALPH_RUNTIME_OVERLAY_TEST_CLEANUP_CMD
  fi
fi

ralph_run_plan_record_workspace_registry "$WORKSPACE" "$RUNTIME" "$RALPH_PLAN_KEY"

ralph_session_init "$WORKSPACE" "$PLAN_LOG_NAME"

if declare -F ralph_bg_job_recover_on_restart >/dev/null 2>&1; then
  ralph_bg_job_recover_on_restart || true
fi

if [[ -f "$RALPH_SESSION_DIR/killswitch-override.json" ]]; then
  RALPH_KILLSWITCH_OVERRIDE_FILE="$RALPH_SESSION_DIR/killswitch-override.json"
  export RALPH_KILLSWITCH_OVERRIDE_FILE
fi
if [[ -f "$RALPH_SESSION_DIR/opencode-permission-override.json" ]]; then
  OPENCODE_PLAN_PERMISSION_CONFIG_PATH="$RALPH_SESSION_DIR/opencode-permission-override.json"
  export OPENCODE_PLAN_PERMISSION_CONFIG_PATH
fi
if [[ -f "$RALPH_SESSION_DIR/runtime-permission-overrides.sh" ]]; then
  RALPH_RUNTIME_PERMISSION_OVERRIDES_FILE="$RALPH_SESSION_DIR/runtime-permission-overrides.sh"
  export RALPH_RUNTIME_PERMISSION_OVERRIDES_FILE
  # shellcheck source=/dev/null
  source "$RALPH_RUNTIME_PERMISSION_OVERRIDES_FILE"
fi

if [[ -n "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]]; then
  LOG_FILE="$RALPH_LOG_DIR/agent.log"
  OUTPUT_LOG="$RALPH_LOG_DIR/agent.log"
elif [[ -z "${CURSOR_PLAN_LOG:-}" ]]; then
  LOG_FILE="$RALPH_LOG_DIR/plan-runner-${PLAN_LOG_NAME}.log"
else
  LOG_FILE="$CURSOR_PLAN_LOG"
fi
if [[ -z "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]]; then
  if [[ -z "${CURSOR_PLAN_OUTPUT_LOG:-}" ]]; then
    OUTPUT_LOG="$RALPH_LOG_DIR/plan-runner-${PLAN_LOG_NAME}-output.log"
  else
    OUTPUT_LOG="$CURSOR_PLAN_OUTPUT_LOG"
  fi
fi
# Destination for captured CLI stdout/stderr (tee); subprocesses may append via invoke helpers.
export OUTPUT_LOG

ralph_assert_path_not_env_secret "Plan file" "$PLAN_PATH"
ralph_assert_path_not_env_secret "Plan log" "$LOG_FILE"
ralph_assert_path_not_env_secret "Output log" "$OUTPUT_LOG"

case "$RUNTIME" in
  cursor)
    ralph_ensure_cursor_cli
    ;;
  claude)
    ralph_ensure_claude_cli
    ;;
  codex)
    ralph_ensure_codex_cli
    ;;
  opencode)
    ralph_ensure_opencode_cli
    ;;
  antigravity)
    ralph_ensure_antigravity_cli
    ;;
esac

RALPH_INVOKED_CLI=""
case "$RUNTIME" in
  cursor) RALPH_INVOKED_CLI="$CURSOR_CLI" ;;
  claude) RALPH_INVOKED_CLI="$CLAUDE_CLI" ;;
  codex) RALPH_INVOKED_CLI="$CODEX_CLI" ;;
  opencode) RALPH_INVOKED_CLI="$OPENCODE_CLI" ;;
  antigravity) RALPH_INVOKED_CLI="$ANTIGRAVITY_CLI" ;;
esac
export RALPH_INVOKED_CLI

MAX_ITERATIONS="${CURSOR_PLAN_MAX_ITER:-50}"
case "$RUNTIME" in
  antigravity)
    MAX_ITERATIONS="${ANTIGRAVITY_PLAN_MAX_ITER:-${OPENCODE_PLAN_MAX_ITER:-${CODEX_PLAN_MAX_ITER:-${CLAUDE_PLAN_MAX_ITER:-${CURSOR_PLAN_MAX_ITER:-50}}}}}"
    ;;
esac
case "$RUNTIME" in
  cursor)
    _ralph_gutter_default="${CURSOR_PLAN_GUTTER_ITER:-3}"
    ;;
  claude)
    _ralph_gutter_default="${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-3}}"
    ;;
  codex)
    _ralph_gutter_default="${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-3}}}"
    ;;
  opencode)
    _ralph_gutter_default="${OPENCODE_PLAN_GUTTER_ITER:-${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-3}}}}"
    ;;
  antigravity)
    _ralph_gutter_default="${ANTIGRAVITY_PLAN_GUTTER_ITER:-${OPENCODE_PLAN_GUTTER_ITER:-${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-3}}}}}"
    ;;
  *)
    _ralph_gutter_default="${CURSOR_PLAN_GUTTER_ITER:-3}"
    ;;
esac
GUTTER_ITERATIONS="${RALPH_PLAN_TODO_MAX_ITERATIONS:-$_ralph_gutter_default}"
unset _ralph_gutter_default

# Cache the effective compact command for this runtime so the post-verification
# reopen retry path can quickly decide whether compact resume is available.
_ralph_compact_command_for_runtime=""
case "$RUNTIME" in
  claude)
    _ralph_compact_command_for_runtime="${RALPH_PLAN_COMPACT_COMMAND:-${RALPH_PLAN_RESET_COMMAND:-${RALPH_PLAN_RESET_COMMAND_CLAUDE:-/clear}}}"
    ;;
  cursor)
    _ralph_compact_command_for_runtime="${RALPH_PLAN_COMPACT_COMMAND:-${RALPH_PLAN_COMPACT_COMMAND_CURSOR:-/compress}}"
    ;;
  codex)
    _ralph_compact_command_for_runtime="${RALPH_PLAN_COMPACT_COMMAND:-${RALPH_PLAN_COMPACT_COMMAND_CODEX:-/compact}}"
    ;;
  opencode)
    _ralph_compact_command_for_runtime="${RALPH_PLAN_COMPACT_COMMAND:-${RALPH_PLAN_COMPACT_COMMAND_OPENCODE:-}}"
    ;;
  antigravity)
    _ralph_compact_command_for_runtime="${RALPH_PLAN_COMPACT_COMMAND:-${RALPH_PLAN_COMPACT_COMMAND_ANTIGRAVITY:-}}"
    ;;
  *)
    _ralph_compact_command_for_runtime="${RALPH_PLAN_COMPACT_COMMAND:-}"
    ;;
esac

RALPH_PLAN_RESUME_HINT_EMITTED=0

RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS=""
if ! RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS="$(ralph_resolve_timeout)"; then
  ralph_die "Error: failed to resolve invocation timeout"
fi

ralph_run_plan_log "run-plan.sh started (workspace=$WORKSPACE plan=$PLAN_PATH)"
ralph_run_plan_log "plan_path=$PLAN_PATH output_log=$OUTPUT_LOG log_file=$LOG_FILE"
ralph_run_plan_log "artifact namespace: RALPH_ARTIFACT_NS=$RALPH_ARTIFACT_NS RALPH_PLAN_KEY=$RALPH_PLAN_KEY"
ralph_run_plan_log "invocation timeout: ${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s (${RALPH_PLAN_INVOCATION_TIMEOUT_RAW:-default 30m})"
if ! ralph_run_plan_non_interactive_model_preflight_ok; then
  case "$RUNTIME" in
    claude|codex)
      ralph_run_plan_die_unresolved_claude_codex_model "$RUNTIME"
      ;;
    *)
      ralph_run_plan_log "ERROR: --non-interactive requires --model <id> or CURSOR_PLAN_MODEL"
      echo -e "${C_R}${C_BOLD}Non-interactive mode requires --model <id> or CURSOR_PLAN_MODEL.${C_RST}" >&2
      exit 1
      ;;
  esac
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  ralph_run_plan_log "ERROR: plan file not found: $PLAN_PATH"
  echo -e "${C_R}${C_BOLD}Plan file not found:${C_RST} ${C_R}$PLAN_PATH${C_RST}"
  echo -e "${C_DIM}Create the plan file or pass a valid path with --plan <path>.${C_RST}"
  exit 1
fi

ralph_run_plan_log "plan file found: $PLAN_PATH"

# Apply consolidation pass if enabled
if [[ "${RALPH_PLAN_CONSOLIDATE:-0}" == "1" ]]; then
  ralph_run_plan_log "applying todo consolidation (RALPH_PLAN_CONSOLIDATE=1)"
  ralph_run_plan_consolidate_todos "$PLAN_PATH"
fi

RALPH_PLAN_SPLIT_MODE="${RALPH_PLAN_SPLIT_MODE:-warn}"
if [[ "${RALPH_PLAN_AUTO_SPLIT:-0}" == "1" && "$RALPH_PLAN_SPLIT_MODE" == "warn" ]]; then
  RALPH_PLAN_SPLIT_MODE="rewrite"
fi
case "$RALPH_PLAN_SPLIT_MODE" in
  warn|rewrite|fail)
    ralph_run_plan_log "running todo preflight (RALPH_PLAN_SPLIT_MODE=$RALPH_PLAN_SPLIT_MODE)"
    if ! ralph_plan_split_preflight "$PLAN_PATH" "$RALPH_PLAN_SPLIT_MODE"; then
      ralph_run_plan_log "ERROR: todo preflight failed mode=$RALPH_PLAN_SPLIT_MODE"
      echo -e "${C_R}${C_BOLD}Plan preflight failed:${C_RST} broad TODOs must be split before execution." >&2
      exit 1
    fi
    ;;
  *)
    ralph_run_plan_log "ERROR: invalid RALPH_PLAN_SPLIT_MODE=$RALPH_PLAN_SPLIT_MODE"
    echo "Error: RALPH_PLAN_SPLIT_MODE must be warn, rewrite, or fail." >&2
    exit 1
    ;;
esac

_PLAN_VERIFY_COMMAND="$(plan_frontmatter_verify_command "$PLAN_PATH" 2>/dev/null || true)"
if [[ -n "$_PLAN_VERIFY_COMMAND" ]]; then
  ralph_run_plan_log "plan-level post-verification command configured"
fi

ralph_path_to_file_uri() {
  if command -v python3 &>/dev/null; then
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$1" 2>/dev/null || echo "file://localhost$1"
  else
    local encoded="${1// /%20}"
    echo "file://$encoded"
  fi
}

ralph_should_persist_human_files() {
  if [[ -t 0 && -t 1 ]]; then
    return 1
  fi
  return 0
}

ralph_restart_command_hint() {
  if [[ -n "${RALPH_ORCH_FILE:-}" ]]; then
    printf '.ralph/orchestrator.sh --orchestration %s' "$(printf '%q' "$RALPH_ORCH_FILE")"
  else
    printf '%s --non-interactive --plan %s --workspace %s' \
      "$RALPH_RUN_PLAN_RELATIVE" \
      "$(printf '%q' "$PLAN_PATH")" \
      "$(printf '%q' "$WORKSPACE")"
  fi
}

ralph_json_field() {
  local file="${1:-}"
  local field="${2:-}"
  [[ -f "$file" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg field "$field" '.[$field] // empty' "$file" 2>/dev/null || return 1
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$field" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
try:
    doc = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
value = doc.get(field, "")
if value is None:
    value = ""
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
    return $?
  fi
  return 1
}

ralph_read_human_request_metadata() {
  local file="${1:-${HUMAN_REQUEST_FILE:-}}"
  [[ -n "$file" ]] || return 1
  [[ -f "$file" ]] || return 1
  local kind runtime classification blocked_cmd blocked_path blocked_tool question resume
  kind="$(ralph_json_field "$file" kind 2>/dev/null || printf 'guidance')"
  runtime="$(ralph_json_field "$file" runtime 2>/dev/null || true)"
  classification="$(ralph_json_field "$file" classification 2>/dev/null || true)"
  blocked_cmd="$(ralph_json_field "$file" blocked_command_or_tool 2>/dev/null || true)"
  blocked_path="$(ralph_json_field "$file" blocked_path 2>/dev/null || true)"
  blocked_tool="$(ralph_json_field "$file" blocked_tool 2>/dev/null || true)"
  question="$(ralph_json_field "$file" question 2>/dev/null || true)"
  resume="$(ralph_json_field "$file" resume_command 2>/dev/null || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$runtime" "$classification" "$blocked_cmd" "$blocked_path" "$blocked_tool" "$question" "$resume"
}

ralph_write_operator_response_template() {
  local request_file="${1:-${HUMAN_REQUEST_FILE:-}}"
  local response_file="${2:-${OPERATOR_RESPONSE_FILE:-}}"
  [[ -n "$response_file" ]] || return 1
  local kind="guidance"
  local runtime=""
  local classification=""
  local blocked_command_or_tool=""
  local blocked_path=""
  local blocked_tool=""
  local question=""
  if [[ -n "$request_file" ]] && [[ -f "$request_file" ]]; then
    kind="$(ralph_json_field "$request_file" kind 2>/dev/null || printf 'guidance')"
    runtime="$(ralph_json_field "$request_file" runtime 2>/dev/null || true)"
    classification="$(ralph_json_field "$request_file" classification 2>/dev/null || true)"
    blocked_command_or_tool="$(ralph_json_field "$request_file" blocked_command_or_tool 2>/dev/null || true)"
    blocked_path="$(ralph_json_field "$request_file" blocked_path 2>/dev/null || true)"
    blocked_tool="$(ralph_json_field "$request_file" blocked_tool 2>/dev/null || true)"
    question="$(ralph_json_field "$request_file" question 2>/dev/null || true)"
  fi
  cat >"$response_file" <<EOF
{
  "placeholder": true,
  "kind": "$kind",
  "decision": "$( [[ "$kind" == "permission" ]] && printf 'allow' || printf 'answer' )",
  "runtime": "$runtime",
  "classification": "$classification",
  "blocked_command_or_tool": "$blocked_command_or_tool",
  "blocked_path": "$blocked_path",
  "blocked_tool": "$blocked_tool",
  "reason": "",
  "answer": ""
}
EOF
}

ralph_operator_has_real_answer() {
  [[ -s "$OPERATOR_RESPONSE_FILE" ]] || return 1
  local _p _ph
  _p="$(tr -d '[:space:]' <"$OPERATOR_RESPONSE_FILE")"
  _ph="$(printf '%s' '(Replace this line with your answer to the question above, then save.)' | tr -d '[:space:]')"
  [[ "$_p" == "$_ph" ]] && return 1
  [[ -z "$_p" ]] && return 1
  if [[ "$_p" =~ ^\{ ]]; then
    local _kind _decision _answer
    local _placeholder
    _placeholder="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" placeholder 2>/dev/null || true)"
    [[ "$_placeholder" == "true" ]] && return 1
    _kind="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" kind 2>/dev/null || true)"
    _decision="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" decision 2>/dev/null || true)"
    _answer="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" answer 2>/dev/null || true)"
    case "$_kind" in
      permission)
        case "$(printf '%s' "$_decision" | tr '[:upper:]' '[:lower:]')" in
          allow|deny)
            return 0
            ;;
        esac
        return 1
        ;;
      guidance)
        [[ -n "$_answer" ]] && return 0
        return 1
        ;;
      *)
        [[ -n "$_decision" || -n "$_answer" ]] && return 0
        return 1
        ;;
    esac
  fi
  return 0
}

ralph_operator_response_file_owned_by_current_user() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 1
  local current_uid owner_uid
  current_uid="$(id -u)"
  if owner_uid="$(stat -c '%u' "$file" 2>/dev/null)"; then
    :
  elif owner_uid="$(stat -f '%u' "$file" 2>/dev/null)"; then
    :
  else
    echo "Warning: unable to determine owner of $file; rejecting operator response for safety." >&2
    return 1
  fi
  owner_uid="${owner_uid%%$'\n'*}"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "Warning: $file is owned by UID $owner_uid but current UID is $current_uid; ignoring response to prevent injection." >&2
    return 1
  fi
  return 0
}

ralph_remove_human_action_file() {
  if [[ -f "$HUMAN_ACTION_FILE" ]]; then
    rm -f "$HUMAN_ACTION_FILE"
    ralph_run_plan_log "Removed human action file: $HUMAN_ACTION_FILE"
  fi
}

ralph_write_human_action_file() {
  local question="${1:-}"
  if [[ -z "$question" && -f "$PENDING_HUMAN" ]]; then
    question="$(<"$PENDING_HUMAN")"
  fi
  [[ -n "$question" ]] || return 0

  local history="(no operator replies recorded yet)"
  if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
    history="$(<"$HUMAN_CONTEXT")"
  fi

  local restart_hint
  restart_hint="$(ralph_restart_command_hint)"

  {
    printf '# HUMAN ACTION REQUIRED\n\n'
    printf 'The agent paused this plan step until your response.\n\n'
    printf '## Plan file\n%s\n\n' "$PLAN_PATH"
    printf '## Question from the agent\n\n%s\n\n' "$question"
    printf '## What to do\n'
    printf '1. Open %s and replace the placeholder line with your full answer.\n' "$OPERATOR_RESPONSE_FILE"
    printf '2. Save the file and leave pending-human.txt untouched; it will clear automatically after the answer is applied.\n'
    printf '3. If the plan runner is still running, it continues when you save. Otherwise restart: %s\n\n' "$restart_hint"
    printf '## Session\n'
    printf -- '- Pending question: %s\n' "$PENDING_HUMAN"
    if [[ -n "${HUMAN_REQUEST_FILE:-}" ]]; then
      printf -- '- Human request record: %s\n' "$HUMAN_REQUEST_FILE"
    fi
    printf -- '- Session directory: %s\n' "$RALPH_SESSION_DIR"
    printf -- '- Plan log: %s\n' "$LOG_FILE"
    printf -- '- Output log: %s\n\n' "$OUTPUT_LOG"
    printf '## Previous operator replies\n\n%s\n' "$history"
  } >"$HUMAN_ACTION_FILE"
  ralph_run_plan_log "Wrote human action file: $HUMAN_ACTION_FILE"
}

ralph_prepare_permission_pause() {
  local line_num="${1:?}"
  local todo_text="${2:?}"
  local plan_path="${3:?}"
  local runtime="${4:?}"
  local classification="${5:?}"
  local denial_excerpt="${6:-}"
  local blocked_cmd="${7:-}"
  local blocked_path="${8:-}"
  local blocked_tool="${9:-}"
  local hint=""
  local resume_cmd=""
  local prompt_text=""

  if declare -F ralph_permission_hint >/dev/null 2>&1; then
    hint="$(ralph_permission_hint "$classification" "$runtime" "$blocked_cmd" "$denial_excerpt" 2>/dev/null || true)"
  fi
  if declare -F ralph_restart_command_hint >/dev/null 2>&1; then
    resume_cmd="$(ralph_restart_command_hint)"
  fi
  if declare -F ralph_build_permission_operator_brief >/dev/null 2>&1; then
    prompt_text="$(ralph_build_permission_operator_brief \
      "$line_num" \
      "$todo_text" \
      "$plan_path" \
      "$runtime" \
      "$classification" \
      "$hint" \
      "$resume_cmd" \
      "$denial_excerpt" \
      "$blocked_cmd" \
      "$blocked_path")"
  else
    prompt_text="Permission block (${classification}) on line ${line_num}: ${todo_text}"
  fi

  printf '%s\n' "$prompt_text" >"$PENDING_HUMAN"
  # Record which graph run owns this pause so a later run does not inherit a
  # question only this run can answer. See
  # ralph_session_discard_foreign_run_pause.
  if [[ -n "${RALPH_GRAPH_RUN_ID:-}" && -n "${PENDING_HUMAN_OWNER:-}" ]]; then
    printf '%s\n' "$RALPH_GRAPH_RUN_ID" >"$PENDING_HUMAN_OWNER"
  fi
  if declare -F ralph_write_human_request_artifact >/dev/null 2>&1; then
    ralph_write_human_request_artifact \
      "$RALPH_SESSION_DIR" \
      "permission" \
      "$runtime" \
      "$line_num" \
      "$todo_text" \
      "$todo_text" \
      "$classification" \
      "$blocked_cmd" \
      "$blocked_path" \
      "$blocked_tool" \
      "$prompt_text" \
      "$denial_excerpt" \
      "$hint" \
      "$resume_cmd" \
      "$prompt_text" >/dev/null 2>&1 || true
  fi
  if declare -F ralph_write_operator_response_template >/dev/null 2>&1; then
    ralph_write_operator_response_template "${HUMAN_REQUEST_FILE:-$RALPH_SESSION_DIR/human-request.json}" "$OPERATOR_RESPONSE_FILE"
  fi
  if declare -F ralph_should_persist_human_files >/dev/null 2>&1; then
    if ralph_should_persist_human_files; then
      ralph_write_human_action_file "$prompt_text"
    else
      ralph_remove_human_action_file
    fi
  fi
  ralph_run_plan_log "permission block classified as $classification; wrote pending-human and waiting for operator response"
}

ralph_sync_human_action_file_state() {
  if [[ -f "$PENDING_HUMAN" ]] && ! ralph_operator_has_real_answer; then
    if ralph_should_persist_human_files; then
      ralph_write_human_action_file
    else
      ralph_remove_human_action_file
    fi
  else
    ralph_remove_human_action_file
  fi
}

ralph_try_consume_human_response() {
  if [[ -f "$PENDING_HUMAN" ]] && ralph_operator_has_real_answer; then
    if ! ralph_operator_response_file_owned_by_current_user "$OPERATOR_RESPONSE_FILE"; then
      ralph_run_plan_log "Operator response rejected because $OPERATOR_RESPONSE_FILE is not owned by current user"
      return 1
    fi
    local _pq _pa
    _pq="$(<"$PENDING_HUMAN")"
    _pa="$(<"$OPERATOR_RESPONSE_FILE")"
    {
      echo ""
      echo "### $(date '+%Y-%m-%d %H:%M:%S')"
      echo "**Agent asked:**"
      echo "$_pq"
      echo "**Operator answered:**"
      echo "$_pa"
    } >>"$HUMAN_CONTEXT"

    local _request_file="${HUMAN_REQUEST_FILE:-$RALPH_SESSION_DIR/human-request.json}"
    local _request_kind="guidance"
    local _request_runtime=""
    local _request_classification=""
    local _request_blocked_cmd=""
    local _request_blocked_tool=""
    local _request_blocked_path=""
    local _request_question=""
    if [[ -f "$_request_file" ]]; then
      _request_kind="$(ralph_json_field "$_request_file" kind 2>/dev/null || printf 'guidance')"
      _request_runtime="$(ralph_json_field "$_request_file" runtime 2>/dev/null || true)"
      _request_classification="$(ralph_json_field "$_request_file" classification 2>/dev/null || true)"
      _request_blocked_cmd="$(ralph_json_field "$_request_file" blocked_command_or_tool 2>/dev/null || true)"
      _request_blocked_tool="$(ralph_json_field "$_request_file" blocked_tool 2>/dev/null || true)"
      _request_blocked_path="$(ralph_json_field "$_request_file" blocked_path 2>/dev/null || true)"
      _request_question="$(ralph_json_field "$_request_file" question 2>/dev/null || true)"
    elif [[ -f "$RALPH_SESSION_DIR/permission-remediation.json" ]]; then
      _request_kind="permission"
      _request_runtime="$(ralph_json_field "$RALPH_SESSION_DIR/permission-remediation.json" runtime 2>/dev/null || true)"
      _request_classification="$(ralph_json_field "$RALPH_SESSION_DIR/permission-remediation.json" classification 2>/dev/null || true)"
      _request_blocked_cmd="$(ralph_json_field "$RALPH_SESSION_DIR/permission-remediation.json" blocked_command_or_tool 2>/dev/null || true)"
      _request_blocked_tool="$(ralph_json_field "$RALPH_SESSION_DIR/permission-remediation.json" blocked_tool 2>/dev/null || true)"
      _request_blocked_path="$(ralph_json_field "$RALPH_SESSION_DIR/permission-remediation.json" blocked_path 2>/dev/null || true)"
    fi

    local _response_decision="unknown"
    local _response_runtime="$_request_runtime"
    local _response_classification="$_request_classification"
    local _response_blocked_cmd="$_request_blocked_cmd"
    local _response_blocked_path="$_request_blocked_path"
    local _response_blocked_tool="$_request_blocked_tool"
    local _response_reason=""
    if [[ "$_pa" =~ ^\{ ]]; then
      _response_decision="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" decision 2>/dev/null || true)"
      _response_runtime="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" runtime 2>/dev/null || true)"
      _response_classification="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" classification 2>/dev/null || true)"
      _response_blocked_cmd="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" blocked_command_or_tool 2>/dev/null || true)"
      _response_blocked_path="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" blocked_path 2>/dev/null || true)"
      _response_blocked_tool="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" blocked_tool 2>/dev/null || true)"
      _response_reason="$(ralph_json_field "$OPERATOR_RESPONSE_FILE" reason 2>/dev/null || true)"
      if [[ -z "$_response_decision" ]]; then
        _response_decision="$(ralph_permission_operator_response_decision "$_pa")"
      fi
    else
      _response_decision="$(ralph_permission_operator_response_decision "$_pa")"
    fi

    ralph_human_continuation_finalize_success() {
      local _route="${1:-generic}" _perm_decision="${2:-}"
      if declare -F ralph_human_continuation_persist >/dev/null 2>&1; then
        ralph_human_continuation_persist "$_route" "$_perm_decision" >/dev/null \
          || ralph_run_plan_log "WARN: human-answer continuation record not persisted"
      fi
      rm -f "$PENDING_HUMAN" "$OPERATOR_RESPONSE_FILE"
    }

    if [[ "$_request_kind" == "permission" ]] || [[ -n "$_response_classification" ]] || [[ -n "$_response_blocked_cmd" ]] || [[ -n "$_response_blocked_path" ]] || [[ -n "$_response_blocked_tool" ]]; then
      if [[ "$_response_decision" == "allow" ]] && declare -F ralph_apply_permission_operator_response >/dev/null 2>&1; then
        local _permission_apply_result_file
        _permission_apply_result_file="$(mktemp)"
        if ralph_apply_permission_operator_response \
          "$RALPH_SESSION_DIR" \
          "$_response_runtime" \
          "$_response_classification" \
          "$_response_blocked_cmd" \
          "$_response_blocked_path" \
          "$_response_blocked_tool" \
          "$_pa" >"$_permission_apply_result_file" 2>/dev/null; then
          _response_decision="$(<"$_permission_apply_result_file")"
        else
          _response_decision="unknown"
        fi
        rm -f "$_permission_apply_result_file"
      fi
      case "$_response_decision" in
        allow)
          ralph_run_plan_log "Operator allowed human request; prepared ${OPENCODE_PLAN_PERMISSION_CONFIG_PATH:-OpenCode permission overlay}"
          if [[ -n "${RALPH_PERMISSION_APPLY_DEGRADED:-}" ]]; then
            ralph_run_plan_log "WARN: permission approved but overlay setup was incomplete (${RALPH_PERMISSION_APPLY_DEGRADED}); the runtime may block the same action again"
            echo -e "${C_Y}Permission approved. Note: could not fully record the exception (${RALPH_PERMISSION_APPLY_DEGRADED}); the runtime may block the same action again.${C_RST}" >&2
          fi
          RALPH_PERMISSION_RESPONSE_DECISION="allow"
          export RALPH_PERMISSION_RESPONSE_DECISION
          ralph_human_continuation_finalize_success "permission" "allow"
          ralph_run_plan_log "Applied structured human response; continuing plan run"
          return 0
          ;;
        deny)
          ralph_run_plan_log "Operator denied human request; TODO will remain open"
          RALPH_PERMISSION_RESPONSE_DECISION="deny"
          export RALPH_PERMISSION_RESPONSE_DECISION
          # A deny stops this run only. Leaving the request on disk would make
          # every later run consume the same stale answer and exit immediately
          # without ever prompting, with no way for the operator to recover.
          rm -f "$PENDING_HUMAN" "$OPERATOR_RESPONSE_FILE"
          return 0
          ;;
        *)
          ralph_run_plan_log "Structured permission response did not include allow/deny; leaving request in place"
          return 1
          ;;
      esac
    fi

    if [[ "$_request_kind" != "permission" ]] && [[ -n "$_request_question" ]]; then
      ralph_human_continuation_finalize_success "guidance" ""
      ralph_run_plan_log "Applied guidance answer from operator-response.txt; continuing plan run"
      return 0
    fi

    ralph_human_continuation_finalize_success "generic" ""
    ralph_run_plan_log "Applied answer from operator-response.txt; continuing plan run"
    return 0
  fi
  return 1
}

ralph_human_input_write_offline_instructions() {
  local _iu _ir _cmd_hint
  local _request_file="${HUMAN_REQUEST_FILE:-$RALPH_SESSION_DIR/human-request.json}"
  local _request_kind="guidance"
  _iu="$(ralph_path_to_file_uri "$HUMAN_INPUT_MD")"
  _ir="$(ralph_path_to_file_uri "$OPERATOR_RESPONSE_FILE")"
  _cmd_hint="$(ralph_restart_command_hint)"
  if [[ -f "$_request_file" ]]; then
    _request_kind="$(ralph_json_field "$_request_file" kind 2>/dev/null || printf 'guidance')"
  elif [[ -f "$RALPH_SESSION_DIR/permission-remediation.json" ]]; then
    _request_file="$RALPH_SESSION_DIR/permission-remediation.json"
    _request_kind="permission"
  fi

  local _permission_tty_ok=0
  if [[ -t 0 ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; then
    _permission_tty_ok=1
  fi
  if [[ "$_request_kind" == "permission" ]] && { [[ -n "${RALPH_PERMISSION_PREAPPROVED_DECISION:-}" ]] || [[ "$_permission_tty_ok" == "1" ]]; }; then
    local _permission_decision=""
    local _permission_prompt=""
    local _permission_runtime=""
    local _permission_classification=""
    local _permission_blocked_cmd=""
    local _permission_blocked_tool=""
    local _permission_blocked_path=""
    if [[ -f "$_request_file" ]]; then
      _permission_runtime="$(ralph_json_field "$_request_file" runtime 2>/dev/null || true)"
      _permission_classification="$(ralph_json_field "$_request_file" classification 2>/dev/null || true)"
      _permission_blocked_cmd="$(ralph_json_field "$_request_file" blocked_command_or_tool 2>/dev/null || true)"
      _permission_blocked_tool="$(ralph_json_field "$_request_file" blocked_tool 2>/dev/null || true)"
      _permission_blocked_path="$(ralph_json_field "$_request_file" blocked_path 2>/dev/null || true)"
    fi
    _permission_prompt=$'Permission request paused the plan.\n'
    if [[ -n "${_permission_runtime:-}" ]]; then
      _permission_prompt+="Runtime: ${_permission_runtime}"$'\n'
    fi
    if [[ -n "${_permission_classification:-}" ]]; then
      _permission_prompt+="Classification: ${_permission_classification}"$'\n'
    fi
    if [[ -n "${_permission_blocked_tool:-}" ]]; then
      _permission_prompt+="Blocked tool: ${_permission_blocked_tool}"$'\n'
    fi
    if [[ -n "${_permission_blocked_cmd:-}" ]]; then
      _permission_prompt+="Blocked command: ${_permission_blocked_cmd}"$'\n'
    fi
    if [[ -n "${_permission_blocked_path:-}" ]]; then
      _permission_prompt+="Blocked path: ${_permission_blocked_path}"$'\n'
    fi
    if [[ -n "${RALPH_PERMISSION_PREAPPROVED_DECISION:-}" ]]; then
      _permission_decision="$RALPH_PERMISSION_PREAPPROVED_DECISION"
      ralph_run_plan_log "Permission request auto-answered '${_permission_decision}' from RALPH_PERMISSION_RESPONSE_DECISION"
      printf '%sPermission request auto-answered: %s (RALPH_PERMISSION_RESPONSE_DECISION)\n' \
        "$_permission_prompt" "$_permission_decision" >&2
    else
      _permission_prompt+=$'\nAllow this permission request? [y/N]: '
      local _permission_read_rc=0
      _permission_decision="$(ralph_permission_prompt_operator_decision "$_permission_prompt")" \
        || _permission_read_rc=$?
      if [[ "$_permission_read_rc" -ne 0 ]]; then
        # EOF or a read error is not an operator answer. Recording it as a deny
        # would both stop the run and misreport who decided.
        ralph_run_plan_log "WARN: permission prompt read failed (rc=$_permission_read_rc); no operator answer captured"
        return 1
      fi
    fi
    if declare -F ralph_write_operator_response_template >/dev/null 2>&1; then
      ralph_write_operator_response_template "$_request_file" "$OPERATOR_RESPONSE_FILE"
    fi
    jq -n \
      --arg kind "permission" \
      --arg decision "$_permission_decision" \
      --arg runtime "${_permission_runtime:-}" \
      --arg classification "${_permission_classification:-}" \
      --arg blocked_command_or_tool "${_permission_blocked_cmd:-}" \
      --arg blocked_path "${_permission_blocked_path:-}" \
      --arg blocked_tool "${_permission_blocked_tool:-}" \
      --arg reason "terminal bridge response" \
      '{placeholder: false, kind: $kind, decision: $decision, runtime: $runtime, classification: $classification, blocked_command_or_tool: $blocked_command_or_tool, blocked_path: $blocked_path, blocked_tool: $blocked_tool, reason: $reason, answer: ""}' >"$OPERATOR_RESPONSE_FILE"
    if ralph_try_consume_human_response; then
      return 0
    fi
    return 1
  fi

  if [[ "$_request_kind" != "permission" ]] \
    && { [[ -n "${RALPH_GUIDANCE_RESPONSE_ANSWER:-}" ]] || [[ "$_permission_tty_ok" == "1" ]]; } \
    && [[ -f "$PENDING_HUMAN" ]] && [[ -s "$PENDING_HUMAN" ]] \
    && declare -F ralph_guidance_prompt_operator_answer >/dev/null 2>&1; then
    local _guidance_question _guidance_prompt _guidance_answer _guidance_read_rc=0
    _guidance_question="$(<"$PENDING_HUMAN")"
    _guidance_prompt=$'\nGuidance requested -- the plan is paused waiting for your answer.\n\n'
    _guidance_prompt+="${_guidance_question}"$'\n\n'
    _guidance_prompt+=$'Type your answer and press Enter (leave blank to fall back to editing operator-response.txt): '
    _guidance_answer="$(ralph_guidance_prompt_operator_answer "$_guidance_prompt")" || _guidance_read_rc=$?
    if [[ "$_guidance_read_rc" -eq 0 ]] && [[ -n "$_guidance_answer" ]]; then
      if declare -F ralph_write_operator_response_template >/dev/null 2>&1; then
        ralph_write_operator_response_template "$_request_file" "$OPERATOR_RESPONSE_FILE"
      fi
      jq -n \
        --arg answer "$_guidance_answer" \
        '{placeholder: false, kind: "guidance", decision: "answer", runtime: "", classification: "", blocked_command_or_tool: "", blocked_path: "", blocked_tool: "", reason: "terminal bridge response", answer: $answer}' \
        >"$OPERATOR_RESPONSE_FILE"
      if ralph_try_consume_human_response; then
        return 0
      fi
      return 1
    fi
    ralph_run_plan_log "WARN: guidance prompt read failed or was left blank (rc=$_guidance_read_rc); falling back to file-based instructions"
  fi

  if [[ "$_request_kind" != "permission" ]] && declare -F ralph_write_human_request_artifact >/dev/null 2>&1; then
    ralph_write_human_request_artifact \
      "$RALPH_SESSION_DIR" \
      "guidance" \
      "${RUNTIME:-}" \
      "0" \
      "$(<"$PENDING_HUMAN")" \
      "$(<"$PENDING_HUMAN")" \
      "" \
      "" \
      "" \
      "" \
      "$(<"$PENDING_HUMAN")" \
      "" \
      "" \
      "$_cmd_hint" \
      "$(<"$PENDING_HUMAN")" >/dev/null 2>&1 || true
  fi
  if declare -F ralph_write_operator_response_template >/dev/null 2>&1; then
    ralph_write_operator_response_template "$_request_file" "$OPERATOR_RESPONSE_FILE"
  fi
  {
    echo "# Paused for human input"
    echo ""
    echo "The plan runner wrote a structured human-request record and will resume on the next invocation after you answer."
  echo ""
  echo "## Question from the agent"
  echo ""
  printf '%s\n' "$(<"$PENDING_HUMAN")"
  echo ""
    echo "## What to do"
    echo ""
    echo "1. Open **operator-response.txt** in this folder and replace the JSON template with your answer. Remove the \`placeholder\` field or set it to \`false\`."
    echo "2. Save the file. The next run will consume the structured response and continue."
    echo "3. If this process is no longer running, restart with: ${_cmd_hint}"
    echo ""
    echo "## Clickable links (terminal or browser address bar)"
    echo ""
    echo "- This instruction page: ${_iu}"
    echo "- Your answer file (edit here): ${_ir}"
    echo ""
    echo "## Paths"
    echo ""
    echo "- Session directory: $RALPH_SESSION_DIR"
    echo "- Plan file: $PLAN_PATH"
    if [[ -n "${HUMAN_REQUEST_FILE:-}" ]]; then
      echo "- Human request record: $HUMAN_REQUEST_FILE"
    fi
  } >"$HUMAN_INPUT_MD"

  if declare -F ralph_forward_human_question_to_orchestrator >/dev/null 2>&1; then
    if [[ "$_request_kind" == "permission" ]]; then
      export RALPH_HUMAN_QUESTION_KIND=permission
      if ralph_forward_human_question_to_orchestrator "$PENDING_HUMAN" "$PLAN_PATH"; then
        ralph_run_plan_log "Forwarded permission pause via human-ack bridge"
      else
        ralph_run_plan_log "human-ack bridge unavailable or failed for permission pause; falling back to file-based instructions"
      fi
      unset RALPH_HUMAN_QUESTION_KIND 2>/dev/null || true
    elif ralph_run_plan_workflow_operator_input_active 2>/dev/null; then
      unset RALPH_HUMAN_QUESTION_KIND 2>/dev/null || true
      if ralph_forward_human_question_to_orchestrator "$PENDING_HUMAN" "$PLAN_PATH"; then
        ralph_run_plan_log "Forwarded operator input via workflow common action request"
      else
        ralph_run_plan_log "workflow action request unavailable; falling back to file-based instructions"
      fi
    fi
  fi

  if [[ ! -f "$OPERATOR_RESPONSE_FILE" ]] || [[ ! -s "$OPERATOR_RESPONSE_FILE" ]]; then
    ralph_write_operator_response_template "${HUMAN_REQUEST_FILE:-$RALPH_SESSION_DIR/human-request.json}" "$OPERATOR_RESPONSE_FILE"
  fi
  ralph_write_human_action_file
  ralph_run_plan_log "Wrote offline human instructions: $HUMAN_INPUT_MD"

  echo "" >&2
  echo -e "${C_Y}${C_BOLD}Paused for human input (no TTY).${C_RST}" >&2
  echo "  Instruction page: ${_iu}" >&2
  echo "  Answer file: ${_ir}" >&2
  echo "  Log: $LOG_FILE" >&2

  if [[ "$(uname -s)" == "Darwin" ]] && [[ "$HUMAN_PROMPT_NO_OPEN_FLAG" != "1" ]] && command -v open &>/dev/null; then
    open "$HUMAN_INPUT_MD" 2>/dev/null || true
    echo "  (Opened HUMAN-INPUT-REQUIRED.md in your default app.)" >&2
  fi
}

# When stdin is not a TTY, write the request artifacts once and stop.
# Exception: if a TTY is available for a permission request and the operator
# responds (allow or deny), return 0 so the main loop can continue.
ralph_human_pause_for_operator_offline() {
  if ralph_human_input_write_offline_instructions; then
    if [[ "${RALPH_PERMISSION_RESPONSE_DECISION:-}" == "allow" ]] || [[ "${RALPH_PERMISSION_RESPONSE_DECISION:-}" == "deny" ]]; then
      return 0
    fi
  fi
  echo "" >&2
  echo "Permission response was not captured (terminal may not be interactive or read returned empty)." >&2
  echo "Re-run the plan to get a fresh prompt, or set RALPH_PERMISSION_RESPONSE_DECISION=allow before re-running." >&2
  ralph_run_plan_log "EXIT 4: human input required (one-shot request written)"
  read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
  if declare -F _ralph_write_plan_usage_summary >/dev/null 2>&1; then
    _ralph_write_plan_usage_summary "$done_count" "$total_count"
  fi
  exit 4
}

# Capture an operator-supplied pre-approval before the per-request resets below
# clear it. This is the non-interactive escape hatch: exporting
# RALPH_PERMISSION_RESPONSE_DECISION=allow (or deny) answers every permission
# prompt for the whole run, including runs with no TTY.
RALPH_PERMISSION_PREAPPROVED_DECISION="$(printf '%s' "${RALPH_PERMISSION_RESPONSE_DECISION:-}" | tr '[:upper:]' '[:lower:]')"
case "$RALPH_PERMISSION_PREAPPROVED_DECISION" in
  allow|deny) ;;
  *) RALPH_PERMISSION_PREAPPROVED_DECISION="" ;;
esac
export RALPH_PERMISSION_PREAPPROVED_DECISION

RALPH_PERMISSION_RESPONSE_DECISION=""
if ralph_try_consume_human_response; then
  if [[ "${RALPH_PERMISSION_RESPONSE_DECISION:-}" == "deny" ]]; then
    read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
    echo "" >&2
    echo -e "${C_R}${C_BOLD}Permission request was denied by the operator; stopping plan run.${C_RST}" >&2
    echo -e "${C_DIM}Plan: $PLAN_PATH${C_RST}" >&2
    echo -e "${C_DIM}Re-run the same command to retry; you will be prompted again. Pre-approve with RALPH_PERMISSION_RESPONSE_DECISION=allow.${C_RST}" >&2
    if declare -F _ralph_write_plan_usage_summary >/dev/null 2>&1; then
      _ralph_write_plan_usage_summary "$done_count" "$total_count"
    fi
    ralph_runtime_overlay_cleanup_if_needed
    exit 1
  fi
  :
elif [[ ! -f "$PENDING_HUMAN" ]]; then
  : >"$HUMAN_CONTEXT"
  rm -f "$OPERATOR_RESPONSE_FILE" "$HUMAN_INPUT_MD" "$HUMAN_REQUEST_FILE" "$RALPH_SESSION_DIR/permission-remediation.json"
fi

ralph_sync_human_action_file_state

if [[ -f "$PENDING_HUMAN" ]] && ! ralph_operator_has_real_answer; then
  ralph_human_pause_for_operator_offline
fi

ralph_run_plan_log "session dir=$RALPH_SESSION_DIR"

ralph_session_prompt_cli_resume
# Session strategy is interactive when unset on TTY; CLI resume flag is derived for compatibility.
export RALPH_PLAN_SESSION_STRATEGY
ralph_session_derive_cli_resume
export RALPH_PLAN_CLI_RESUME

# Load workspace preferences if RALPH_MODE is not yet resolved.
if [[ -z "${RALPH_MODE:-}" ]]; then
  ralph_load_workspace_preferences "$WORKSPACE" "$RALPH_PLAN_WORKSPACE_ROOT"
fi

# Prompt interactively if RALPH_MODE is still unresolved on a TTY.
if [[ -z "${RALPH_MODE:-}" && -t 0 && -t 1 && "$NON_INTERACTIVE_FLAG" != "1" ]]; then
  if declare -F prompt_ralph_mode >/dev/null 2>&1; then
    prompt_ralph_mode || true
  fi
fi

# Default to no if still unresolved.
if [[ -z "${RALPH_MODE:-}" ]]; then
  RALPH_MODE="no"
fi
export RALPH_MODE

# Derive internal knobs from RALPH_MODE for downstream code compatibility.
if declare -F ralph_apply_ralph_mode_to_knobs >/dev/null 2>&1; then
  ralph_apply_ralph_mode_to_knobs "$RALPH_MODE"
fi
export RALPH_AGENT_TOOL_ACCESS
export RALPH_NATIVE_HOOKS

if [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" == "ralph" ]]; then
  RALPH_MCP_TOOLS_ENABLED=1
else
  RALPH_MCP_TOOLS_ENABLED=0
fi
export RALPH_MCP_TOOLS_ENABLED

ralph_run_plan_log "Ralph Mode: $RALPH_MODE"

# Apply default shell compaction based on Ralph mode.
# Must be called after RALPH_MODE is finalized.
if declare -F ralph_apply_shell_compact_defaults >/dev/null 2>&1; then
  ralph_apply_shell_compact_defaults || true
fi

ralph_run_plan_log "Shell Compaction: ${RALPH_PROXY_SHELL_COMPACT:-unset}"
ralph_run_plan_log "Transcript Eviction: ${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"


ralph_run_plan_log_tool_access_breakdown() {
  local usage_file="${1:-}"
  if [[ ! -f "$usage_file" ]]; then
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    return 0
  fi
    local breakdown py_exit=0
    breakdown="$(
      PYTHONPATH="$SCRIPT_DIR/python" python3 "$SCRIPT_DIR/python/ralph-tool-access-breakdown.py" "$usage_file"
    )" || py_exit=1
  local line hint_line="" warning_line=""
  ralph_efficiency_hint_clear
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ralph_run_plan_log "$line"
    echo "$line"
    if [[ -z "$hint_line" && "$line" == HINT:* ]]; then
      hint_line="$line"
    fi
    if [[ -z "$warning_line" && "$line" == WARNING:* ]]; then
      warning_line="$line"
    fi
  done <<< "$breakdown"
  if [[ -n "$hint_line" ]]; then
    ralph_efficiency_hint_store "$hint_line"
  elif [[ -n "$warning_line" ]]; then
    ralph_efficiency_hint_store "$warning_line"
  fi
  [ "$py_exit" -eq 0 ] || return 1
}

ralph_run_plan_opencode_strict_proxy_preflight() {
  # Preflight check for OpenCode with strict proxy enforcement.
  # OpenCode cannot block native tools before execution, so strict mode must fail
  # before the CLI is invoked to avoid wasting an entire invocation.
  if [[ "${RALPH_AGENT_TOOL_ACCESS:-}" != "ralph" ]]; then
    return 0
  fi
  if [[ "$RUNTIME" != "opencode" ]]; then
    return 0
  fi
  local is_strict=0
  if [[ "${RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY:-0}" == "1" ]]; then
    is_strict=1
  fi
  if [[ "${RALPH_STRICT_PROXY:-0}" == "1" ]]; then
    is_strict=1
  fi
  if [[ "$is_strict" != "1" ]]; then
    return 0
  fi
  if [[ "${RALPH_OPENCODE_ALLOW_STRICT_PROXY_BESTEFFORT:-0}" == "1" ]]; then
    ralph_run_plan_log "WARNING: OpenCode strict proxy enforcement downgraded to best-effort audit/warning (RALPH_OPENCODE_ALLOW_STRICT_PROXY_BESTEFFORT=1)"
    return 0
  fi
  echo "Error: Strict proxy enforcement (RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=1 or RALPH_STRICT_PROXY=1) is not supported for OpenCode." >&2
  echo "Reason: OpenCode cannot block native tools before execution, so strict mode would waste a full invocation if a native tool is used." >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  1. Switch to a runtime that supports strict proxy enforcement:" >&2
  echo "     - Claude (via --runtime claude)" >&2
  echo "     - Cursor (via --runtime cursor)" >&2
  echo "  2. Disable strict proxy enforcement:" >&2
  echo "     - Set RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=0" >&2
  echo "     - Or use --tool-access native to disable Ralph MCP" >&2
  echo "  3. Accept best-effort audit/warning behavior (post-execution):" >&2
  echo "     - Set RALPH_OPENCODE_ALLOW_STRICT_PROXY_BESTEFFORT=1" >&2
  echo "" >&2
  ralph_run_plan_log "ERROR: Strict proxy mode not supported for OpenCode before CLI invocation"
  exit 1
}

ralph_run_plan_mcp_preflight_or_exit() {
  if [[ "${RALPH_AGENT_TOOL_ACCESS:-}" != "ralph" ]]; then
    return 0
  fi
  local server_script preflight_msg
  if ! server_script="$(ralph_mcp_server_script_path "$WORKSPACE")"; then
    echo "Error: could not resolve Ralph MCP server script for workspace $WORKSPACE." >&2
    ralph_run_plan_log "ERROR: MCP server script resolution failed"
    exit 1
  fi
  ralph_run_plan_log "MCP server script: $server_script plan_key=${RALPH_PLAN_KEY:-}"

  case "${RALPH_SKIP_MCP_PREFLIGHT:-${SKIP_MCP_PREFLIGHT_FLAG:-0}}" in
    1|true|yes|on)
      ralph_run_plan_log "MCP preflight skipped (--skip-mcp-preflight or RALPH_SKIP_MCP_PREFLIGHT=1)"
      export RALPH_MCP_PREFLIGHT_PASSED=0
      export RALPH_MCP_PREFLIGHT_OUTCOME="skipped"
      return 0
      ;;
  esac

  ralph_run_plan_log "running MCP preflight handshake"
  if ! preflight_msg="$(ralph_mcp_preflight "$server_script" "$WORKSPACE" 2>&1)"; then
    echo "$preflight_msg" >&2
    echo "Error: Agent Tool Access (ralph) aborted because MCP preflight failed. Fix the issue above or re-run with --tool-access native. Manual check: RALPH_MCP_WORKSPACE=\"$WORKSPACE\" bash \"$server_script\"" >&2
    ralph_run_plan_log "ERROR: MCP preflight failed"
    exit 1
  fi
  ralph_run_plan_log "MCP preflight: ${preflight_msg:-OK}"
  export RALPH_MCP_PREFLIGHT_PASSED=1
  export RALPH_MCP_PREFLIGHT_OUTCOME="passed"
  # RALPH_MCP_TOOL_NAMESPACE is set by ralph_mcp_proxy_preflight during the
  # deterministic handshake; export it for downstream use in allowedTools and prompts.
  if [[ -n "${RALPH_MCP_TOOL_NAMESPACE:-}" ]]; then
    ralph_run_plan_log "MCP tool namespace detected: ${RALPH_MCP_TOOL_NAMESPACE}"
  fi

  # Opt-in end-to-end gate: actually drive the claude CLI and confirm it can reach
  # a ralph proxy tool. The deterministic preflight above only validates the bash
  # server's responses; this catches client-side regressions in claude itself.
  case "${RALPH_MCP_CLI_PREFLIGHT:-0}" in
    1|true|yes|on)
      if [[ "$RUNTIME" != "claude" ]]; then
        ralph_run_plan_log "RALPH_MCP_CLI_PREFLIGHT set but runtime=$RUNTIME (claude-only); skipping live gate"
      else
        ralph_run_plan_log "running live claude CLI MCP preflight (RALPH_MCP_CLI_PREFLIGHT=1)"
        local cli_msg cli_rc
        cli_msg="$(ralph_mcp_claude_cli_preflight "$WORKSPACE" "${SELECTED_MODEL:-}" 2>&1)"
        cli_rc=$?
        [[ -n "$cli_msg" ]] && ralph_run_plan_log "$cli_msg"
        case "$cli_rc" in
          0)
            ralph_run_plan_log "live claude CLI MCP preflight: ralph tools reachable end-to-end"
            ;;
          1)
            echo "$cli_msg" >&2
            echo "Error: Agent Tool Access (ralph) aborted because claude could not reach the ralph MCP tools end-to-end. Re-run with --tool-access native, or unset RALPH_MCP_CLI_PREFLIGHT to fall back to the deterministic check only." >&2
            ralph_run_plan_log "ERROR: live claude CLI MCP preflight failed (tools not reachable)"
            exit 1
            ;;
          *)
            ralph_run_plan_log "live claude CLI MCP preflight inconclusive; continuing on deterministic check"
            ;;
        esac
      fi
      ;;
  esac

  # Codex strict proxy: live CLI probe before the real TODO (not opt-in like Claude).
  if [[ "$RUNTIME" == "codex" ]] && ralph_mcp_codex_strict_proxy_active; then
    case "${RALPH_CODEX_ALLOW_STRICT_PROXY_BESTEFFORT:-0}" in
      1|true|yes|on)
        ralph_run_plan_log "WARNING: Codex strict proxy live MCP preflight downgraded to best-effort (RALPH_CODEX_ALLOW_STRICT_PROXY_BESTEFFORT=1)"
        ;;
      *)
        case "${RALPH_CODEX_SKIP_LIVE_MCP_PREFLIGHT:-0}" in
          1|true|yes|on)
            ralph_run_plan_log "Codex live MCP preflight skipped (RALPH_CODEX_SKIP_LIVE_MCP_PREFLIGHT=1)"
            ;;
          *)
            if ! declare -F ralph_mcp_codex_cli_preflight >/dev/null 2>&1; then
              # shellcheck source=/dev/null
              source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-invoke-codex.sh"
            fi
            ralph_run_plan_log "running live Codex CLI MCP preflight (strict proxy)"
            local codex_cli_msg codex_cli_rc
            codex_cli_msg="$(ralph_mcp_codex_cli_preflight "$WORKSPACE" "${SELECTED_MODEL:-}" 2>&1)"
            codex_cli_rc=$?
            [[ -n "$codex_cli_msg" ]] && ralph_run_plan_log "$codex_cli_msg"
            case "$codex_cli_rc" in
              0)
                ralph_run_plan_log "live Codex CLI MCP preflight: ralph_proxy_read reachable end-to-end"
                ;;
              1)
                echo "$codex_cli_msg" >&2
                echo "Error: Agent Tool Access (ralph) aborted because Codex strict proxy preflight failed before the plan invocation. Fix MCP approval/config, re-run with --tool-access native, or set RALPH_CODEX_ALLOW_STRICT_PROXY_BESTEFFORT=1 for a warning-only downgrade." >&2
                ralph_run_plan_log "ERROR: live Codex CLI MCP preflight failed (strict proxy)"
                exit 1
                ;;
              *)
                ralph_run_plan_log "live Codex CLI MCP preflight inconclusive; continuing on deterministic check"
                ;;
            esac
            ;;
        esac
        ;;
    esac
  fi
}

ralph_run_plan_compression_audit() {
  # Non-blocking compression audit mode: estimates savings from historical tool-result blobs.
  # Runs before runtime invocation if RALPH_AUDIT_COMPRESSION=1.
  # Does not modify source files; writes results to discover report or log.
  local audit_script="${SCRIPT_DIR}/python/shell-output-compact-audit.py"
  if [[ ! -f "$audit_script" ]]; then
    ralph_run_plan_log "compression audit: script not found at $audit_script (skipping)"
    return 0
  fi
  if ! command -v python3 &>/dev/null; then
    ralph_run_plan_log "compression audit: python3 not available (skipping)"
    return 0
  fi

  ralph_run_plan_log "compression audit: starting read-only scan of session/log data"
  local audit_output
  audit_output="$(python3 "$audit_script" \
    --workspace "$WORKSPACE" \
    --plan-key "$RALPH_PLAN_KEY" 2>&1)" || true

  if [[ -z "$audit_output" ]]; then
    ralph_run_plan_log "compression audit: no output produced"
    return 0
  fi

  # Parse and log audit results
  local scanned_files total_savings savings_pct record_count
  scanned_files=$(printf '%s' "$audit_output" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('scanned_files', 0))" 2>/dev/null || echo "0")
  total_savings=$(printf '%s' "$audit_output" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('total_potential_savings_bytes', 0))" 2>/dev/null || echo "0")
  savings_pct=$(printf '%s' "$audit_output" | python3 -c "import json, sys; d=json.load(sys.stdin); print(f\"{d.get('total_potential_savings_percent', 0):.1f}\")" 2>/dev/null || echo "0")
  record_count=$(printf '%s' "$audit_output" | python3 -c "import json, sys; d=json.load(sys.stdin); print(len(d.get('records', [])))" 2>/dev/null || echo "0")

  if [[ "$total_savings" != "0" && "$total_savings" != "" ]]; then
    ralph_run_plan_log "compression audit: scanned_files=$scanned_files compressible_outputs=$record_count potential_savings_bytes=$total_savings savings_pct=${savings_pct}%"
  else
    ralph_run_plan_log "compression audit: scanned_files=$scanned_files no compressible outputs found"
  fi

  # Optionally write full results to discover-report or audit log if locations exist
  # This is non-blocking; failures are silently ignored
  if [[ -n "$RALPH_LOG_DIR" && -d "$RALPH_LOG_DIR" ]]; then
    local audit_log="${RALPH_LOG_DIR}/compression-audit-results.json"
    printf '%s\n' "$audit_output" > "$audit_log" 2>/dev/null || true
    [[ -f "$audit_log" ]] && ralph_run_plan_log "compression audit: full results written to $audit_log"
  fi

  return 0
}

mkdir -p "$(dirname "$OUTPUT_LOG")"
{
  echo ""
  echo "################################################################################"
  echo "# Plan runner started $(date '+%Y-%m-%d %H:%M:%S') | workspace=$WORKSPACE"
  echo "# Plan: $PLAN_PATH (log prefix: plan-runner-${PLAN_LOG_NAME})"
  echo "# Ralph Mode: $RALPH_MODE"
  echo "################################################################################"
} >> "$OUTPUT_LOG"

# After this point, offer optional cleanup on exit (logs and Ralph artifacts).
ALLOW_CLEANUP_PROMPT=1
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-plan.sh"
EXIT_STATUS="incomplete"
# shellcheck source=bash-lib/run-plan/run-plan-cleanup.sh
source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-cleanup.sh"
if [[ "${_RALPH_RUNTIME_OVERLAY_ACTIVE:-0}" == "1" ]]; then
  ralph_runtime_overlay_chain_exit_trap ralph_run_plan_exit_trap_handler
else
  trap ralph_run_plan_exit_trap_handler EXIT
fi
trap 'ralph_run_plan_interrupt_trap_handler INT' INT
trap 'ralph_run_plan_interrupt_trap_handler TERM' TERM
trap 'ralph_run_plan_interrupt_trap_handler HUP' HUP

# Resolve model: prebuilt profile selection was removed.
PREBUILT_AGENT_CONTEXT=""
RALPH_AGENT_NATIVE_NAME=""
PREBUILT_AGENT=""
CLAUDE_TOOLS_FROM_AGENT=""
RALPH_AGENT_MAX_BUDGET=""
prompt_agent_source_mode "$WORKSPACE"

# Graph/orchestration stage and voter models: stage/voter > saved > native.
# Profile models and global --model / *_PLAN_MODEL are not rungs.
# Attended Claude/Codex leaf resolution prompts with the full saved-model catalog
# (see _select_model_resolve_claude_codex_chain). INTERACTIVE_SELECT_MODEL_FLAG
# remains a one-shot override used only when explicitly set by callers.
if [[ "${RALPH_MODEL_SCOPE:-}" == "staged" ]]; then
  SELECTED_MODEL="$(ralph_resolve_staged_plan_model "$RUNTIME" "${PLAN_STAGE_MODEL:-}")" || {
    if [[ "$RUNTIME" == "claude" || "$RUNTIME" == "codex" ]]; then
      ralph_run_plan_die_unresolved_claude_codex_model "$RUNTIME"
    fi
    echo -e "${C_R}Could not resolve staged model for runtime${C_RST} $RUNTIME" >&2
    exit 1
  }
  ralph_run_plan_log "staged model (stage/voter > saved > native): ${SELECTED_MODEL:-native default} stage_model=${PLAN_STAGE_MODEL:-}"
elif [[ "$RUNTIME" == "claude" || "$RUNTIME" == "codex" ]]; then
  if [[ "${INTERACTIVE_SELECT_MODEL_FLAG:-0}" == "1" ]]; then
    # Explicit force: show the picker even if a CLI/TODO pin exists upstream.
    case "$RUNTIME" in
      claude) SELECTED_MODEL="$(_claude_select_model_interactive)" ;;
      codex)  SELECTED_MODEL="$(_codex_select_model_interactive)" ;;
    esac
    SELECTED_MODEL="$(tr -d '\r' <<<"${SELECTED_MODEL:-}")"
    [[ -n "$SELECTED_MODEL" ]] || ralph_run_plan_die_unresolved_claude_codex_model "$RUNTIME"
    ralph_run_plan_log "interactive model selection: $SELECTED_MODEL"
  else
    SELECTED_MODEL="$(ralph_resolve_claude_codex_plan_model "$RUNTIME" "")" || {
      ralph_run_plan_die_unresolved_claude_codex_model "$RUNTIME"
    }
    ralph_run_plan_log "using model: $SELECTED_MODEL"
  fi
  elif [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    SELECTED_MODEL="$PLAN_MODEL_CLI"
    ralph_run_plan_log "using CLI --model: $SELECTED_MODEL"
  else
    SELECTED_MODEL="$(prompt_for_agent)"
    if [[ -n "$SELECTED_MODEL" ]]; then
      ralph_run_plan_log "using model: $SELECTED_MODEL"
    fi
  fi
  SELECTED_MODEL="$(tr -d '\r' <<<"${SELECTED_MODEL:-}")"
# Pin the resolved model so per-todo routing can reuse it without re-prompting each TODO.
# Staged/generated workflow runs: always pin the stage-resolved SELECTED_MODEL so a
# plan-header leftover cannot become the baseline above stage/invocation defaults.
if [[ "${RALPH_MODEL_SCOPE:-}" == "staged" ]]; then
  PLAN_MODEL_CLI="${SELECTED_MODEL:-}"
elif [[ -z "${PLAN_MODEL_CLI:-}" && -n "${SELECTED_MODEL:-}" ]]; then
  PLAN_MODEL_CLI="$SELECTED_MODEL"
fi
# Clear any one-shot force-picker flag after the baseline selection.
INTERACTIVE_SELECT_MODEL_FLAG=0
# One-time note when model was not specified via --model or plan header, so user knows
# about per-todo overrides. Example: add 'model: <id>' and 'runtime: <name>' to a todo entry.
if [[ -z "${_plan_model_from_cli:-}" && -z "${_plan_header_model:-}" && "${NON_INTERACTIVE_FLAG:-0}" == "0" && -n "${SELECTED_MODEL:-}" ]]; then
  echo -e "${C_DIM}Using '${SELECTED_MODEL}' for all TODOs. To override per-todo, add 'model: <id>' and 'runtime: <name>' fields to a todo entry.${C_RST}" >&2
fi

_prebuilt_agent_reasoning_effort=""
if ! ralph_validate_reasoning_effort_config "${PLAN_REASONING_EFFORT_CLI:-}" "reasoning_effort"; then
  exit 1
fi
if ! ralph_validate_reasoning_effort_config "${_prebuilt_agent_reasoning_effort:-}" "agent reasoning_effort"; then
  exit 1
fi
_reasoning_gate_rc=0
ralph_run_plan_reasoning_effort_enabled || _reasoning_gate_rc=$?
if [[ "$_reasoning_gate_rc" -eq 2 ]]; then
  exit 1
fi
SELECTED_REASONING_EFFORT="$(ralph_resolve_reasoning_effort "$RUNTIME" "${_prebuilt_agent_reasoning_effort:-}")"
SELECTED_REASONING_EFFORT="$(tr -d '\r' <<<"${SELECTED_REASONING_EFFORT:-inherit}")"
export SELECTED_REASONING_EFFORT
RALPH_PLAN_REASONING_EFFORT_RESOLVED="$SELECTED_REASONING_EFFORT"
export RALPH_PLAN_REASONING_EFFORT_RESOLVED
if [[ -n "${PLAN_REASONING_EFFORT_CLI:-}" ]]; then
  ralph_run_plan_log "using CLI --reasoning-effort: $SELECTED_REASONING_EFFORT"
elif [[ -n "$(ralph_reasoning_effort_runtime_env_value "$RUNTIME" 2>/dev/null || true)" ]]; then
  ralph_run_plan_log "runtime env reasoning_effort: $SELECTED_REASONING_EFFORT"
fi

ralph_run_plan_routing_capture_baseline

total_invocations=0
_ralph_opencode_cache_warn_emitted=0
# Running token usage totals (accumulated from per-invocation USAGE_FILE written by demux.py).
_total_input_tokens=0
_total_output_tokens=0
_total_cache_creation_tokens=0
_total_cache_read_tokens=0
_total_max_turn_tokens=0
_plan_start_ts="$(date +%s)"
_plan_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Echo the argument when it is a plain integer or decimal (optionally signed),
# otherwise echo 0. Guards the plan-usage-summary JSON against malformed numeric
# interpolations (for example an empty or whitespace-bearing todo count) that
# would otherwise produce invalid JSON that the benchmark report silently drops.
run_plan_num_or_zero() {
  local _value="$1"
  _value="${_value#"${_value%%[![:space:]]*}"}"
  _value="${_value%"${_value##*[![:space:]]}"}"
  case "$_value" in
    "" ) printf '0' ;;
    *[!0-9.+-]* ) printf '0' ;;
    *[0-9]* ) printf '%s' "$_value" ;;
    * ) printf '0' ;;
  esac
}

_ralph_write_plan_usage_summary() {
  local _done="$1" _total="$2"
  local _elapsed=$(( $(date +%s) - _plan_start_ts ))
  local _ended_at
  _ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local _summary_dir="$RALPH_LOG_DIR"
  local _summary_text=""
  mkdir -p "$_summary_dir"
  local _summary_invocations="$total_invocations"
  local _summary_input_tokens="$_total_input_tokens"
  local _summary_output_tokens="$_total_output_tokens"
  local _summary_cache_creation_tokens="$_total_cache_creation_tokens"
  local _summary_cache_read_tokens="$_total_cache_read_tokens"
  local _summary_max_turn_tokens="$_total_max_turn_tokens"
  local _history_summary=""
  if command -v python3 &>/dev/null && [[ -f "$RALPH_LOG_DIR/invocation-usage.json" ]]; then
    _history_summary="$(
      python3 - "$RALPH_LOG_DIR/invocation-usage.json" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)

invocations = doc.get("invocations") if isinstance(doc, dict) else []
if not isinstance(invocations, list):
    invocations = []
records = [record for record in invocations if isinstance(record, dict)]
if not records:
    raise SystemExit(0)

def as_int(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        try:
            return int(float(value or 0))
        except (TypeError, ValueError):
            return 0

input_tokens = sum(as_int(r.get("input_tokens")) for r in records)
output_tokens = sum(as_int(r.get("output_tokens")) for r in records)
cache_create = sum(as_int(r.get("cache_creation_input_tokens")) for r in records)
cache_read = sum(as_int(r.get("cache_read_input_tokens")) for r in records)
max_turn = max((as_int(r.get("max_turn_total_tokens")) for r in records), default=0)
prompt_bytes = sum(as_int(r.get("prompt_bytes")) for r in records)
todo_bytes = sum(as_int(r.get("todo_bytes")) for r in records)
todo_continuation_lines = sum(as_int(r.get("todo_continuation_lines")) for r in records)
direct_verification_count = sum(1 for r in records if r.get("direct_verification") is True)
rate_limit_count = sum(1 for r in records if str(r.get("rate_limit_status") or "").strip())
tool_turns = sum(as_int(r.get("tool_turns")) for r in records)
tool_calls_total = sum(as_int(r.get("tool_calls_total")) for r in records)
elapsed = sum(as_int(r.get("elapsed_seconds")) for r in records)
started = [str(r.get("started_at") or "") for r in records if r.get("started_at")]
ended = [str(r.get("ended_at") or "") for r in records if r.get("ended_at")]
print("\t".join([
    str(len(records)),
    str(elapsed),
    str(input_tokens),
    str(output_tokens),
    str(cache_create),
    str(cache_read),
    str(max_turn),
    str(prompt_bytes),
    str(todo_bytes),
    str(todo_continuation_lines),
    str(direct_verification_count),
    str(rate_limit_count),
    str(tool_turns),
    str(tool_calls_total),
    min(started) if started else "",
    max(ended) if ended else "",
]))
PY
    )"
    if [[ -n "$_history_summary" ]]; then
      IFS=$'\t' read -r \
        _summary_invocations \
        _elapsed \
        _summary_input_tokens \
        _summary_output_tokens \
        _summary_cache_creation_tokens \
        _summary_cache_read_tokens \
        _summary_max_turn_tokens \
        _summary_prompt_bytes \
        _summary_todo_bytes \
        _summary_todo_continuation_lines \
        _summary_direct_verification_count \
        _summary_rate_limit_count \
        _summary_tool_turns \
        _summary_tool_calls_total \
        _history_started_at \
        _history_ended_at <<<"$_history_summary"
      [[ -n "${_history_started_at:-}" ]] && _plan_started_at="$_history_started_at"
      [[ -n "${_history_ended_at:-}" ]] && _ended_at="$_history_ended_at"
    fi
  fi
  local _summary_cache_hit_ratio=0
  local _summary_total_input=$(( _summary_input_tokens + _summary_cache_read_tokens + _summary_cache_creation_tokens ))
  local _summary_total_tokens=$(( _summary_input_tokens + _summary_output_tokens + _summary_cache_creation_tokens + _summary_cache_read_tokens ))
  if [[ "$_summary_total_input" -gt 0 ]]; then
    _summary_cache_hit_ratio="$(python3 -c "print(round(${_summary_cache_read_tokens}/${_summary_total_input},4))" 2>/dev/null || echo 0)"
  fi
  local _overlay_summary_path=""
  local _summary_compaction_original_bytes=0
  local _summary_compaction_compacted_bytes=0
  local _summary_compaction_saved_bytes=0
  local _summary_compaction_measured_not_applied_bytes=0
  if declare -F runtime_overlay_summary_path >/dev/null 2>&1; then
    _overlay_summary_path="$(runtime_overlay_summary_path 2>/dev/null || true)"
  fi
  if [[ -n "$_overlay_summary_path" && -f "$_overlay_summary_path" ]] && command -v python3 &>/dev/null; then
    read -r _summary_compaction_original_bytes _summary_compaction_compacted_bytes _summary_compaction_saved_bytes _summary_compaction_measured_not_applied_bytes <<<"$(
      python3 - "$_overlay_summary_path" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    data = {}
original_bytes = int(data.get("compaction_original_bytes") or 0)
compacted_bytes = int(data.get("compaction_compacted_bytes") or 0)
if "compaction_saved_bytes" in data:
    saved_bytes = int(data.get("compaction_saved_bytes") or 0)
else:
    saved_bytes = max(0, original_bytes - compacted_bytes)
measured_not_applied = int(data.get("compaction_measured_not_applied_bytes") or 0)
print(f"{original_bytes} {compacted_bytes} {saved_bytes} {measured_not_applied}")
PY
    )"
  fi
  : "${_summary_prompt_bytes:=0}"
  : "${_summary_todo_bytes:=0}"
  : "${_summary_todo_continuation_lines:=0}"
  : "${_summary_direct_verification_count:=0}"
  : "${_summary_rate_limit_count:=0}"
  : "${_summary_tool_turns:=0}"
  : "${_summary_tool_calls_total:=0}"
  : "${_summary_verification_bytes_suppressed:=0}"

  # Aggregate verification bytes suppressed from post-verification tracking
  if [[ -f "$RALPH_LOG_DIR/post-verification-tracking.txt" ]]; then
    _summary_verification_bytes_suppressed=$(awk -F'bytes_suppressed=' '{sum+=int($NF)} END {print sum+0}' "$RALPH_LOG_DIR/post-verification-tracking.txt")
  fi

  # Cache reporting status: "observed" when tokens.cache fields were seen in
  # the stream (or cache token totals are nonzero), "unavailable" when the
  # final config enables caching but nothing was reported, "none" otherwise.
  local _summary_cache_reporting="none"
  local _summary_cache_observed=0
  local _summary_cache_settings_present="${RALPH_OPENCODE_FINAL_CACHE_SETTINGS:-0}"
  local _summary_prompt_cache_injected="${RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED:-0}"
  local _summary_ambient_cache="${RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS:-0}"
  if [[ "$_summary_cache_settings_present" != "1" && "$_summary_prompt_cache_injected" =~ ^(1|true|yes|on)$ ]]; then
    _summary_cache_settings_present=1
  fi
  if [[ "$_summary_cache_settings_present" != "1" && "$_summary_ambient_cache" =~ ^(1|true|yes|on)$ ]]; then
    _summary_cache_settings_present=1
  fi
  if (( _summary_cache_read_tokens + _summary_cache_creation_tokens > 0 )); then
    _summary_cache_observed=1
  elif [[ -f "$RALPH_LOG_DIR/invocation-usage.json" ]] \
    && grep -qE '"opencode_cache_fields_seen"[[:space:]]*:[[:space:]]*(true|1)' "$RALPH_LOG_DIR/invocation-usage.json" 2>/dev/null; then
    _summary_cache_observed=1
  fi
  if [[ "$_summary_cache_observed" -eq 1 ]]; then
    _summary_cache_reporting="observed"
  else
    case "${_summary_cache_settings_present:-0}" in
      1|true|yes|on) _summary_cache_reporting="unavailable" ;;
    esac
  fi

  local _summary_cache_read_per_tool_turn=0
  local _summary_cache_read_per_tool_call=0
  if command -v python3 &>/dev/null; then
    _ratio="$(python3 - <<PY
cache = int(${_summary_cache_read_tokens:-0})
turns = int(${_summary_tool_turns:-0})
calls = int(${_summary_tool_calls_total:-0})
denom = turns if turns > 0 else (calls if calls > 0 else 1)
per_turn = cache / denom if denom else 0
per_call = cache / calls if calls > 0 else 0
print(per_turn, per_call)
PY
    )" || true
    read -r _summary_cache_read_per_tool_turn _summary_cache_read_per_tool_call <<<"${_ratio:-0 0}"
  fi

  # Sanitize every numeric field so a malformed value cannot corrupt the JSON.
  _summary_invocations="$(run_plan_num_or_zero "${_summary_invocations:-0}")"
  _done="$(run_plan_num_or_zero "${_done:-0}")"
  _total="$(run_plan_num_or_zero "${_total:-0}")"
  _elapsed="$(run_plan_num_or_zero "${_elapsed:-0}")"
  _summary_input_tokens="$(run_plan_num_or_zero "${_summary_input_tokens:-0}")"
  _summary_output_tokens="$(run_plan_num_or_zero "${_summary_output_tokens:-0}")"
  _summary_cache_creation_tokens="$(run_plan_num_or_zero "${_summary_cache_creation_tokens:-0}")"
  _summary_cache_read_tokens="$(run_plan_num_or_zero "${_summary_cache_read_tokens:-0}")"
  _summary_cache_read_per_tool_turn="$(run_plan_num_or_zero "${_summary_cache_read_per_tool_turn:-0}")"
  _summary_cache_read_per_tool_call="$(run_plan_num_or_zero "${_summary_cache_read_per_tool_call:-0}")"
  _summary_max_turn_tokens="$(run_plan_num_or_zero "${_summary_max_turn_tokens:-0}")"
  _summary_cache_hit_ratio="$(run_plan_num_or_zero "${_summary_cache_hit_ratio:-0}")"
  _summary_prompt_bytes="$(run_plan_num_or_zero "${_summary_prompt_bytes:-0}")"
  _summary_todo_bytes="$(run_plan_num_or_zero "${_summary_todo_bytes:-0}")"
  _summary_todo_continuation_lines="$(run_plan_num_or_zero "${_summary_todo_continuation_lines:-0}")"
  _summary_direct_verification_count="$(run_plan_num_or_zero "${_summary_direct_verification_count:-0}")"
  _summary_verification_bytes_suppressed="$(run_plan_num_or_zero "${_summary_verification_bytes_suppressed:-0}")"
  _summary_rate_limit_count="$(run_plan_num_or_zero "${_summary_rate_limit_count:-0}")"
  _summary_tool_turns="$(run_plan_num_or_zero "${_summary_tool_turns:-0}")"
  _summary_tool_calls_total="$(run_plan_num_or_zero "${_summary_tool_calls_total:-0}")"
  _summary_compaction_original_bytes="$(run_plan_num_or_zero "${_summary_compaction_original_bytes:-0}")"
  _summary_compaction_compacted_bytes="$(run_plan_num_or_zero "${_summary_compaction_compacted_bytes:-0}")"
  _summary_compaction_saved_bytes="$(run_plan_num_or_zero "${_summary_compaction_saved_bytes:-0}")"
  _summary_compaction_measured_not_applied_bytes="$(run_plan_num_or_zero "${_summary_compaction_measured_not_applied_bytes:-0}")"

  cat > "$_summary_dir/plan-usage-summary.json" << _SUMMARY_EOF
{"schema_version":1,"kind":"plan_usage_summary","plan":"${PLAN_PATH}","plan_key":"${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}","artifact_ns":"${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-}}","stage_id":"${RALPH_STAGE_ID:-}","model":"${SELECTED_MODEL:-}","runtime":"${RUNTIME}","session_strategy":"${RALPH_PLAN_SESSION_STRATEGY:-fresh}","invocations":${_summary_invocations},"todos_done":${_done},"todos_total":${_total},"started_at":"${_plan_started_at}","ended_at":"${_ended_at}","elapsed_seconds":${_elapsed},"input_tokens":${_summary_input_tokens},"output_tokens":${_summary_output_tokens},"cache_creation_input_tokens":${_summary_cache_creation_tokens},"cache_read_input_tokens":${_summary_cache_read_tokens},"cache_read_per_tool_turn":${_summary_cache_read_per_tool_turn},"cache_read_per_tool_call":${_summary_cache_read_per_tool_call},"max_turn_total_tokens":${_summary_max_turn_tokens},"cache_hit_ratio":${_summary_cache_hit_ratio},"cache_reporting":"${_summary_cache_reporting}","prompt_bytes":${_summary_prompt_bytes},"todo_bytes":${_summary_todo_bytes},"todo_continuation_lines":${_summary_todo_continuation_lines},"direct_verification_count":${_summary_direct_verification_count},"verification_bytes_suppressed":${_summary_verification_bytes_suppressed},"rate_limit_count":${_summary_rate_limit_count},"tool_turns":${_summary_tool_turns},"tool_calls_total":${_summary_tool_calls_total},"compaction_original_bytes":${_summary_compaction_original_bytes},"compaction_compacted_bytes":${_summary_compaction_compacted_bytes},"compaction_saved_bytes":${_summary_compaction_saved_bytes},"compaction_measured_not_applied_bytes":${_summary_compaction_measured_not_applied_bytes}}
_SUMMARY_EOF
  if command -v python3 &>/dev/null && [[ -f "$RALPH_LOG_DIR/invocation-usage.json" ]]; then
    PYTHONPATH="$SCRIPT_DIR/python" python3 - "$_summary_dir/plan-usage-summary.json" "$RALPH_LOG_DIR/invocation-usage.json" "${RALPH_PLAN_KEY:-}" \
      "$(ralph_hooks_config_snapshot_path "${RALPH_PLAN_WORKSPACE_ROOT:-}" 2>/dev/null || true)" <<'PY'
import json
import os
import sys

from tool_call_classification import (
    ACCOUNTING_KEYS,
    SAVINGS_PATH_NAMES,
    empty_savings_bucket,
    finalize_savings_bucket,
)
from ralph_overlay_usage_fields import aggregate_hook_config_by_runtime, aggregate_opencode_cache_summary
from usage_accounting import aggregate_records, apply_canonical_to_summary

summary_path = sys.argv[1]
usage_path = sys.argv[2]
plan_key = sys.argv[3] if len(sys.argv) > 3 else ""

try:
    with open(summary_path, "r", encoding="utf-8") as fh:
        summary = json.load(fh)
    with open(usage_path, "r", encoding="utf-8") as fh:
        usage = json.load(fh)
    invocations_raw = usage.get("invocations")
    if not isinstance(summary, dict) or not isinstance(invocations_raw, list):
        raise ValueError("invalid summary or usage data")
    invocations = [item for item in invocations_raw if isinstance(item, dict)]
    if plan_key:
        filtered = []
        for item in invocations:
            record_plan = str(item.get("plan_key") or "").strip()
            if not record_plan or record_plan == plan_key:
                filtered.append(item)
        invocations = filtered
    def cache_read_ratios(cache_read, tool_turns, tool_calls):
        cache_read = float(cache_read or 0)
        tool_turns = int(tool_turns or 0)
        tool_calls = int(tool_calls or 0)
        denom = tool_turns if tool_turns > 0 else (tool_calls if tool_calls > 0 else 1)
        per_turn = cache_read / denom if denom else 0.0
        per_call = cache_read / tool_calls if tool_calls > 0 else 0.0
        return per_turn, per_call
    grouped = {}
    for record in invocations:
        if not isinstance(record, dict):
            continue
        key = (str(record.get("runtime") or ""), str(record.get("model") or ""))
        bucket = grouped.setdefault(
            key,
            {
                "runtime": key[0],
                "model": key[1],
                "invocations": 0,
                "elapsed_seconds": 0,
                "input_tokens": 0,
                "output_tokens": 0,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
                "max_turn_total_tokens": 0,
                "prompt_bytes": 0,
                "todo_bytes": 0,
                "todo_continuation_lines": 0,
                "direct_verification_count": 0,
                "rate_limit_count": 0,
                "tool_turns": 0,
                "tool_calls_total": 0,
                **{counter_key: 0 for counter_key in ACCOUNTING_KEYS},
            },
        )
        bucket["invocations"] += 1
        bucket["elapsed_seconds"] += int(record.get("elapsed_seconds") or 0)
        bucket["input_tokens"] += int(record.get("input_tokens") or 0)
        bucket["output_tokens"] += int(record.get("output_tokens") or 0)
        bucket["cache_creation_input_tokens"] += int(record.get("cache_creation_input_tokens") or 0)
        bucket["cache_read_input_tokens"] += int(record.get("cache_read_input_tokens") or 0)
        bucket["prompt_bytes"] += int(record.get("prompt_bytes") or 0)
        bucket["todo_bytes"] += int(record.get("todo_bytes") or 0)
        bucket["todo_continuation_lines"] += int(record.get("todo_continuation_lines") or 0)
        bucket["tool_turns"] += int(record.get("tool_turns") or 0)
        bucket["tool_calls_total"] += int(record.get("tool_calls_total") or 0)
        for counter_key in ACCOUNTING_KEYS:
            bucket[counter_key] += int(record.get(counter_key) or 0)
        if record.get("direct_verification") is True:
            bucket["direct_verification_count"] += 1
        if str(record.get("rate_limit_status") or "").strip():
            bucket["rate_limit_count"] += 1
        bucket["max_turn_total_tokens"] = max(bucket["max_turn_total_tokens"], int(record.get("max_turn_total_tokens") or 0))
    breakdown = []
    for key in sorted(grouped):
        bucket = grouped[key]
        canonical = aggregate_records(
            [
                {
                    "input_tokens": bucket["input_tokens"],
                    "output_tokens": bucket["output_tokens"],
                    "cache_creation_input_tokens": bucket["cache_creation_input_tokens"],
                    "cache_read_input_tokens": bucket["cache_read_input_tokens"],
                }
            ]
        )
        cache_hit_ratio = canonical["cache_hit_ratio"]
        cache_read_per_turn, cache_read_per_call = cache_read_ratios(
            bucket["cache_read_input_tokens"],
            bucket["tool_turns"],
            bucket["tool_calls_total"],
        )
        breakdown.append({
            "runtime": bucket["runtime"],
            "model": bucket["model"],
            "invocations": bucket["invocations"],
            "elapsed_seconds": bucket["elapsed_seconds"],
            "input_tokens": bucket["input_tokens"],
            "output_tokens": bucket["output_tokens"],
            "cache_creation_input_tokens": bucket["cache_creation_input_tokens"],
            "cache_read_input_tokens": bucket["cache_read_input_tokens"],
            "cache_read_per_tool_turn": cache_read_per_turn,
            "cache_read_per_tool_call": cache_read_per_call,
            "max_turn_total_tokens": bucket["max_turn_total_tokens"],
            "cache_hit_ratio": cache_hit_ratio,
            "cache_efficiency_ratio": canonical["cache_efficiency_ratio"],
            "uncached_input_tokens": canonical["uncached_input_tokens"],
            "total_input_tokens": canonical["total_input_tokens"],
            "measurement_source": canonical["measurement_source"],
            "prompt_bytes": bucket["prompt_bytes"],
            "todo_bytes": bucket["todo_bytes"],
            "todo_continuation_lines": bucket["todo_continuation_lines"],
            "direct_verification_count": bucket["direct_verification_count"],
            "rate_limit_count": bucket["rate_limit_count"],
            "tool_turns": bucket["tool_turns"],
            "tool_calls_total": bucket["tool_calls_total"],
            **{counter_key: bucket[counter_key] for counter_key in ACCOUNTING_KEYS},
        })
    total_per_turn, total_per_call = cache_read_ratios(
        summary.get("cache_read_input_tokens"),
        summary.get("tool_turns"),
        summary.get("tool_calls_total"),
    )
    summary["cache_read_per_tool_turn"] = total_per_turn
    summary["cache_read_per_tool_call"] = total_per_call
    summary["model_breakdown"] = breakdown

    # Persist the authoritative final per-path savings. Per-invocation
    # byte_savings_by_path is a cumulative running total, so the correct
    # whole-run value is the latest snapshot per path, not the sum. Savings can
    # decrease when an agent later reads back the raw/full stored result.
    # Writing it at the top level lets the benchmark report read a single
    # de-duplicated source instead of re-summing cumulative snapshots.
    final_paths = {}
    for record in invocations:
        savings = record.get("byte_savings_by_path")
        if not isinstance(savings, dict):
            continue
        for path_name in SAVINGS_PATH_NAMES:
            path_data = savings.get(path_name)
            if not isinstance(path_data, dict):
                continue
            final_paths[path_name] = dict(path_data)
    if final_paths:
        byte_savings_by_path = {}
        for path_name in SAVINGS_PATH_NAMES:
            entry = final_paths.get(path_name)
            bucket = dict(entry) if entry else empty_savings_bucket(
                include_hidden=path_name
                in ("hook_compaction", "proxy_shell_compaction", "result_windowing")
            )
            finalize_savings_bucket(bucket)
            byte_savings_by_path[path_name] = bucket
        summary["byte_savings_by_path"] = byte_savings_by_path

    apply_canonical_to_summary(summary, invocations)
    opencode_cache_summary = aggregate_opencode_cache_summary(invocations)
    if opencode_cache_summary:
        summary.update(opencode_cache_summary)

    hooks_config_path = sys.argv[4] if len(sys.argv) > 4 else ""
    hook_config_by_runtime = aggregate_hook_config_by_runtime(hooks_config_path, plan_key)
    if hook_config_by_runtime:
        summary["hook_config_by_runtime"] = hook_config_by_runtime

    tmp = f"{summary_path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(summary, fh)
        fh.write("\n")
    os.replace(tmp, summary_path)
except Exception as exc:
    sys.stderr.write(f"plan-usage-summary model_breakdown update failed: {type(exc).__name__}: {exc}\n")
PY
  fi
  if command -v python3 &>/dev/null; then
    local _usage_file="$RALPH_LOG_DIR/invocation-usage.json"
    if [[ ! -f "$_usage_file" ]]; then
      python3 - "$_usage_file" <<'PY' 2>/dev/null || true
import json
import os
import sys
schema = {"schema_version": 1, "kind": "plan_invocation_usage_history", "invocations": []}
usage_file = sys.argv[1]
os.makedirs(os.path.dirname(usage_file), exist_ok=True)
with open(usage_file, "w", encoding="utf-8") as fh:
    json.dump(schema, fh)
    fh.write("\n")
PY
    fi
    PYTHONPATH="$SCRIPT_DIR/python" python3 "$SCRIPT_DIR/python/ralph-discover-report.py" \
      --invocations "$_usage_file" \
      --output "$_summary_dir/discover-report.json" \
      --plan-key "${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}" \
      2>/dev/null || true
  fi
  if command -v python3 &>/dev/null && [[ -f "$RALPH_LOG_DIR/invocation-usage.json" ]]; then
    # Command substitution hides the terminal from python; forward our own
    # color decision so the summary renders styled sections on the console.
    local _summary_color=0
    [[ -n "$C_RST" ]] && _summary_color=1
    _summary_text="$(
      RALPH_USAGE_SUMMARY_COLOR="$_summary_color" \
      python3 "$SCRIPT_DIR/python/ralph-usage-summary-text.py" plan \
        --summary "$_summary_dir/plan-usage-summary.json" \
        --invocations "$RALPH_LOG_DIR/invocation-usage.json" 2>/dev/null || true
    )"
  fi
  local _elapsed_fmt
  _elapsed_fmt="$(ralph_format_elapsed_secs "$_elapsed")"
  ralph_run_plan_log "plan usage summary: invocations=${_summary_invocations} input=${_summary_input_tokens} output=${_summary_output_tokens} cache_create=${_summary_cache_creation_tokens} cache_read=${_summary_cache_read_tokens} cache_read_per_turn=${_summary_cache_read_per_tool_turn} cache_read_per_call=${_summary_cache_read_per_tool_call} max_turn=${_summary_max_turn_tokens} cache_hit_ratio=${_summary_cache_hit_ratio} elapsed=${_elapsed_fmt} compaction_saved_bytes=${_summary_compaction_saved_bytes} compaction_measured_not_applied_bytes=${_summary_compaction_measured_not_applied_bytes} compaction_original_bytes=${_summary_compaction_original_bytes} compaction_compacted_bytes=${_summary_compaction_compacted_bytes}"
  local _summary_count_fmt
  _summary_count_fmt="$(ralph_format_int_commas "$_summary_invocations")"
  local _summary_input_fmt _summary_cache_create_fmt _summary_cache_read_fmt _summary_output_fmt
  _summary_input_fmt="$(ralph_format_int_commas "$_summary_input_tokens")"
  _summary_cache_create_fmt="$(ralph_format_int_commas "$_summary_cache_creation_tokens")"
  _summary_cache_read_fmt="$(ralph_format_int_commas "$_summary_cache_read_tokens")"
  _summary_output_fmt="$(ralph_format_int_commas "$_summary_output_tokens")"
  local _summary_input_avg=0 _summary_cache_create_avg=0 _summary_cache_read_avg=0 _summary_output_avg=0
  if [[ "$_summary_invocations" -gt 0 ]]; then
    _summary_input_avg=$(( (_summary_input_tokens + _summary_invocations / 2) / _summary_invocations ))
    _summary_cache_create_avg=$(( (_summary_cache_creation_tokens + _summary_invocations / 2) / _summary_invocations ))
    _summary_cache_read_avg=$(( (_summary_cache_read_tokens + _summary_invocations / 2) / _summary_invocations ))
    _summary_output_avg=$(( (_summary_output_tokens + _summary_invocations / 2) / _summary_invocations ))
  fi
  local _summary_input_avg_fmt _summary_cache_create_avg_fmt _summary_cache_read_avg_fmt _summary_output_avg_fmt
  _summary_input_avg_fmt="$(ralph_format_int_commas "$_summary_input_avg")"
  _summary_cache_create_avg_fmt="$(ralph_format_int_commas "$_summary_cache_create_avg")"
  _summary_cache_read_avg_fmt="$(ralph_format_int_commas "$_summary_cache_read_avg")"
  _summary_output_avg_fmt="$(ralph_format_int_commas "$_summary_output_avg")"
  local _summary_rate_input=5 _summary_rate_cache_create=5 _summary_rate_cache_read=5 _summary_rate_output=25
  case "${SELECTED_MODEL:-}" in
    *haiku*4.5*|*sonnet*4.6*|*sonnet*4.7*|*opus*4.*)
      _summary_rate_input=3
      _summary_rate_cache_create=3
      _summary_rate_cache_read=3
      _summary_rate_output=15
      ;;
  esac
  local _summary_total_cost_weighted _summary_total_cost_cents _summary_avg_cost_cents
  _summary_total_cost_weighted=$(( \
    (_summary_input_tokens * _summary_rate_input) + \
    (_summary_cache_creation_tokens * _summary_rate_cache_create) + \
    (_summary_cache_read_tokens * _summary_rate_cache_read) + \
    (_summary_output_tokens * _summary_rate_output) \
  ))
  _summary_total_cost_cents=$(( (_summary_total_cost_weighted * 100 + 500000) / 1000000 ))
  _summary_avg_cost_cents=0
  if [[ "$_summary_invocations" -gt 0 ]]; then
    _summary_avg_cost_cents=$(( (_summary_total_cost_cents + _summary_invocations / 2) / _summary_invocations ))
  fi
  local _summary_total_cost_fmt _summary_avg_cost_fmt
  _summary_total_cost_fmt="$(printf '%d.%02d' $(( _summary_total_cost_cents / 100 )) $(( _summary_total_cost_cents % 100 )))"
  _summary_avg_cost_fmt="$(printf '%d.%02d' $(( _summary_avg_cost_cents / 100 )) $(( _summary_avg_cost_cents % 100 )))"
  if [[ "$_summary_compaction_saved_bytes" -gt 0 ]]; then
    local _summary_compaction_saved_fmt _summary_compaction_saved_tokens_fmt
    _summary_compaction_saved_fmt="$(ralph_format_int_commas "$_summary_compaction_saved_bytes")"
    _summary_compaction_saved_tokens_fmt="$(ralph_format_int_commas "$(( _summary_compaction_saved_bytes / 4 ))")"
    echo "Ralph kept about ${_summary_compaction_saved_fmt} bytes (~${_summary_compaction_saved_tokens_fmt} est. tokens) of tool output out of the AI's view this run."
  fi
  echo -e "${C_DIM}Plan total across ${_summary_count_fmt} invocations: input=${_summary_input_fmt} cache_create=${_summary_cache_create_fmt} cache_read=${_summary_cache_read_fmt} output=${_summary_output_fmt} est=\$${_summary_total_cost_fmt} compaction_saved_bytes=${_summary_compaction_saved_bytes}${C_RST}"
  echo -e "${C_DIM}Per-invocation average: input=${_summary_input_avg_fmt} cache_create=${_summary_cache_create_avg_fmt} cache_read=${_summary_cache_read_avg_fmt} output=${_summary_output_avg_fmt} est=\$${_summary_avg_cost_fmt}${C_RST}"
  if [[ -n "$_summary_text" ]]; then
    echo ""
    printf '%s\n' "$_summary_text"
  else
    echo -e "${C_DIM}Total elapsed time: ${_elapsed_fmt}${C_RST}"
  fi
  if [[ -n "${RALPH_GRAPH_NODE_LOG_DIR:-}" && -f "$_summary_dir/plan-usage-summary.json" ]]; then
    cp "$_summary_dir/plan-usage-summary.json" "$RALPH_GRAPH_NODE_LOG_DIR/usage.json" 2>/dev/null || true
  fi
  _RALPH_PLAN_SUMMARY_FINALIZED=1
}

# Write plan-usage-summary.json and discover-report.json on abnormal exits when an
# explicit stop path did not already finalize usage (kill switch, signals, etc.).
_ralph_finalize_plan_usage_on_exit() {
  if [[ "${_RALPH_PLAN_SUMMARY_FINALIZED:-0}" == "1" ]]; then
    return 0
  fi
  if [[ -z "${RALPH_LOG_DIR:-}" || -z "${PLAN_PATH:-}" ]]; then
    return 0
  fi
  if ! declare -F _ralph_write_plan_usage_summary >/dev/null 2>&1; then
    return 0
  fi
  local _done=0 _total=0
  if declare -F count_todos >/dev/null 2>&1 && [[ -f "$PLAN_PATH" ]]; then
    read -r _done _total <<< "$(count_todos "$PLAN_PATH")"
  fi
  _ralph_write_plan_usage_summary "$_done" "$_total" || true
}

_ralph_runtime_overlay_summary_path_for_usage() {
  local path=""
  if [[ "${_RALPH_RUNTIME_OVERLAY_ACTIVE:-0}" == "1" ]] && declare -F runtime_overlay_summary_path >/dev/null 2>&1; then
    path="$(runtime_overlay_summary_path 2>/dev/null || true)"
    if [[ ! -f "$path" ]]; then
      path=""
    fi
  fi
  printf '%s' "$path"
}

_ralph_runtime_overlay_summary_snapshot_for_usage() {
  local summary_path="$1"
  local iteration="$2"
  local runtime="$3"
  local start_time="$4"
  if [[ -z "$summary_path" || ! -f "$summary_path" ]]; then
    printf '%s' ""
    return
  fi
  local iter_id="${iteration:-0}"
  local runtime_id="${runtime:-unknown}"
  runtime_id="${runtime_id//[^[:alnum:]-]/_}"
  local start_ts="${start_time:-}"
  if [[ -z "$start_ts" ]]; then
    start_ts="$(date +%s)"
  fi
  local dest="$RALPH_LOG_DIR/runtime-overlay-summary-${iter_id}-${runtime_id}-${start_ts}.json"
  mkdir -p "$(dirname "$dest")"
  if cp "$summary_path" "$dest" 2>/dev/null; then
    printf '%s' "$dest"
  else
    printf '%s' "$summary_path"
  fi
}

# Export bounded continuation / background telemetry for the invocation usage
# record. Never includes command text, secrets, or unbounded job output.
ralph_run_plan_capture_bg_continuation_usage_telemetry() {
  local continuation_json="${1:-}"
  local tier="${RALPH_BG_TIER_SELECTED:-}"
  local elapsed="" status="" reason=""

  [[ -n "$continuation_json" ]] || return 0
  reason="${RALPH_USAGE_CONTINUATION_REASON:-bg-job}"
  elapsed="$(jq -r '.elapsedSeconds // empty' <<<"$continuation_json" 2>/dev/null || true)"
  status="$(jq -r '.status // empty' <<<"$continuation_json" 2>/dev/null || true)"

  export RALPH_USAGE_CONTINUATION_REASON="$reason"
  if [[ "$elapsed" =~ ^[0-9]+$ ]]; then
    export RALPH_USAGE_WAIT_DURATION_SECONDS="$elapsed"
  fi
  if [[ -n "$status" && "$status" != "null" ]]; then
    export RALPH_USAGE_TERMINAL_STATUS="$status"
  fi
  case "$tier" in
    hook)
      export RALPH_USAGE_SESSION_CONTINUITY="held"
      ;;
    invocation|*)
      export RALPH_USAGE_SESSION_CONTINUITY="resumed"
      ;;
  esac
}

ralph_run_plan_refresh_continuation_usage_telemetry() {
  local attempt_key="" tier="${RALPH_BG_TIER_SELECTED:-}" tier_reason="${RALPH_BG_TIER_REASON:-}"
  local continuity="${RALPH_USAGE_SESSION_CONTINUITY:-}"
  local degraded="${RALPH_USAGE_DEGRADED_FALLBACK:-}"
  local continuation_reason="${RALPH_USAGE_CONTINUATION_REASON:-}"

  if [[ -z "$continuation_reason" && -n "${RALPH_PLAN_INVOCATION_REASON:-}" ]]; then
    continuation_reason="${RALPH_PLAN_INVOCATION_REASON}"
  fi

  if [[ -z "$continuity" ]]; then
    if [[ "$tier" == "hook" && "${RALPH_PLAN_INVOCATION_REASON:-}" == "${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}" ]]; then
      continuity="held"
    elif [[ "${RALPH_PLAN_INVOCATION_REASON:-}" == "${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}" ]]; then
      if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
        continuity="resumed"
      fi
    fi
  fi

  if [[ -z "$degraded" ]]; then
    case "${RALPH_TODO_SESSION_CAPTURE_STATUS:-${RALPH_SESSION_TODO_CAPTURE:-}}" in
      degraded)
        degraded="session-capture-degraded"
        ;;
    esac
    if [[ -z "$degraded" && "${RALPH_TODO_SESSION_CAPTURE:-}" == "${RALPH_TODO_SESSION_CAPTURE_DEGRADED:-degraded}" ]]; then
      degraded="session-capture-degraded"
    fi
  fi

  if declare -F ralph_bg_job_attempt_key >/dev/null 2>&1 && declare -F ralph_bg_job_identity_json >/dev/null 2>&1; then
    attempt_key="$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)" 2>/dev/null || true)"
  elif declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 && declare -F ralph_session_todo_identity_json >/dev/null 2>&1; then
    attempt_key="$(ralph_session_todo_attempt_key "$(ralph_session_todo_identity_json)" 2>/dev/null || true)"
  fi

  # Prefer already-exported RALPH_BG_TIER_*; never invent command text.
  # Use if/fi (not `[[ ... ]] && export`) so empty optional fields do not trip
  # set -e on macOS bash 3.2.
  if [[ -n "$tier" ]]; then
    export RALPH_USAGE_BG_TIER="$tier"
  fi
  if [[ -n "$tier_reason" ]]; then
    export RALPH_USAGE_BG_TIER_REASON="$tier_reason"
  fi
  if [[ -n "$continuation_reason" ]]; then
    export RALPH_USAGE_CONTINUATION_REASON="$continuation_reason"
  fi
  if [[ -n "$attempt_key" ]]; then
    export RALPH_USAGE_LOGICAL_ATTEMPT="$attempt_key"
  fi
  if [[ -n "$continuity" ]]; then
    export RALPH_USAGE_SESSION_CONTINUITY="$continuity"
  fi
  if [[ -n "$degraded" ]]; then
    export RALPH_USAGE_DEGRADED_FALLBACK="$degraded"
  fi
}

_ralph_append_invocation_usage_history() {
  local _path="$1"
  local _iteration="$2"
  local _model="$3"
  local _runtime="$4"
  local _elapsed_seconds="$5"
  local _input_tokens="$6"
  local _output_tokens="$7"
  local _cache_create="$8"
  local _cache_read="$9"
  local _max_turn="${10:-0}"
  local _cache_hit_ratio="${11:-0}"
  local _started_at="${12:-}"
  local _ended_at="${13:-}"
  local _plan_key="${14:-}"
  local _stage_id="${15:-}"
  local _session_strategy="${16:-fresh}"
  local _todo_line="${17:-}"
  local _todo_ordinal="${18:-}"
  local _todo_completed="${19:-}"
  local _todo_class="${20:-}"
  local _todo_hash="${21:-}"
  local _validation_failed="${22:-}"
  local _override_used="${23:-}"
  local _prompt_bytes="${24:-0}"
  local _todo_bytes="${25:-0}"
  local _todo_continuation_lines="${26:-0}"
  local _split_parent_id="${27:-}"
  local _direct_verification="${28:-0}"
  local _rate_limit_status="${29:-}"
  local _tool_turns="${30:-0}"
  local _usage_merge_path="${31:-}"
  local _overlay_summary_path="${32:-}"
  local _overlay_fields_py="${SCRIPT_DIR:-}/python/ralph_overlay_usage_fields.py"
  if [[ ! -f "$_overlay_fields_py" ]]; then
    _overlay_fields_py=""
  fi

  if declare -F ralph_run_plan_refresh_continuation_usage_telemetry >/dev/null 2>&1; then
    ralph_run_plan_refresh_continuation_usage_telemetry
  fi

  mkdir -p "$(dirname "$_path")"

  if command -v python3 &>/dev/null; then
    PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" python3 "${SCRIPT_DIR}/python/ralph-usage-record.py" \
      "$_path" "$_iteration" "$_model" "$_runtime" "$_elapsed_seconds" "$_input_tokens" "$_output_tokens" \
      "$_cache_create" "$_cache_read" "$_max_turn" "$_cache_hit_ratio" \
      "$_started_at" "$_ended_at" "$_plan_key" "$_stage_id" \
      "$_session_strategy" "$_todo_line" "$_todo_ordinal" \
      "$_todo_completed" "$_todo_class" "$_todo_hash" \
      "$_validation_failed" "$_override_used" \
      "$_prompt_bytes" "$_todo_bytes" "$_todo_continuation_lines" \
      "$_split_parent_id" "$_direct_verification" "$_rate_limit_status" \
      "$_tool_turns" "$_usage_merge_path" "$_overlay_summary_path" "$_overlay_fields_py"
    return 0
  fi

  local _extra_fields=""
  if [[ -n "$_started_at" ]]; then
    _extra_fields+=",\"started_at\":\"${_started_at}\""
  fi
  if [[ -n "$_ended_at" ]]; then
    _extra_fields+=",\"ended_at\":\"${_ended_at}\""
  fi
  if [[ -n "$_plan_key" ]]; then
    _extra_fields+=",\"plan_key\":\"${_plan_key}\""
  fi
  if [[ -n "$_stage_id" ]]; then
    _extra_fields+=",\"stage_id\":\"${_stage_id}\""
  fi
  if [[ -n "$_session_strategy" ]]; then
    _extra_fields+=",\"session_strategy\":\"${_session_strategy}\""
  fi
  if [[ -n "$_todo_line" ]]; then
    _extra_fields+=",\"todo_line\":${_todo_line}"
  fi
  if [[ -n "$_todo_ordinal" ]]; then
    _extra_fields+=",\"todo_ordinal\":${_todo_ordinal}"
  fi
  if [[ -n "$_todo_completed" ]]; then
    if [[ "$_todo_completed" == "1" ]]; then
      _extra_fields+=",\"todo_completed\":true"
    else
      _extra_fields+=",\"todo_completed\":false"
    fi
  fi
  if [[ -n "$_todo_class" ]]; then
    _extra_fields+=",\"todo_risk_class\":\"${_todo_class}\""
  fi
  if [[ -n "$_todo_hash" ]]; then
    _extra_fields+=",\"todo_hash\":\"${_todo_hash}\""
  fi
  if [[ -n "$_validation_failed" ]]; then
    if [[ "$_validation_failed" == "1" ]]; then
      _extra_fields+=",\"todo_validation_failed\":true"
    else
      _extra_fields+=",\"todo_validation_failed\":false"
    fi
  fi
  if [[ -n "$_override_used" ]]; then
    if [[ "$_override_used" == "1" ]]; then
      _extra_fields+=",\"completion_override_used\":true"
    else
      _extra_fields+=",\"completion_override_used\":false"
    fi
  fi
  _extra_fields+=",\"prompt_bytes\":${_prompt_bytes},\"todo_bytes\":${_todo_bytes},\"todo_continuation_lines\":${_todo_continuation_lines},\"direct_verification\":$([[ "$_direct_verification" == "1" ]] && printf true || printf false),\"tool_turns\":${_tool_turns},\"requests_without_tool_use\":0"
  _extra_fields+=",\"ralph_proxy_calls\":0,\"other_mcp_calls\":0,\"native_read_like_calls\":0,\"native_write_like_calls\":0,\"native_file_read_calls\":0,\"native_read_compatibility_calls\":0,\"native_search_calls\":0,\"native_shell_calls\":0,\"ralph_mcp_calls\":0,\"runtime_hook_rewrite_calls\":0,\"runtime_hook_compaction_calls\":0,\"unknown_tool_calls\":0"
  _extra_fields+=",\"native_hooks_effective\":false,\"native_hook_events\":0,\"hook_compactions\":0,\"hook_rewrites\":0,\"hook_original_bytes\":0,\"hook_compacted_bytes\":0,\"mcp_effective\":false,\"runtime_overlay_mode\":\"\",\"runtime_overlay_warnings\":[]"
  if [[ -n "$_split_parent_id" ]]; then
    _extra_fields+=",\"split_parent_id\":\"${_split_parent_id}\""
  fi
  if [[ -n "$_rate_limit_status" ]]; then
    _extra_fields+=",\"rate_limit_status\":\"${_rate_limit_status}\""
  fi
  # Continuation / background telemetry (env only; never command text or output).
  local _bg_tier="${RALPH_USAGE_BG_TIER:-${RALPH_BG_TIER_SELECTED:-}}"
  local _bg_tier_reason="${RALPH_USAGE_BG_TIER_REASON:-${RALPH_BG_TIER_REASON:-}}"
  local _cont_reason="${RALPH_USAGE_CONTINUATION_REASON:-}"
  local _logical_attempt="${RALPH_USAGE_LOGICAL_ATTEMPT:-}"
  local _session_cont="${RALPH_USAGE_SESSION_CONTINUITY:-}"
  local _degraded_fb="${RALPH_USAGE_DEGRADED_FALLBACK:-}"
  local _wait_dur="${RALPH_USAGE_WAIT_DURATION_SECONDS:-}"
  local _term_status="${RALPH_USAGE_TERMINAL_STATUS:-}"
  if [[ -n "$_bg_tier" ]]; then
    _extra_fields+=",\"bg_tier\":\"${_bg_tier//\"/}\""
  fi
  if [[ -n "$_bg_tier_reason" ]]; then
    _extra_fields+=",\"bg_tier_reason\":\"${_bg_tier_reason//\"/}\""
  fi
  if [[ -n "$_cont_reason" ]]; then
    _extra_fields+=",\"continuation_reason\":\"${_cont_reason//\"/}\""
  fi
  if [[ -n "$_logical_attempt" ]]; then
    _extra_fields+=",\"logical_attempt\":\"${_logical_attempt//\"/}\""
  fi
  if [[ -n "$_session_cont" ]]; then
    _extra_fields+=",\"session_continuity\":\"${_session_cont//\"/}\""
  fi
  if [[ -n "$_degraded_fb" ]]; then
    _extra_fields+=",\"degraded_fallback\":\"${_degraded_fb//\"/}\""
  fi
  if [[ "$_wait_dur" =~ ^[0-9]+$ ]]; then
    _extra_fields+=",\"wait_duration_seconds\":${_wait_dur}"
  fi
  if [[ -n "$_term_status" ]]; then
    _extra_fields+=",\"terminal_status\":\"${_term_status//\"/}\""
  fi

  cat >"$_path" <<USAGE_EOF
{"schema_version":1,"kind":"plan_invocation_usage_history","invocations":[{"iteration":${_iteration},"model":"${_model}","runtime":"${_runtime}","elapsed_seconds":${_elapsed_seconds},"input_tokens":${_input_tokens},"output_tokens":${_output_tokens},"cache_creation_input_tokens":${_cache_create},"cache_read_input_tokens":${_cache_read},"max_turn_total_tokens":${_max_turn},"cache_hit_ratio":${_cache_hit_ratio}${_extra_fields}}]}
USAGE_EOF
}

ralph_current_invocation_output_segment() {
  local log_path="$1"
  local start_size="$3"

  [[ -f "$log_path" ]] || return 0
  tail -c +"$((start_size + 1))" "$log_path" 2>/dev/null
}

ralph_detect_rate_limit_status() {
  local text="$1"
  local lower filtered
  # The Claude CLI emits an informational `rate_limit_event` on essentially every
  # request, even when the request is ALLOWED, e.g.:
  #   {"type":"rate_limit_event","rate_limit_info":{"status":"allowed",
  #    "rateLimitType":"five_hour","overageStatus":"rejected",
  #    "overageDisabledReason":"out_of_credits",...}}
  # Here "rateLimitType":"five_hour" merely names the bucket and
  # "overageStatus":"rejected" only means pay-as-you-go overage is off; the
  # request still succeeded ("status":"allowed"). Blindly substring-matching
  # "five_hour"/"rate limit" on that telemetry produced false hard-stops that
  # killed the plan after a TODO the agent had actually completed. Parse JSON
  # lines when possible so allowed rate-limit telemetry is dropped before any
  # substring heuristics run. Also drop grep/source lines (agents often read
  # run-plan-core.sh and match `_rate_limit_status` in tool output) and
  # successful CLI result events.
  filtered="$text"
  if command -v python3 >/dev/null 2>&1; then
    filtered="$(python3 -c '
import json
import re
import sys

grep_line = re.compile(r"^[^:\s][^:]*\.(?:sh|py|bats|md|json):[0-9]+:")
source_ref = re.compile(
    r"_(?:rate_limit|ralph_detect_rate_limit)|rate_limit_count|rate_limit_display",
    re.I,
)

for line in sys.stdin:
    raw = line.rstrip("\n")
    if not raw:
        continue
    if grep_line.search(raw) or source_ref.search(raw):
        continue
    try:
        obj = json.loads(raw)
    except Exception:
        print(raw)
        continue

    if isinstance(obj, dict):
        if obj.get("type") == "rate_limit_event":
            info = obj.get("rate_limit_info")
            if isinstance(info, dict) and str(info.get("status", "")).lower() == "allowed":
                continue
        if (
            obj.get("type") == "result"
            and str(obj.get("subtype", "")).lower() == "success"
            and not obj.get("is_error")
        ):
            continue

    print(raw)
' <<<"$text")"
  else
    filtered="$(printf '%s\n' "$text" | grep -ivE '"type"[[:space:]]*:[[:space:]]*"rate_limit_event".*"status"[[:space:]]*:[[:space:]]*"allowed"' || true)"
    filtered="$(printf '%s\n' "$filtered" | grep -ivE '\.(sh|py|bats|md|json):[0-9]+:.*rate_limit' || true)"
  fi
  lower="$(printf '%s' "$filtered" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *"five_hour"* || "$lower" == *"5-hour"* || "$lower" == *"5 hour"* ]]; then
    printf 'five_hour\n'
    return 0
  fi
  if [[ "$lower" == *"out of credits"* || "$lower" == *"credit balance"* || "$lower" == *"insufficient credits"* ]]; then
    printf 'out_of_credits\n'
    return 0
  fi
  if [[ "$lower" == *"rate limit"* || "$lower" == *"rate_limit"* || "$lower" == *"usage limit"* ]]; then
    printf 'rate_limited\n'
    return 0
  fi
  return 1
}

ralph_plan_manual_ack_path() {
  printf '%s\n' "$RALPH_SESSION_DIR/manual-ack.txt"
}

# Classify a nonzero CLI exit from the invocation's output segment so the
# operator sees the real stop reason instead of a generic label. Prints one
# token on stdout and returns 0 when a known signature matches:
#   mcp_transport - the Ralph MCP server transport died or requests timed out
#                   (agents lose mcp__ralph__* tools mid-session and flail)
#   auth          - the runtime CLI reported a login/authentication problem
# Returns 1 when nothing recognizable matched.
ralph_run_plan_classify_cli_failure() {
  local text="${1:-}"
  [[ -n "$text" ]] || return 1
  case "$text" in
    *"MCP error -32001"* | *"MCP error -32000"* | \
    *"No such tool available: mcp__"* | \
    *'not found on server "ralph"'* | \
    *"Connection closed"*)
      printf 'mcp_transport\n'
      return 0
      ;;
    *"Not logged in"* | *"Please run /login"* | *"authentication_error"*)
      printf 'auth\n'
      return 0
      ;;
  esac
  return 1
}

# Print the last few non-empty error-looking lines of the invocation output
# segment to stderr so the terminal shows *why* the runtime failed without the
# operator having to open the output log.
ralph_run_plan_print_failure_tail() {
  local text="${1:-}" max_lines="${2:-5}"
  [[ -n "$text" ]] || return 0
  local tail_lines
  tail_lines="$(printf '%s\n' "$text" | grep -iE 'error|exception|timed out|timeout|denied|no such tool|not found on server' | tail -n "$max_lines")"
  if [[ -z "$tail_lines" ]]; then
    tail_lines="$(printf '%s\n' "$text" | grep -vE '^[[:space:]]*$' | tail -n "$max_lines")"
  fi
  [[ -n "$tail_lines" ]] || return 0
  echo -e "${C_DIM}Last runtime output:${C_RST}" >&2
  while IFS= read -r _fail_line; do
    echo -e "${C_DIM}  ${_fail_line:0:200}${C_RST}" >&2
  done <<< "$tail_lines"
}

# Terminate orphaned ralph-run-plan processes that were left behind when a
# previous parent shell/terminal died without running cleanup. Only targets
# processes reparented to init (ppid 1) that share the same --plan path.
# Args: $1 = plan path (defaults to $PLAN_PATH)
ralph_run_plan_cleanup_orphans() {
  local plan_path="${1:-${PLAN_PATH:-}}"
  [[ -n "$plan_path" ]] || return 0

  local self_pid="$$"
  local plan_abs other_abs
  plan_abs="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$plan_path" 2>/dev/null || readlink -f "$plan_path" 2>/dev/null || printf '%s' "$plan_path")"
  [[ -n "$plan_abs" ]] || return 0

  local pid args plan_arg
  while IFS= read -r line; do
    pid="${line%% *}"
    args="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$self_pid" ]] && continue

    plan_arg=""
    if [[ "$args" =~ --plan[[:space:]]+([^[:space:]]+) ]]; then
      plan_arg="${BASH_REMATCH[1]}"
    elif [[ "$args" =~ --plan=([^[:space:]]+) ]]; then
      plan_arg="${BASH_REMATCH[1]}"
    fi
    [[ -n "$plan_arg" ]] || continue

    other_abs="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$plan_arg" 2>/dev/null || readlink -f "$plan_arg" 2>/dev/null || printf '%s' "$plan_arg")"
    if [[ "$plan_abs" == "$other_abs" ]]; then
      ralph_run_plan_log "cleaning up orphaned plan runner from previous run (pid=$pid)"
      kill -TERM "$pid" 2>/dev/null || true
      ralph_wait 1
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  done < <(ps -eo pid=,ppid=,args= 2>/dev/null | awk '$2 == 1 && $0 ~ /ralph-run-plan/ {print $1, substr($0, index($0,$3))}')
}

if [[ "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
  # Preflight check for OpenCode strict proxy (must run before MCP preflight)
  ralph_run_plan_opencode_strict_proxy_preflight
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bash-lib/mcp/mcp-setup.sh"
  ralph_run_plan_mcp_preflight_or_exit
  ralph_run_plan_log "Agent Tool Access: ralph (runtime=$RUNTIME)"
fi

# Outer loop: one iteration per "next open TODO" in the plan file.
# Inner loop (below): retry the same TODO until it is marked [x], human input is satisfied, or limits hit.
ralph_run_plan_cleanup_orphans "$PLAN_PATH"
ralph_launcher_death_watchdog &
RALPH_LAUNCHER_WATCHDOG_PID=$!
while true; do
  if ! next=$(get_next_todo "$PLAN_PATH"); then
    read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
    ralph_run_plan_log "all complete (done=$done_count total=$total_count) after $total_invocations agent invocation(s)"
    {
      echo ""
      echo "################################################################################"
      echo "# All TODOs complete ($done_count/$total_count) - $(date '+%Y-%m-%d %H:%M:%S')"
      echo "################################################################################"
    } >> "$OUTPUT_LOG"
    echo ""
    echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done_count/$total_count)${C_RST}."
    # Invalidate any stale manual-ack artifact when plan is fully complete.
    rm -f "$(ralph_plan_manual_ack_path)" 2>/dev/null || true
    _ralph_write_plan_usage_summary "$done_count" "$total_count"
    echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
    EXIT_STATUS="complete"
    exit 0
  fi

  plan_format="$(plan_detect_format "$PLAN_PATH" 2>/dev/null || printf 'default')"
  line_num="${next%%|*}"
  todo_id=""
  todo_target="$line_num"
  if plan_format_is_yaml "$plan_format"; then
    _next_cursor_rest="${next#*|}"
    todo_id="${_next_cursor_rest%%|*}"
    todo_text="${_next_cursor_rest#*|}"
    todo_target="${todo_id:-$line_num}"
  else
    full_line="${next#*|}"
    todo_text="$(plan_open_todo_body "$full_line")"
  fi
  todo_multiline_note=""
  if plan_todo_has_continuation_lines "$todo_text" 2>/dev/null; then
    todo_multiline_note=$'\n\nThis TODO spans multiple lines. Treat every continuation line as required work, and do not stop after completing only the first numbered item.'
  fi

  attempts_on_line=0
  human_gate_satisfied_for_line=0
  _reset_retry_done_for_line=0
  _opencode_empty_resume_retry_done_for_line=0
  _claude_empty_resume_retry_done_for_line=0
  _post_verify_reopen_retry_active=0
  # Same checklist line: re-invoke assistant if the box stayed [ ], pending-human was cleared, or gutter retry.
  while true; do
    total_invocations=$((total_invocations + 1))
    if [[ $total_invocations -gt $MAX_ITERATIONS ]]; then
      ralph_run_plan_log "exceeded plan max invocations (CURSOR_PLAN_MAX_ITER etc.) limit=$MAX_ITERATIONS"
      echo -e "${C_R}Too many agent invocations ($MAX_ITERATIONS).${C_RST} Raise CURSOR_PLAN_MAX_ITER or fix the plan." >&2
      read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
      _ralph_write_plan_usage_summary "$done_count" "$total_count"
      ralph_runtime_overlay_cleanup_if_needed
      exit 1
    fi
    iteration=$total_invocations

    # One hooks-config.jsonl snapshot per invocation/runtime, written after
    # mode defaults and runtime adapter preparation have both run (never
    # during runtime_overlay_init_state, which precedes both).
    if declare -F ralph_hooks_config_snapshot_append >/dev/null 2>&1; then
      ralph_hooks_config_snapshot_append \
        "${RALPH_PLAN_WORKSPACE_ROOT:-}" \
        "${RALPH_PLAN_KEY:-}" \
        "$iteration" \
        "${RUNTIME:-}" \
        "${RALPH_MODE:-no}" || true
    fi

    read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
    remaining=$((total_count - done_count))
    _resume_hint_threshold="${RALPH_PLAN_RESUME_HINT_THRESHOLD:-25}"
    if [[ ! "$_resume_hint_threshold" =~ ^[0-9]+$ ]]; then
      _resume_hint_threshold=25
    fi
    if [[ "${RALPH_PLAN_RESUME_HINT:-1}" != "0" ]] && \
       [[ "${RALPH_PLAN_CLI_RESUME:-0}" != "1" ]] && \
       [[ "$RALPH_PLAN_RESUME_HINT_EMITTED" != "1" ]] && \
       (( remaining > _resume_hint_threshold )); then
      echo "Hint: $remaining unchecked TODOs remain. Set RALPH_PLAN_CLI_RESUME=1 or pass --cli-resume to reuse the CLI session for long plans." >&2
      ralph_run_plan_log "resume hint emitted (remaining=$remaining threshold=$_resume_hint_threshold)"
      RALPH_PLAN_RESUME_HINT_EMITTED=1
    fi
    unset _resume_hint_threshold

    ralph_run_plan_log "invocation=$iteration next_todo line=$line_num done=$done_count total=$total_count remaining=$remaining attempts_on_line=$attempts_on_line"
    ralph_run_plan_log "todo_text: $todo_text"
    _session_label="none"
    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
      _session_label="${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
    elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
      _session_label="bare"
    fi
    ralph_run_plan_log "current task line=$line_num session=$_session_label strategy=${RALPH_PLAN_SESSION_STRATEGY:-fresh}"
    ralph_run_plan_continuation_summary_sync_plan

    _grader_prompt_block=""
    if ralph_rubric_grader_stage_active; then
      _grader_prompt_block="$(ralph_rubric_grader_prepare_prompt 2>/dev/null || true)"
      ralph_run_plan_log "rubric grader: prepared independent grader prompt block"
    fi

    _router_prompt_block=""
    if [[ "${RALPH_ROUTER_STAGE:-0}" == "1" && -n "${RALPH_ROUTER_CONFIG_JSON:-}" ]]; then
      _router_prompt_block="$(ralph_router_prepare_prompt "$RALPH_ROUTER_CONFIG_JSON" 2>/dev/null || true)"
      ralph_run_plan_log "router stage: prepared router prompt block"
    fi

    _structured_output_prompt_block=""
    if run_plan_structured_output_needs_prompt_contract "$RUNTIME"; then
      _structured_output_prompt_block="$(run_plan_structured_output_build_prompt_block 2>/dev/null || true)"
      if [[ -n "$_structured_output_prompt_block" ]]; then
        ralph_run_plan_log "structured output: injected JSON-only prompt contract"
      fi
    fi

    task_ordinal="$(plan_todo_ordinal_for_next "$PLAN_PATH" "$plan_format" "$line_num")"
    todo_verification=""
    todo_verify=""
    todo_text_for_verification="$todo_text"
    todo_prompt_text="$todo_text"
    todo_prompt_body="$todo_text$todo_multiline_note"
    if plan_format_is_yaml "$plan_format"; then
      todo_verification="$(plan_yaml_frontmatter_op "$PLAN_PATH" "get_verification" "$todo_target" 2>/dev/null || true)"
      if [[ -n "$todo_verification" ]]; then
        todo_text_for_verification+=$'\n'"Verification:"$'\n'"$todo_verification"
        todo_prompt_text+=$'\n'"Verification:"$'\n'"$todo_verification"
      fi
      todo_verify="$(plan_yaml_frontmatter_op "$PLAN_PATH" "get_verify" "$todo_target" 2>/dev/null || true)"
      if [[ -n "$todo_verify" ]]; then
        todo_text_for_verification+=$'\n'"Verify:"$'\n'"$todo_verify"
        todo_prompt_text+=$'\n'"Verify:"$'\n'"$todo_verify"
      fi
    fi
    if [[ -n "${RALPH_RUN_PLAN_INPUT_ARTIFACT_SECTION:-}" ]]; then
      todo_prompt_text+=$'\n\n'"${RALPH_RUN_PLAN_INPUT_ARTIFACT_SECTION}"
    fi
    todo_prompt_body="$todo_prompt_text$todo_multiline_note"
    todo_class="$(plan_todo_risk_classify "$todo_text_for_verification" 2>/dev/null || printf 'normal')"
    todo_hash="$(plan_todo_hash "$todo_text" 2>/dev/null || printf '%s' "$todo_text")"
    _todo_retry_limit="$GUTTER_ITERATIONS"
    if [[ "$todo_class" == "verification_gate" ]] && plan_format_is_yaml "$plan_format"; then
      # Verification-gated TODOs already depend on the agent proving completion
      # via a check or command; do not blind-retry them after a failed pass.
      _todo_retry_limit=0
    fi
    # Determine whether this TODO will route to prose-agent verification so the
    # first-pass prompt can request a verification verdict, avoiding a second
    # agent invocation solely to obtain the result.
    _request_verify_verdict=0
    if [[ "${RALPH_POST_VERIFY:-1}" != "0" ]] && _ralph_todo_declares_verification_metadata "$todo_text_for_verification"; then
      _request_verify_verdict=1
    fi
    _todo_bytes="${#todo_text}"
    _todo_continuation_lines=0
    if [[ "$todo_text" == *$'\n'* ]]; then
      _todo_continuation_lines=$(( $(printf '%s\n' "$todo_text" | wc -l | tr -d ' ') - 1 ))
    fi
    _split_parent_id=""
    if printf '%s\n' "$todo_text" | grep -q "Ralph split parent:"; then
      _split_parent_id="$(printf '%s\n' "$todo_text" | sed -n 's/.*Ralph split parent: \([^ ]*\).*/\1/p' | head -1)"
    fi
    _banner_plan_secs=$(( $(date +%s) - _plan_start_ts ))
    _banner_plan_str="$(ralph_format_elapsed_secs "$_banner_plan_secs")"

    if ! ralph_run_plan_routing_apply_effective_todo_context "$PLAN_PATH" "$plan_format" "$line_num" "$todo_target" "$todo_id"; then
      ralph_run_plan_log "ERROR: TODO routing failed for line=$line_num"
      exit 1
    fi

    ralph_rubric_grader_apply_session_isolation

    RALPH_CURRENT_PLAN_PATH="$PLAN_PATH"
    RALPH_CURRENT_TODO_LINE="$line_num"
    RALPH_CURRENT_TODO_ORDINAL="$task_ordinal"
    RALPH_CURRENT_TODO_ID="$todo_id"
    RALPH_CURRENT_TODO_HASH="$todo_hash"
    export RALPH_CURRENT_PLAN_PATH
    export RALPH_CURRENT_TODO_LINE
    export RALPH_CURRENT_TODO_ORDINAL
    export RALPH_CURRENT_TODO_ID
    export RALPH_CURRENT_TODO_HASH
    # Release any identity frozen for the previous invocation's post-processing;
    # the live RALPH_CURRENT_TODO_* above are authoritative from here.
    if declare -F ralph_session_todo_identity_thaw >/dev/null 2>&1; then
      ralph_session_todo_identity_thaw
    fi

    if declare -F plan_pipeline_has_metadata >/dev/null 2>&1 && plan_pipeline_has_metadata "$PLAN_PATH"; then
      if ! ralph_run_plan_pipeline_input_artifacts_prepare "$PLAN_PATH" "$todo_target" "$line_num"; then
        exit 1
      fi
    else
      RALPH_RUN_PLAN_INPUT_ARTIFACT_PATHS=()
      RALPH_RUN_PLAN_INPUT_ARTIFACT_SECTION=""
    fi

    if [[ -n "${RALPH_PLAN_FILE_PATH:-}" ]]; then
      _nested_plan_file="${RALPH_PLAN_FILE_PATH}"
      _nested_plan_file="${_nested_plan_file//\{\{ARTIFACT_NS\}\}/${RALPH_ARTIFACT_NS:-}}"
      _nested_plan_file="${_nested_plan_file//\{\{PLAN_KEY\}\}/${RALPH_PLAN_KEY:-}}"
      _nested_plan_file="${_nested_plan_file//\{\{STAGE_ID\}\}/${RALPH_STAGE_ID:-}}"
      if [[ ! -f "$_nested_plan_file" ]]; then
        ralph_run_plan_log "ERROR: planFile not found: $_nested_plan_file (todo=$todo_target line=$line_num)"
        exit 1
      fi
      ralph_run_plan_log "planFile delegation: running nested plan $_nested_plan_file (todo=$todo_target stage=${RALPH_STAGE_ID:-} runtime=${RUNTIME:-})"
      _nested_exit=0
      bash "$SCRIPT_DIR/run-plan.sh" \
        --runtime "$RUNTIME" \
        --plan "$_nested_plan_file" \
        --workspace "$WORKSPACE" \
        ${PLAN_MODEL_CLI:+--model "$PLAN_MODEL_CLI"} || _nested_exit=$?
      if [[ "$_nested_exit" -ne 0 ]]; then
        ralph_run_plan_log "ERROR: nested plan failed (exit=$_nested_exit) for planFile=$_nested_plan_file"
        exit "$_nested_exit"
      fi
      if declare -F plan_pipeline_has_metadata >/dev/null 2>&1 && plan_pipeline_has_metadata "$PLAN_PATH"; then
        if ! ralph_run_plan_pipeline_output_artifacts_verify "$PLAN_PATH" "$todo_target" "$line_num"; then
          read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
          _ralph_write_plan_usage_summary "$done_count" "$total_count"
          ralph_runtime_overlay_cleanup_if_needed
          exit 1
        fi
      fi
      if ! ralph_graph_write_scope_verify_todo "${todo_id:-todo-$line_num}"; then
        ralph_runtime_overlay_cleanup_if_needed
        exit 1
      fi
      if run_plan_mark_and_confirm "$PLAN_PATH" "$plan_format" "$todo_target" "$line_num"; then
        ralph_run_plan_log "planFile stage completed: todo=$todo_target planFile=$_nested_plan_file"
        ralph_run_plan_routing_restore_baseline
      fi
      continue
    fi

    # Direct-verification path. Disabled by default so agent-authored
    # VERIFICATION_RESULT can complete the TODO without rerunning the command.
    if [[ "${RALPH_PLAN_VERIFY_DIRECT:-0}" == "1" ]]; then
      _direct_command=""
      _direct_command="$(ralph_plan_direct_verification_command "$todo_text_for_verification" 2>/dev/null || true)"
      if [[ -n "$_direct_command" ]]; then
        ralph_run_plan_log "direct verification selected for line=$line_num command=$_direct_command"
        start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
        _inv_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        START_TIME="$(date +%s)"
        echo -e "${C_G}Running direct verification for TODO line $line_num at ${start_ts}: ${_direct_command}${C_RST}" >&2
        {
          echo ""
          echo "================================================================================"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Direct verification $iteration | TODO (line $line_num): $todo_text"
          echo "Command: $_direct_command"
          echo "================================================================================"
          echo ""
        } >> "$OUTPUT_LOG"
        set +e
        _direct_output="$(cd "$WORKSPACE" && bash -lc "$_direct_command" 2>&1)"
        _direct_exit=$?
        set -e
        if command -v python3 >/dev/null 2>&1 \
          && [[ -f "$SCRIPT_DIR/python/pretty_result_store.py" ]]; then
          PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
            printf '%s' "$_direct_output" \
            | python3 "$SCRIPT_DIR/python/pretty_result_store.py" log-summary \
            >>"$OUTPUT_LOG"
        else
          printf '%s\n' "$_direct_output" >>"$OUTPUT_LOG"
        fi
        _inv_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _inv_elapsed=$(( $(date +%s) - START_TIME ))
        _direct_completed=0
        if [[ "$_direct_exit" -eq 0 ]]; then
          if declare -F plan_pipeline_has_metadata >/dev/null 2>&1 && plan_pipeline_has_metadata "$PLAN_PATH"; then
            if ! ralph_run_plan_pipeline_output_artifacts_verify "$PLAN_PATH" "$todo_target" "$line_num"; then
              read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
              _ralph_write_plan_usage_summary "$done_count" "$total_count"
              ralph_runtime_overlay_cleanup_if_needed
              exit 1
            fi
          fi
          if ! ralph_graph_write_scope_verify_todo "${todo_id:-todo-$line_num}"; then
            ralph_runtime_overlay_cleanup_if_needed
            exit 1
          fi
          if run_plan_mark_and_confirm "$PLAN_PATH" "$plan_format" "$todo_target" "$line_num"; then
            _direct_completed=1
            ralph_run_plan_log "direct verification completed line=$line_num elapsed=${_inv_elapsed}s"
            ralph_run_plan_routing_restore_baseline
          else
            _direct_mark_status=$?
            if [[ "$_direct_mark_status" -eq 5 ]]; then
              ralph_run_plan_log "ERROR: TODO id=${todo_id:-$todo_target} line=$line_num reported marked but is still open (plan integrity)"
              read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
              _ralph_write_plan_usage_summary "$done_count" "$total_count"
              ralph_runtime_overlay_cleanup_if_needed
              exit 1
            fi
            ralph_run_plan_log "ERROR: direct verification passed but could not mark line=$line_num complete"
            exit 1
          fi
        else
          ralph_run_plan_log "direct verification failed line=$line_num exit=$_direct_exit elapsed=${_inv_elapsed}s"
        fi
        _ralph_append_invocation_usage_history \
          "$RALPH_LOG_DIR/invocation-usage.json" \
          "$iteration" \
          "${SELECTED_MODEL:-}" \
          "$RUNTIME" \
          "$_inv_elapsed" \
          0 0 0 0 0 0 \
          "$_inv_started_at" \
          "$_inv_ended_at" \
          "${RALPH_PLAN_KEY:-}" \
          "${RALPH_STAGE_ID:-}" \
          "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" \
          "$line_num" \
          "$task_ordinal" \
          "$_direct_completed" \
          "$todo_class" \
          "$todo_hash" \
          "$([[ "$_direct_exit" -eq 0 ]] && printf 0 || printf 1)" \
          "0" \
          "0" \
          "$_todo_bytes" \
          "$_todo_continuation_lines" \
          "$_split_parent_id" \
          "1" \
          "" \
          "0" \
          "" \
          "$(_ralph_runtime_overlay_summary_path_for_usage)"
        if [[ "$_direct_exit" -eq 0 ]]; then
          break
        fi
        echo -e "${C_R}Direct verification failed for TODO line $line_num. See $OUTPUT_LOG.${C_RST}" >&2
        exit 1
      fi
    fi

    echo ""
    echo -e "${C_C}${C_BOLD}═══════════════════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_C}Plan:${C_RST} $PLAN_PATH"
    echo -e "${C_DIM}-----------------------------------------------------------------------------------${C_RST}"
    _banner_ralph_mode_style=""
    case "${RALPH_MODE:-no}" in
      hybrid|ralph)
        _banner_ralph_mode_style="${C_G}"
        ;;
      *)
        _banner_ralph_mode_style="${C_DIM}"
        ;;
    esac
    echo -e "  ${C_DIM}${C_RST}  ${C_BOLD}TASK ${task_ordinal}${C_RST}  ${C_DIM}|${C_RST}  Complete ${C_G}$done_count/$total_count |${C_RST} Skipped: 0 ${C_DIM}|${C_RST}  ${C_Y}Invoke $iteration${C_RST} (line $line_num)  ${C_DIM}|${C_RST}  ${_banner_ralph_mode_style}Ralph Mode: ${RALPH_MODE:-no}${C_RST}"
    echo -e "${C_DIM}-----------------------------------------------------------------------------------${C_RST}"
    echo -e "  ${C_C}Model:${C_RST} ${C_BOLD}${SELECTED_MODEL:-default}${C_RST}  ${C_DIM}|${C_RST}  ${C_C}Runtime:${C_RST} ${C_BOLD}${RUNTIME}${C_RST}  ${C_DIM}|${C_RST}  ${C_C}Plan Elapsed:${C_RST} ${C_BOLD}${_banner_plan_str}${C_RST}"
    echo -e "${C_C}${C_BOLD}═══════════════════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_BOLD}$todo_text${C_RST}"
    echo -e "${C_DIM}Log: $LOG_FILE  |  Output: $OUTPUT_LOG${C_RST}"
    echo ""
    _plan_format_display="$(plan_format_display "$plan_format")"
    ralph_run_plan_log "todo classification: class=$todo_class hash=$todo_hash format=$_plan_format_display ordinal=$task_ordinal"

    # Refresh resume env from runtime-specific session-id files / flags before building PROMPT (compact vs full context).
    ralph_session_todo_prepare_invocation

    _hc_included_bytes=0
    _ds_stage_count=0
    _prompt_mode="fresh"
    RALPH_RUN_PLAN_RESET_COMMAND_USED=0
    export RALPH_RUN_PLAN_RESET_COMMAND_USED
    _session_strategy="${RALPH_PLAN_SESSION_STRATEGY:-fresh}"
    _agent_verify_strategy_override=0

    # Agent-reported verification failure retry still uses compact/resume strategy
    # override when available. Runner-owned post-verification repair uses the
    # tier-2 continuation record and todo-continue session resolver instead.
    if [[ "$_post_verify_reopen_retry_active" == "1" ]]; then
      _post_verify_reopen_retry_active=0
      _agent_verify_strategy_override=1
      if [[ -n "${_ralph_compact_command_for_runtime:-}" ]]; then
        ralph_run_plan_log "agent verification reopen retry line=$line_num: forcing compact resume (strategy=$_session_strategy -> compact) with prior failure context"
        _session_strategy="compact"
      else
        ralph_run_plan_log "agent verification reopen retry line=$line_num: compact resume unavailable for runtime=$RUNTIME; falling back to plain resume (strategy=$_session_strategy -> resume) with prior failure context"
        _session_strategy="resume"
      fi
      RALPH_PLAN_SESSION_STRATEGY="$_session_strategy"
      export RALPH_PLAN_SESSION_STRATEGY
      # Re-apply resume strategy so session id/bare flags align with the override.
      ralph_session_todo_prepare_invocation
      # Recompute effective strategy in case apply changed it (e.g. no stored id and bare not allowed).
      _session_strategy="${RALPH_PLAN_SESSION_STRATEGY:-$_session_strategy}"
    fi
    if [[ "$_session_strategy" == "reset" ]] && ([[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] || ([[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]])); then
      _prompt_mode="reset"
      _reset_command=""
      if [[ -n "${RALPH_PLAN_RESET_COMMAND:-}" ]]; then
        _reset_command="${RALPH_PLAN_RESET_COMMAND}"
      else
        case "$RUNTIME" in
          claude)
            _reset_command="${RALPH_PLAN_RESET_COMMAND_CLAUDE:-/clear}"
            ;;
          cursor)
            _reset_command="${RALPH_PLAN_RESET_COMMAND_CURSOR:-}"
            ;;
          codex)
            _reset_command="${RALPH_PLAN_RESET_COMMAND_CODEX:-}"
            ;;
          opencode)
            _reset_command="${RALPH_PLAN_RESET_COMMAND_OPENCODE:-}"
            ;;
          *)
            _reset_command=""
            ;;
        esac
      fi
      _reset_prefix=""
      if [[ -n "$_reset_command" ]]; then
        _reset_prefix="${_reset_command}"$'\n\n'
        RALPH_RUN_PLAN_RESET_COMMAND_USED=1
        export RALPH_RUN_PLAN_RESET_COMMAND_USED
      fi
      if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
        if [[ -n "$_reset_command" ]]; then
          _resume_intro="Reusing the same CLI session id in reset mode (--resume) and issuing a reset command first."
        else
          _resume_intro="Reusing the same CLI session id in reset mode (--resume)."
        fi
      else
        if [[ -n "$_reset_command" ]]; then
          _resume_intro="Reusing bare CLI resume in reset mode (last-session semantics; isolated CI only) and issuing a reset command first."
        else
          _resume_intro="Reusing bare CLI resume in reset mode (last-session semantics; isolated CI only)."
        fi
      fi
      _resume_intro="$(ralph_run_plan_resume_intro_with_reason "$_resume_intro")"
      PROMPT_STATIC="$(ralph_run_plan_rebuild_prompt_static)"
      PROMPT="${_reset_prefix}$_resume_intro

**TODO (line $line_num):** $todo_prompt_body

Reset contract:
- Treat this as a fresh task.
- Ignore previous task-specific conversation state unless re-verified from files.
- Keep only durable system/tool constraints that still apply.

$(ralph_run_plan_agent_completion_prompt_block "$line_num" "$PLAN_PATH" "$PENDING_ABS" "$_request_verify_verdict")

Start with the exact files or commands named in the TODO. Do not reread README/AGENTS or remap the repo unless the TODO requires missing context.
Cost model: prefer strict \`verify:\` for final proof; use one blocking call for anything that fits; never author polling loops (\`while grep -c ...; sleep\` over a log). Async proxy shell tools are a manual human-monitoring fallback only—when used, block with \`ralph_proxy_shell_wait\` and pass \`waitSeconds\` near its 600 cap (default is only 60); \`shell_status\` is an occasional spot check, never a polling loop. Continuation prompts stay compact: continue this TODO from the evidence above; do not redo it from scratch."

    elif [[ "$_session_strategy" == "compact" ]] && ([[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] || ([[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]])); then
      _prompt_mode="compact"
      _compact_command=""
      if [[ -n "${RALPH_PLAN_COMPACT_COMMAND:-}" ]]; then
        _compact_command="${RALPH_PLAN_COMPACT_COMMAND}"
      else
        case "$RUNTIME" in
          claude)
            if [[ -n "${RALPH_PLAN_RESET_COMMAND:-}" ]]; then
              _compact_command="${RALPH_PLAN_RESET_COMMAND}"
            else
              _compact_command="${RALPH_PLAN_RESET_COMMAND_CLAUDE:-/clear}"
            fi
            ;;
          cursor)
            _compact_command="${RALPH_PLAN_COMPACT_COMMAND_CURSOR:-/compress}"
            ;;
          codex)
            _compact_command="${RALPH_PLAN_COMPACT_COMMAND_CODEX:-/compact}"
            ;;
          opencode)
            _compact_command="${RALPH_PLAN_COMPACT_COMMAND_OPENCODE:-}"
            ;;
          *)
            _compact_command=""
            ;;
        esac
      fi
      _compact_prefix=""
      if [[ -n "$_compact_command" ]]; then
        _compact_prefix="${_compact_command}"$'\n\n'
        RALPH_RUN_PLAN_RESET_COMMAND_USED=1
        export RALPH_RUN_PLAN_RESET_COMMAND_USED
      fi
      if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
        if [[ -n "$_compact_command" ]]; then
          _resume_intro="Reusing the same CLI session id in compact mode (--resume) and issuing ${_compact_command} first."
        else
          _resume_intro="Reusing the same CLI session id in compact mode (--resume)."
        fi
      else
        if [[ -n "$_compact_command" ]]; then
          _resume_intro="Reusing bare CLI resume in compact mode (last-session semantics; isolated CI only) and issuing ${_compact_command} first."
        else
          _resume_intro="Reusing bare CLI resume in compact mode (last-session semantics; isolated CI only)."
        fi
      fi
      _resume_intro="$(ralph_run_plan_resume_intro_with_reason "$_resume_intro")"
      PROMPT_STATIC="$(ralph_run_plan_rebuild_prompt_static)"
      _compact_label="${_compact_command:-the compact command}"
      PROMPT="${_compact_prefix}$_resume_intro

**TODO (line $line_num):** $todo_prompt_body

Compact contract:
- Treat this as a fresh task.
- Ignore previous task-specific conversation state unless re-verified from files.
- Keep only durable system/tool constraints that still apply.
- Issue ${_compact_label} before continuing.

$(ralph_run_plan_agent_completion_prompt_block "$line_num" "$PLAN_PATH" "$PENDING_ABS" "$_request_verify_verdict")

Start with the exact files or commands named in the TODO. Do not reread README/AGENTS.md or remap the repo unless the TODO requires missing context.
Cost model: prefer strict \`verify:\` for final proof; use one blocking call for anything that fits; never author polling loops (\`while grep -c ...; sleep\` over a log). Async proxy shell tools are a manual human-monitoring fallback only—when used, block with \`ralph_proxy_shell_wait\` and pass \`waitSeconds\` near its 600 cap (default is only 60); \`shell_status\` is an occasional spot check, never a polling loop. Continuation prompts stay compact: continue this TODO from the evidence above; do not redo it from scratch."

    elif [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] || ([[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]); then
      _prompt_mode="resume"
      if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
        _resume_intro="Continuing the same CLI session (--resume)."
      else
        _resume_intro="Continuing via bare CLI resume (last-session semantics; isolated CI only)."
      fi
      _resume_intro="$(ralph_run_plan_resume_intro_with_reason "$_resume_intro")"
      PROMPT_STATIC="$(ralph_run_plan_rebuild_prompt_static)"
      PROMPT="$_resume_intro

**TODO (line $line_num):** $todo_prompt_body

$(ralph_run_plan_agent_completion_prompt_block "$line_num" "$PLAN_PATH" "$PENDING_ABS" "$_request_verify_verdict")

Start with the exact files or commands named in the TODO. Do not reread README/AGENTS or remap the repo unless the TODO requires missing context.
Cost model: prefer strict \`verify:\` for final proof; use one blocking call for anything that fits; never author polling loops. Async proxy shell tools are a manual human-monitoring fallback only—when used, block with \`ralph_proxy_shell_wait\` and pass \`waitSeconds\` near its 600 cap; \`shell_status\` is never a polling loop. Continue this TODO from prior evidence; do not redo it from scratch."

    else
      # Per-TODO variable portion -- kept short so PROMPT_STATIC carries the bulk.
      PROMPT="Complete exactly this TODO and nothing else:

**TODO (line $line_num):** $todo_prompt_text

**Plan file:** \`$PLAN_PATH\`

Rules:
- Use the repo toolchain documented in README/AGENTS.md. Follow verification steps in the plan.
- If the TODO already specifies exact files or commands, start there. Do not reread README/AGENTS.md or remap the repo unless the TODO requires missing context.
- Prefer targeted search and partial file/log reads first; avoid full log reads unless needed.
- Cost model (cheapest first): prefer strict runner-owned \`verify:\` for final proof; use one blocking call for anything that fits in one; background only work that outlives the tool timeout (when enabled).
- Agent-authored polling loops are forbidden (for example \`while grep -c ...; sleep\` over a log file). Never spend model turns polling a log or job status.
- \`ralph_proxy_shell\` (synchronous) is for short bounded exploratory commands only (e.g., \`ls\`, \`cat\`, \`grep\`, \`git status\`). Do not run test/lint/build/install/docs-check commands through \`ralph_proxy_shell\`; those block the MCP transport and risk dropping the connection.
- Verification ownership: long-running verification and completion checks belong to the runner, not the agent loop. The runner executes strict \`verify:\` / plan-level \`verify:\` commands out-of-process, stores full output as a compact artifact, and reopens the TODO with a short failure summary—do not rerun those commands through agent-side shell helpers.
- When you must rerun a verification manually (agent-run \`verification:\` only), launch it with \`ralph_proxy_shell_start\`, block on completion with \`ralph_proxy_shell_wait\` (pass \`waitSeconds\` near its 600 cap; default is only 60), treat \`ralph_proxy_shell_status\` as an occasional manual progress check, inspect the stored output with \`ralph_proxy_shell_read\`, and cancel with \`ralph_proxy_shell_cancel\` when necessary.
- The async shell tools are a manual human-monitoring fallback only. \`shell_wait\` is the blocking call only in that manual context; \`shell_status\` is an occasional spot check, never a polling loop.
$(ralph_run_plan_fresh_completion_rules_block "$line_num" "$PENDING_ABS" "$_request_verify_verdict")"

    fi

    if [[ "$_prompt_mode" == "fresh" ]]; then
      case "${RALPH_MODE:-no}" in
        ralph|hybrid)
          PROMPT+=$'\n- Cost model: prefer strict `verify:` for final proof; one blocking call when it fits; never author polling loops (`while grep -c ...; sleep`).'
          PROMPT+=$'\n- `ralph_proxy_shell` (synchronous) is for short bounded exploratory commands only. Do not run test/lint/build/install commands through `ralph_proxy_shell`; those block the MCP transport.'
          PROMPT+=$'\n- Verification ownership: long-running verification and completion checks belong to the runner, not the agent loop. The runner executes strict `verify:` / plan-level `verify:` commands out-of-process, stores full output as a compact artifact, and reopens the TODO with a short failure summary—do not rerun those commands through `ralph_proxy_shell_start` + `ralph_proxy_shell_status` loops; only rerun verification manually for agent-run `verification:` instructions.'
          PROMPT+=$'\n- The async shell tools are a manual human-monitoring fallback only. When used, block with `ralph_proxy_shell_wait` and pass `waitSeconds` near its 600 cap (default is only 60); `shell_status` is an occasional spot check, never a polling loop.'
          if [[ "${RALPH_BG_JOBS:-0}" == "1" ]]; then
            PROMPT+=$'\n- Background jobs (RALPH_BG_JOBS=1): for work that outlives the tool timeout, start `.ralph/ralph-bg.sh '\''<command>'\''` and end the turn without claiming completion. Do not poll; do not redo the TODO from scratch when the runner continues with the result.'
          fi
          ;;
      esac
    fi

    # Attempt-bound action capability + optional answered-input injection.
    if declare -F ralph_run_plan_prepare_workflow_operator_input >/dev/null 2>&1; then
      ralph_run_plan_prepare_workflow_operator_input "${todo_id:-}" || true
    fi

    # Workflow stage instructions + OPERATOR_INPUT (+ optional RESPONSE) immediately
    # before TODO content. Order: stage instructions, protocol, response, TODO.
    # Never mutates plan files; never includes capability nonce.
    _wsi_block=""
    _oi_block=""
    _oir_block=""
    if declare -F ralph_workflow_stage_instructions_prompt_block >/dev/null 2>&1; then
      _wsi_block="$(ralph_workflow_stage_instructions_prompt_block)"
    fi
    if ralph_run_plan_workflow_operator_input_active 2>/dev/null; then
      if declare -F ralph_workflow_operator_input_protocol_prompt_block >/dev/null 2>&1; then
        _oi_block="$(ralph_workflow_operator_input_protocol_prompt_block)"
      fi
      if declare -F ralph_workflow_operator_input_response_prompt_block >/dev/null 2>&1; then
        _oir_block="$(ralph_workflow_operator_input_response_prompt_block)"
      fi
    fi
    _wf_prefix=""
    for _wf_part in "$_wsi_block" "$_oi_block" "$_oir_block"; do
      [[ -n "$_wf_part" ]] || continue
      if [[ -n "$_wf_prefix" ]]; then
        _wf_prefix="${_wf_prefix}"$'\n\n'"${_wf_part}"
      else
        _wf_prefix="$_wf_part"
      fi
    done
    if [[ -n "$_wf_prefix" ]]; then
      PROMPT="${_wf_prefix}"$'\n\n'"$PROMPT"
    fi

    if ! ralph_rubric_grader_stage_active; then
      ralph_run_plan_continuation_summary_inject
    fi
    if ralph_rubric_grader_stage_active; then
      PROMPT="${_grader_prompt_block}"$'\n\n'"$PROMPT"
    fi
    if [[ -n "${_router_prompt_block:-}" ]]; then
      PROMPT="${_router_prompt_block}"$'\n\n'"$PROMPT"
    fi
    if [[ -n "${_structured_output_prompt_block:-}" ]]; then
      PROMPT="${_structured_output_prompt_block}"$'\n\n'"$PROMPT"
    fi

    if [[ -n "${RALPH_RUN_PLAN_BG_JOB_CONTINUATION:-}" ]]; then
      ralph_run_plan_capture_bg_continuation_usage_telemetry "$RALPH_RUN_PLAN_BG_JOB_CONTINUATION"
      PROMPT+=$'\n\n'"$(ralph_bg_invocation_format_prompt_block "$RALPH_RUN_PLAN_BG_JOB_CONTINUATION")"
      ralph_bg_invocation_mark_continuation_consumed "$RALPH_RUN_PLAN_BG_JOB_CONTINUATION" >/dev/null 2>&1 || true
      unset RALPH_RUN_PLAN_BG_JOB_CONTINUATION
    fi

    if [[ -n "${POST_VERIFICATION_FAILURE_SUMMARY:-}" || -n "${POST_VERIFICATION_FAILURE_REASON:-}" ]]; then
      PROMPT+=$'\n\n**Post-verification failure (runner-owned check):**\n'"${POST_VERIFICATION_FAILURE_SUMMARY}"
      if [[ -n "${POST_VERIFICATION_FAILURE_REASON:-}" ]]; then
        PROMPT+=$'\nReason: '"${POST_VERIFICATION_FAILURE_REASON}"
      fi
      if [[ -n "${POST_VERIFICATION_FAILURE_COMMAND:-}" ]]; then
        PROMPT+=$'\nCommand: '"${POST_VERIFICATION_FAILURE_COMMAND}"
      fi
      if [[ -n "${POST_VERIFICATION_FAILURE_ARTIFACT:-}" ]]; then
        PROMPT+=$'\nFull output stored as a compact artifact at `'"${POST_VERIFICATION_FAILURE_ARTIFACT}"'` — use `ralph_proxy_result_read` or `ralph_proxy_read` with offset/limit if you need details beyond this summary.'
      fi
      PROMPT+=$'\n\nThis TODO was already implemented; the runner-executed verification step above failed. Preserve the existing work and fix only the failing verification. Do not rerun the same verify command—the runner will re-execute it after you mark this TODO complete.'
      POST_VERIFICATION_FAILURE_SUMMARY=""
      POST_VERIFICATION_FAILURE_REASON=""
      POST_VERIFICATION_FAILURE_COMMAND=""
      POST_VERIFICATION_FAILURE_ARTIFACT=""
    fi

    if [[ -n "${RALPH_VERIFY_REQUEST_MSG:-}" ]]; then
      PROMPT+=$'\n\n**Verification required (report the result):**\n'"${RALPH_VERIFY_REQUEST_MSG}"
      RALPH_VERIFY_REQUEST_MSG=""
    fi

    if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
      _hc_max="${RALPH_HUMAN_CONTEXT_MAX_BYTES:-8192}"
      if [[ "${RALPH_PLAN_CONTEXT_BUDGET:-standard}" != "full" ]]; then
        _hc_max="${RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME:-2048}"
      fi
      _hc_size="$(wc -c < "$HUMAN_CONTEXT" 2>/dev/null || echo 0)"
      if [[ "$_hc_size" -gt "$_hc_max" ]]; then
        _hc_content="$(tail -c "$_hc_max" "$HUMAN_CONTEXT")"
        PROMPT+=$'\n\n## Human operator answers\n[Note: trimmed to last '"$_hc_max"' bytes]\n'"$_hc_content"
        _hc_included_bytes="$_hc_max"
      else
        PROMPT+=$'\n\n## Human operator answers\n'"$(<"$HUMAN_CONTEXT")"
        _hc_included_bytes="$_hc_size"
      fi
    fi

    # Common prompt assembly boundary (every runtime):
    # preamble, contracts (namespace), task.
    # Stage instructions (when set) already precede TODO content inside PROMPT.
    # Do not inject the old profile context block (module retained, unused here).
    _ns_block="$(ralph_run_plan_namespace_prompt_block)"
    _preamble="$(ralph_runtime_prompt_guidance "$RUNTIME")"
    _mode_guidance=""
    if [[ "${RALPH_MODE:-no}" != "no" ]]; then
      _mode_guidance="$(ralph_mode_prompt_guidance "$RUNTIME" "${RALPH_MODE:-no}")"
    fi
    if [[ -n "$_preamble" && -n "$_mode_guidance" ]]; then
      _preamble="${_preamble}"$'\n\n'"${_mode_guidance}"
    elif [[ -n "$_mode_guidance" ]]; then
      _preamble="$_mode_guidance"
    fi
    ralph_run_plan_apply_ordered_prompt_assembly "$RUNTIME" "$_preamble" "$_ns_block"

    # Preamble (mode/runtime guidance) is applied above in ordered assembly.

    # Export PROMPT_STATIC: Claude invoke passes it via --system-prompt; other runtimes already
    # received the fully ordered prompt (no fake cache-control markers).
    export PROMPT_STATIC
    ralph_run_plan_continuation_summary_refresh_metrics
    ralph_run_plan_log "continuation summary: bytes=${RALPH_CONTINUATION_SUMMARY_BYTES:-0} entries=${RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT:-0} truncations=${RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT:-0}"
    # Prompt size measurement and warning.
    _prompt_bytes="${#PROMPT}"
    _prompt_est_tokens=$(( _prompt_bytes / 4 ))
    ralph_run_plan_log "prompt size: bytes=${_prompt_bytes} est_tokens=${_prompt_est_tokens}"
    ralph_run_plan_log "context footprint: mode=${_prompt_mode} context_budget=${RALPH_PLAN_CONTEXT_BUDGET:-standard} hc_bytes=${_hc_included_bytes:-0} ds_stages=${_ds_stage_count:-0}"
    _prompt_warn_threshold="${RALPH_PROMPT_SIZE_WARN_BYTES:-40000}"
    if [[ "$_prompt_bytes" -gt "$_prompt_warn_threshold" ]]; then
      echo "Warning: prompt is large (${_prompt_bytes} bytes, ~${_prompt_est_tokens} tokens). Consider reducing rules, human context, or downstream stages." >&2
    fi

    _invoke_resume_note=""
    _banner_resume_note=""
    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
      _invoke_resume_note=" session_id=${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
      _banner_resume_note=", session ${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
    elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
      _invoke_resume_note=" resume=bare"
      _banner_resume_note=", bare resume"
    fi
    if [[ "$_agent_verify_strategy_override" == "1" && "$_prompt_mode" == "compact" ]]; then
      _invoke_resume_note+=" strategy_override=agent-verify-compact"
      _banner_resume_note+=", agent-verify compact retry"
    elif [[ "$_agent_verify_strategy_override" == "1" && "$_prompt_mode" == "resume" ]]; then
      _invoke_resume_note+=" strategy_override=agent-verify-resume"
      _banner_resume_note+=", agent-verify resume retry"
    elif [[ "${RALPH_POST_VERIFY_REPAIR_CONTINUATION:-}" == "1" ]]; then
      _invoke_resume_note+=" continuation=post-verification-repair"
      _banner_resume_note+=", post-verification repair"
    fi
    unset RALPH_POST_VERIFY_REPAIR_CONTINUATION
    ralph_run_plan_log "invoking $RALPH_INVOKED_CLI (model=${SELECTED_MODEL:-default})${_invoke_resume_note} | Ralph Mode: ${RALPH_MODE:-no}"

    # Optional: run compression audit mode before invocation if enabled
    if [[ "${RALPH_AUDIT_COMPRESSION:-0}" == "1" ]]; then
      ralph_run_plan_compression_audit || true
    fi

    start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${C_G}Starting agent ${C_BOLD}(${SELECTED_MODEL:-default})${C_RST}${C_G}${_banner_resume_note} for this TODO at ${start_ts}...${C_RST}"
    echo ""

    {
      echo ""
      echo "================================================================================"
      _olog_inv="[$(date '+%Y-%m-%d %H:%M:%S')] Invocation $iteration | TODO (line $line_num): $todo_text"
      if [[ -n "$_invoke_resume_note" ]]; then
        _olog_inv+=" |${_invoke_resume_note# }"
      fi
      echo "$_olog_inv"
      echo "================================================================================"
      echo ""
    } >> "$OUTPUT_LOG"

    cd "$WORKSPACE"
    GIT_STATUS_AT_START="$(git -C "$WORKSPACE" status --short --untracked-files=all 2>/dev/null || true)"

    # Sidecar files for this invocation: CLI exit code; AGENT_PID watches the background shell.
    EXIT_CODE_FILE="$RALPH_LOG_DIR/.plan-runner-exit.$$"
    # Per-invocation usage JSON written by demux.py when JSON streaming is enabled.
    USAGE_FILE="$RALPH_LOG_DIR/.plan-runner-usage.$$.json"
    export USAGE_FILE
    rm -f "$USAGE_FILE"
    # CLI PID sidecar containing the live runtime CLI process ID (for targeted termination).
    RALPH_PLAN_INVOCATION_CLI_PID_FILE="$RALPH_LOG_DIR/.plan-runner-cli-pid.$$"
    export RALPH_PLAN_INVOCATION_CLI_PID_FILE
    rm -f "$RALPH_PLAN_INVOCATION_CLI_PID_FILE"
    # Guard PID sidecar so teardown can reap the signal-immune group guard directly.
    RALPH_PLAN_INVOCATION_GUARD_PID_FILE="$RALPH_LOG_DIR/.plan-runner-guard-pid.$$"
    export RALPH_PLAN_INVOCATION_GUARD_PID_FILE
    rm -f "$RALPH_PLAN_INVOCATION_GUARD_PID_FILE"
    PROGRESS_INTERVAL="${CURSOR_PLAN_PROGRESS_INTERVAL:-30}"
    AGENT_POLL_INTERVAL="${RALPH_PLAN_AGENT_POLL_INTERVAL:-1}"
    START_TIME="$(date +%s)"
    RALPH_PLAN_INVOCATION_CLI_START_FILE="$RALPH_LOG_DIR/.plan-runner-cli-start.$$"
    export RALPH_PLAN_INVOCATION_CLI_START_FILE
    rm -f "$RALPH_PLAN_INVOCATION_CLI_START_FILE"
    _inv_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    LOG_SIZE_AT_START="$(wc -c < "$OUTPUT_LOG" 2>/dev/null || echo 0)"
    FIRST_RESPONSE_SHOWN=0
    LAST_PROGRESS_AT=0
    ralph_run_plan_abort_if_kill_switch
    set +e
    _inv_used_resume_session_id=0
    _inv_resume_session_id=""
    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
      _inv_used_resume_session_id=1
      _inv_resume_session_id="${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
    fi
    if [[ "$_RALPH_RUNTIME_OVERLAY_ACTIVE" == "1" ]]; then
      _RALPH_RUNTIME_OVERLAY_CLEANUP_DONE=0
    fi
    _ralph_default_approval_timeout="${RALPH_APPROVAL_TIMEOUT_DEFAULT:-120}"
    _ralph_long_approval_timeout="${RALPH_APPROVAL_TIMEOUT_LONG:-300}"
    approval_timeout="${RALPH_APPROVAL_TIMEOUT:-}"
    if [[ -z "$approval_timeout" ]]; then
      case "$RUNTIME" in
        claude)
          approval_timeout="${RALPH_APPROVAL_TIMEOUT_CLAUDE:-$_ralph_long_approval_timeout}"
          ;;
        codex)
          approval_timeout="${RALPH_APPROVAL_TIMEOUT_CODEX:-$_ralph_long_approval_timeout}"
          ;;
        *)
          approval_timeout="${RALPH_APPROVAL_TIMEOUT_CURSOR:-$_ralph_default_approval_timeout}"
          ;;
      esac
    fi
    export RALPH_APPROVAL_TIMEOUT="$approval_timeout"

    if declare -F ralph_runtime_config_mcp_resolve >/dev/null 2>&1; then
      if ! ralph_runtime_config_mcp_resolve "$RUNTIME" "${RALPH_PROJECT_ROOT:-$WORKSPACE}" "${PREBUILT_AGENT:-}" "$WORKSPACE"; then
        ralph_run_plan_log "ERROR: runtime MCP overlay preflight failed before CLI invocation"
        exit 1
      fi
    fi

    # Run each agent invocation in its own process group, with a guard inside
    # that group that reaps it if the runner dies without completing teardown.
    unset RALPH_RUN_PLAN_AGENT_TEARDOWN_DONE
    set -m
    case "$RUNTIME" in
      cursor)
        # shellcheck source=bash-lib/run-plan/run-plan-invoke-cursor.sh
        source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-invoke-cursor.sh"
        ralph_run_plan_invoke_with_group_guard ralph_run_plan_invoke_cursor &
        ;;
      claude)
        # shellcheck source=bash-lib/run-plan/run-plan-invoke-claude.sh
        source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-invoke-claude.sh"
        ralph_run_plan_invoke_with_group_guard ralph_run_plan_invoke_claude &
        ;;
      codex)
        # shellcheck source=bash-lib/run-plan/run-plan-invoke-codex.sh
        source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-invoke-codex.sh"
        ralph_run_plan_invoke_with_group_guard ralph_run_plan_invoke_codex &
        ;;
      opencode)
        # shellcheck source=bash-lib/run-plan/run-plan-invoke-opencode.sh
        source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-invoke-opencode.sh"
        ralph_run_plan_invoke_with_group_guard ralph_run_plan_invoke_opencode &
        ;;
      antigravity)
        # shellcheck source=bash-lib/run-plan/run-plan-invoke-antigravity.sh
        source "$SCRIPT_DIR/bash-lib/run-plan/run-plan-invoke-antigravity.sh"
        ralph_run_plan_invoke_with_group_guard ralph_run_plan_invoke_antigravity &
        ;;
      *)
        ralph_die "Error: unsupported runtime for invocation: $RUNTIME"
        ;;
    esac
    AGENT_PID=$!
    disown "$AGENT_PID" 2>/dev/null || true
    set +m 2>/dev/null || true

    while kill -0 "$AGENT_PID" 2>/dev/null; do
      ralph_run_plan_approvals_check_pending || true
      sleep "$AGENT_POLL_INTERVAL"
      # Runtime invokers write the CLI result before their outer process group
      # fully unwinds. Do not let a lingering wrapper keep a completed TODO
      # running forever: once the authoritative exit sidecar exists, reap the
      # invocation group and continue through the normal completion path.
      if [[ -f "$EXIT_CODE_FILE" ]]; then
        ralph_run_plan_log "$RALPH_INVOKED_CLI wrote its exit result; reaping lingering invocation wrapper (pid=$AGENT_PID)"
        ralph_run_plan_agent_teardown
        break
      fi
      if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        break
      fi
      now="$(date +%s)"
      elapsed=$((now - START_TIME))
      _timeout_elapsed=""
      if [[ -f "${RALPH_PLAN_INVOCATION_CLI_START_FILE:-}" ]]; then
        _cli_start_ts="$(cat "$RALPH_PLAN_INVOCATION_CLI_START_FILE" 2>/dev/null || true)"
        if [[ "$_cli_start_ts" =~ ^[0-9]+$ ]]; then
          _timeout_elapsed=$((now - _cli_start_ts))
        fi
      fi

      if [[ $FIRST_RESPONSE_SHOWN -eq 0 ]]; then
        current_size="$(wc -c < "$OUTPUT_LOG" 2>/dev/null || echo 0)"
        if [[ "$current_size" -gt "$LOG_SIZE_AT_START" ]]; then
          FIRST_RESPONSE_SHOWN=1
          new_bytes=$((current_size - LOG_SIZE_AT_START))
          first_line="$(tail -c "$new_bytes" "$OUTPUT_LOG" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 120)"
          if [[ -n "$first_line" ]]; then
            echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent first output: ${first_line}${C_RST}" >&2
          else
            echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent has started producing output.${C_RST}" >&2
          fi
        fi
      fi

      if [[ $elapsed -ge $((LAST_PROGRESS_AT + PROGRESS_INTERVAL)) ]]; then
        LAST_PROGRESS_AT=$elapsed
        _inv_elapsed_str="$(ralph_format_elapsed_secs "$elapsed")"
        _run_elapsed_str="$(ralph_format_elapsed_secs "$((now - _plan_start_ts))")"
        echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent still working (invocation ${_inv_elapsed_str}, run ${_run_elapsed_str}).${C_RST}" >&2
      fi

      if [[ -n "$_timeout_elapsed" && $_timeout_elapsed -gt "$RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS" ]]; then
        elapsed="$_timeout_elapsed"
        echo "" >&2
        echo -e "${C_R}${C_BOLD}Invocation stuck: timeout exceeded (${elapsed}s > ${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s).${C_RST}" >&2
        echo -e "${C_R}Terminating agent process (PID $AGENT_PID).${C_RST}" >&2
        ralph_run_plan_log "Invocation timeout exceeded: elapsed=${elapsed}s limit=${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s; killing agent tree (PID $AGENT_PID)"
        ralph_run_plan_agent_teardown
        echo "" >> "$OUTPUT_LOG"
        echo "--- Invocation terminated due to timeout (elapsed ${elapsed}s > ${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s) ---" >> "$OUTPUT_LOG"
        read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
        if ! get_next_todo "$PLAN_PATH" > /dev/null 2>&1; then
          ralph_run_plan_log "all complete (done=$done_count total=$total_count) after timeout kill; exiting clean"
          {
            echo ""
            echo "################################################################################"
            echo "# All TODOs complete ($done_count/$total_count) - $(date '+%Y-%m-%d %H:%M:%S')"
            echo "################################################################################"
          } >> "$OUTPUT_LOG"
          echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done_count/$total_count)${C_RST}." >&2
          rm -f "$(ralph_plan_manual_ack_path)" 2>/dev/null || true
          EXIT_STATUS="complete"
          _ralph_write_plan_usage_summary "$done_count" "$total_count"
          ralph_runtime_overlay_cleanup_if_needed
          exit 0
        fi
        EXIT_STATUS="stuck"
        _ralph_write_plan_usage_summary "$done_count" "$total_count"
        ralph_runtime_overlay_cleanup_if_needed
        exit 4
      fi
    done

    wait "$AGENT_PID" 2>/dev/null || true
    ralph_run_plan_agent_teardown
    # 125 is the runner's own sentinel for "the invocation wrapper never wrote
    # an exit code" (killed mid-flight, wrapper crashed). Track that so the
    # failure report does not present it as a real CLI exit code.
    exit_code=125
    _exit_code_synthetic=1
    if [[ -f "$EXIT_CODE_FILE" ]]; then
      exit_code="$(cat "$EXIT_CODE_FILE")"
      _exit_code_synthetic=0
      rm -f "$EXIT_CODE_FILE"
    fi
    if ! ralph_process_check_abort; then
      exit_code=78
      _exit_code_synthetic=0
    fi
    set -e
    ralph_run_plan_abort_if_kill_switch
    _inv_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _inv_elapsed=$(( $(date +%s) - START_TIME ))
    ralph_run_plan_log "$RALPH_INVOKED_CLI finished (exit=$exit_code elapsed=${_inv_elapsed}s)"
    _inv_effective_runtime="$RUNTIME"
    _inv_effective_model="${SELECTED_MODEL:-}"
    # Bind the CLI session id to this TODO from the supervisor. The invocation
    # wrapper does the same on its way out, but the reaper above tears the
    # wrapper down as soon as EXIT_CODE_FILE appears -- which the wrapper writes
    # one line before it captures -- so that call is racy and can be lost. This
    # one runs with the TODO identity and effective RUNTIME still live, and is
    # idempotent with the wrapper's.
    if declare -F ralph_session_todo_capture_after_invocation >/dev/null 2>&1; then
      ralph_session_todo_capture_after_invocation || true
    fi
    # Everything below restores the routing baseline, which clears
    # RALPH_CURRENT_TODO_* -- but permission classification, the operator pause,
    # and continuation persistence all still belong to this TODO.
    if declare -F ralph_session_todo_identity_freeze >/dev/null 2>&1; then
      ralph_session_todo_identity_freeze || true
    fi
    ralph_run_plan_routing_restore_baseline
    ralph_runtime_overlay_cleanup_if_needed
    GIT_STATUS_AT_END="$(git -C "$WORKSPACE" status --short --untracked-files=all 2>/dev/null || true)"
    _inv_output_segment="$(ralph_current_invocation_output_segment "$OUTPUT_LOG" "$iteration" "$LOG_SIZE_AT_START")"
    _rate_limit_status=""
    if declare -F ralph_detect_rate_limit_status >/dev/null 2>&1; then
      _rate_limit_status="$(ralph_detect_rate_limit_status "$_inv_output_segment" 2>/dev/null || true)"
    fi
    _permission_pause_pending=0
    _permission_block_type="none"
    _proxy_violation_flagged=0
    # Permission denials can surface as explicit runtime output even when the
    # CLI exits 0, so classify the output segment independently of exit code.
    #
    # But when the agent printed an explicit completion sentinel on a clean
    # exit (and left no pending human-input request), the TODO genuinely
    # finished -- a real permission denial would have stopped it short of
    # completion. In that case the segment's prose can still contain
    # permission-shaped vocabulary ("permission denied", "blocked",
    # "rejected") purely as domain output (for example a security or
    # poisoning evaluation summary). Treating that as a permission block
    # would intercept the completion, pause for the operator, and then
    # re-run the same TODO on resume -- looping forever and asking the
    # operator to approve marking the TODO complete. Skip classification
    # when completion is clearly signaled.
    _permission_skip_for_completion=0
    if [[ "$exit_code" -eq 0 ]] && [[ ! -f "$PENDING_HUMAN" ]]; then
      if [[ -f "${USAGE_FILE:-}" ]] && command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("completion_sentinel_seen") else 1)' "${USAGE_FILE}" >/dev/null 2>&1; then
        _permission_skip_for_completion=1
      elif declare -F _ralph_completion_sentinel_seen_in_text >/dev/null 2>&1 \
        && _ralph_completion_sentinel_seen_in_text "$_inv_output_segment"; then
        _permission_skip_for_completion=1
      fi
    fi
    if [[ "$_permission_skip_for_completion" == "1" ]]; then
      ralph_run_plan_log "Skipping permission classification: agent signaled TODO completion on clean exit (line $line_num)"
    fi
    if [[ "$_permission_skip_for_completion" != "1" ]] && declare -F ralph_permission_block_type >/dev/null 2>&1; then
      _permission_block_type="$(ralph_permission_block_type "$_inv_output_segment" "$exit_code" "$_inv_effective_runtime" 2>/dev/null || printf 'none')"
      if [[ "$_permission_block_type" != "none" ]] && declare -F ralph_prepare_permission_pause >/dev/null 2>&1; then
        ralph_prepare_permission_pause \
          "$line_num" \
          "$todo_text" \
          "$PLAN_PATH" \
          "$_inv_effective_runtime" \
          "$_permission_block_type" \
          "$_inv_output_segment" \
          "$(ralph_permission_blocked_command_generic "$_inv_output_segment" 2>/dev/null || true)" \
        "$(ralph_permission_blocked_path "$_inv_output_segment" 2>/dev/null || true)" \
        "$(ralph_permission_blocked_tool "$_inv_output_segment" 2>/dev/null || true)" || true
      _permission_pause_pending=1
      if declare -F ralph_human_pause_for_operator_offline >/dev/null 2>&1; then
        # Proxy denials can happen when MCP's tool boundary is rejected.
        # In non-interactive runs, skip the operator pause so the agent
        # continues with an alternate approach, while still preserving the
        # pause-pending flag so the retry/resume guard does not abort.
        if [[ "${NON_INTERACTIVE_FLAG:-0}" == "1" ]] && [[ "$_inv_output_segment" == *"mcp-proxy"* ]]; then
          ralph_run_plan_log "Skipping operator pause for non-interactive MCP proxy denial"
        else
          RALPH_PERMISSION_RESPONSE_DECISION=""
          export RALPH_PERMISSION_RESPONSE_DECISION
          ralph_human_pause_for_operator_offline || true
          if [[ "${RALPH_PERMISSION_RESPONSE_DECISION:-}" == "deny" ]]; then
            read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
            echo "" >&2
            echo -e "${C_R}${C_BOLD}Permission request was denied by the operator; stopping plan run.${C_RST}" >&2
            echo -e "${C_DIM}Plan: $PLAN_PATH  Line $line_num${C_RST}" >&2
            echo -e "${C_DIM}Re-run the same command to retry; you will be prompted again. Pre-approve with RALPH_PERMISSION_RESPONSE_DECISION=allow.${C_RST}" >&2
            _ralph_write_plan_usage_summary "$done_count" "$total_count"
            ralph_runtime_overlay_cleanup_if_needed
            exit 1
          fi
          if [[ "${RALPH_PERMISSION_RESPONSE_DECISION:-}" == "allow" ]]; then
            ralph_run_plan_log "Permission approved by operator; retrying TODO line $line_num (attempts_on_line reset)"
            attempts_on_line=0
            ralph_wait 1
            continue
          fi
        fi
      fi
    fi
    fi
    _has_verification_metadata=0
    _has_strict_verify_metadata=0
    _agent_verdict="none"
    _agent_verify_reason=""
    if [[ "${RALPH_POST_VERIFY:-1}" != "0" ]]; then
      if _ralph_todo_declares_verification_metadata "$todo_text_for_verification"; then
        _has_verification_metadata=1
      fi
      if [[ -n "${RALPH_VERIFY_AFTER_TODO:-}" || -n "$_PLAN_VERIFY_COMMAND" ]] || _ralph_todo_declares_strict_verify "$todo_text_for_verification"; then
        _has_strict_verify_metadata=1
      fi
      _agent_verdict="$(_ralph_verification_result_in_text "$_inv_output_segment" 2>/dev/null || printf 'none')"
      _agent_verify_reason="$(_ralph_verification_reason_in_text "$_inv_output_segment" 2>/dev/null || true)"
    fi
    # Successful invocations are not rate-limit rejections; substring heuristics
    # can still match source grep output from the agent's own exploration.
    if [[ "$exit_code" -eq 0 ]]; then
      _rate_limit_status=""
    fi

    # Read per-invocation token usage from demux.py output (only when JSON streaming was active).
    _inv_input=0; _inv_output=0; _inv_cache_create=0; _inv_cache_read=0; _inv_max_turn=0; _inv_tool_turns=0
    if [[ -f "$USAGE_FILE" ]]; then
      if command -v python3 &>/dev/null; then
        _inv_usage_json="$(<"$USAGE_FILE")"
        # One interpreter start for all seven fields: python3 costs ~60ms per
        # spawn and this runs on every invocation.
        _inv_fields="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
keys = ('input_tokens', 'output_tokens', 'cache_creation_input_tokens',
        'cache_read_input_tokens', 'max_turn_total_tokens', 'tool_turns',
        'tool_calls_total')
print('\\x1f'.join(str(d.get(k, 0)) for k in keys))
" "$_inv_usage_json" 2>/dev/null || printf '0\x1f0\x1f0\x1f0\x1f0\x1f0\x1f0')"
        IFS=$'\x1f' read -r _inv_input _inv_output _inv_cache_create _inv_cache_read \
          _inv_max_turn _inv_tool_turns _inv_tool_calls_total <<<"$_inv_fields"
        : "${_inv_input:=0}" "${_inv_output:=0}" "${_inv_cache_create:=0}" "${_inv_cache_read:=0}"
        : "${_inv_max_turn:=0}" "${_inv_tool_turns:=0}" "${_inv_tool_calls_total:=0}"
      fi
    fi

    if [[ "$exit_code" -ne 0 ]] && [[ "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" == "reset" ]] && [[ "$_inv_used_resume_session_id" == "1" ]] && [[ "$_reset_retry_done_for_line" -eq 0 ]] && [[ -z "${RESUME_SESSION_ID_OVERRIDE:-}" ]]; then
      if ralph_session_reset_resume_error_detected "$_inv_effective_runtime" "$OUTPUT_LOG"; then
        ralph_run_plan_log "reset strategy detected stale session id ($_inv_resume_session_id) after failed invocation; clearing stored id and retrying once fresh"
        rm -f "$SESSION_ID_FILE" 2>/dev/null || true
        unset RALPH_RUN_PLAN_RESUME_SESSION_ID
        unset RALPH_RUN_PLAN_NEW_SESSION_ID
        unset RALPH_RUN_PLAN_RESUME_BARE
        _reset_retry_done_for_line=1
        ralph_wait 1
        continue
      fi
    fi
    if [[ "$_inv_effective_runtime" == "opencode" ]] && \
       [[ "$exit_code" -eq 0 ]] && \
       [[ "$_inv_used_resume_session_id" == "1" ]] && \
       [[ "$_opencode_empty_resume_retry_done_for_line" -eq 0 ]] && \
       [[ -z "${RESUME_SESSION_ID_OVERRIDE:-}" ]] && \
       [[ "$_inv_input" -eq 0 && "$_inv_output" -eq 0 && "$_inv_cache_create" -eq 0 && "$_inv_cache_read" -eq 0 ]] && \
       ! printf '%s\n' "$_inv_output_segment" | grep -Eq '^[[:space:]]*\{'; then
      ralph_run_plan_log "opencode resumed session produced no JSON events or token usage; clearing stored session id ($_inv_resume_session_id) and retrying fresh once"
      _ralph_append_invocation_usage_history \
        "$RALPH_LOG_DIR/invocation-usage.json" \
        "$iteration" \
        "${_inv_effective_model:-}" \
        "$_inv_effective_runtime" \
        "$_inv_elapsed" \
        "$_inv_input" \
        "$_inv_output" \
        "$_inv_cache_create" \
        "$_inv_cache_read" \
        "0" \
        "0" \
        "$_inv_started_at" \
        "$_inv_ended_at" \
        "${RALPH_PLAN_KEY:-}" \
        "${RALPH_STAGE_ID:-}" \
        "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" \
        "$line_num" \
        "$task_ordinal" \
        "0" \
        "${todo_class:-normal}" \
        "${todo_hash:-}" \
        "0" \
        "0" \
        "${_prompt_bytes:-0}" \
        "${_todo_bytes:-0}" \
        "${_todo_continuation_lines:-0}" \
        "${_split_parent_id:-}" \
        "0" \
        "" \
        "0" \
        "${USAGE_FILE:-}" \
        ""
      rm -f "$SESSION_ID_FILE" 2>/dev/null || true
      unset RALPH_RUN_PLAN_RESUME_SESSION_ID
      unset RALPH_RUN_PLAN_NEW_SESSION_ID
      unset RALPH_RUN_PLAN_RESUME_BARE
      _opencode_empty_resume_retry_done_for_line=1
      ralph_wait 1
      continue
    fi
    if [[ "$_inv_effective_runtime" == "claude" ]] && \
       [[ "$exit_code" -eq 0 ]] && \
       [[ "$_inv_used_resume_session_id" == "1" ]] && \
       [[ "$_claude_empty_resume_retry_done_for_line" -eq 0 ]] && \
       [[ -z "${RESUME_SESSION_ID_OVERRIDE:-}" ]] && \
       [[ "$_inv_input" -eq 0 && "$_inv_output" -eq 0 && "$_inv_cache_create" -eq 0 && "$_inv_cache_read" -eq 0 ]] && \
       [[ "${_inv_tool_turns:-0}" -eq 0 ]]; then
      ralph_run_plan_log "claude resumed session produced no turns or token usage; clearing stored session id ($_inv_resume_session_id) and retrying fresh once"
      rm -f "$SESSION_ID_FILE" 2>/dev/null || true
      unset RALPH_RUN_PLAN_RESUME_SESSION_ID
      unset RALPH_RUN_PLAN_NEW_SESSION_ID
      unset RALPH_RUN_PLAN_RESUME_BARE
      _claude_empty_resume_retry_done_for_line=1
      ralph_wait 1
      continue
    fi
    # Compute per-invocation cache_hit_ratio = cache_read / (input + cache_read + cache_create).
    _inv_cache_hit_ratio=0
    _inv_total_input=$(( _inv_input + _inv_cache_read + _inv_cache_create ))
    if [[ "$_inv_total_input" -gt 0 ]] && command -v python3 &>/dev/null; then
      _inv_cache_hit_ratio="$(python3 -c "print(round(${_inv_cache_read}/${_inv_total_input},4))" 2>/dev/null || echo 0)"
    fi
    _total_input_tokens=$(( _total_input_tokens + _inv_input ))
    _total_output_tokens=$(( _total_output_tokens + _inv_output ))
    _total_cache_creation_tokens=$(( _total_cache_creation_tokens + _inv_cache_create ))
    _total_cache_read_tokens=$(( _total_cache_read_tokens + _inv_cache_read ))
    if [[ "$_inv_max_turn" -gt "$_total_max_turn_tokens" ]]; then
      _total_max_turn_tokens="$_inv_max_turn"
    fi

    _inv_next_after=""
    _inv_next_line=""
    _inv_plan_complete=0
    _inv_todo_completed=0
    if ! _inv_next_after=$(get_next_todo "$PLAN_PATH"); then
      _inv_plan_complete=1
      _inv_todo_completed=1
    else
      _inv_next_line="${_inv_next_after%%|*}"
      if [[ "$_inv_next_line" != "$line_num" ]]; then
        _inv_todo_completed=1
      fi
    fi

    _inv_completion_sentinel=0
    if [[ -f "${USAGE_FILE:-}" ]] && command -v python3 &>/dev/null; then
      _inv_completion_sentinel="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(1 if d.get("completion_sentinel_seen") else 0)' "${USAGE_FILE}" 2>/dev/null || echo 0)"
    fi

    _inv_completion_sentinel_seen=0
    if [[ "$_inv_completion_sentinel" == "1" ]] || _ralph_completion_sentinel_seen_in_text "$_inv_output_segment"; then
      _inv_completion_sentinel_seen=1
    fi
    # Workflow operator-input: refuse checkbox/stage success while outstanding
    # or answered-unconsumed input exists for this attempt (exit 3 / waiting).
    if declare -F ralph_run_plan_gate_workflow_operator_input_after_turn >/dev/null 2>&1; then
      ralph_run_plan_gate_workflow_operator_input_after_turn "$PLAN_PATH" "$plan_format" "$todo_target" "$line_num"
    fi

    if [[ "$exit_code" -eq 0 ]] && [[ "$_inv_todo_completed" == "1" ]] && [[ ! -f "$PENDING_HUMAN" ]]; then
      if declare -F ralph_run_plan_gate_bg_job_before_completion >/dev/null 2>&1; then
        if ! ralph_run_plan_gate_bg_job_before_completion "$PLAN_PATH" "$plan_format" "$todo_target" "$line_num" "$task_ordinal" "$todo_id" "$todo_hash"; then
          _inv_todo_completed=0
          _inv_plan_complete=0
          if declare -F ralph_bg_invocation_try_schedule_continuation >/dev/null 2>&1 \
            && ralph_bg_invocation_try_schedule_continuation; then
            ralph_wait 1
            continue
          fi
          continue
        fi
      fi
      if declare -F plan_pipeline_has_metadata >/dev/null 2>&1 && plan_pipeline_has_metadata "$PLAN_PATH"; then
        if ! ralph_run_plan_pipeline_output_artifacts_verify "$PLAN_PATH" "$todo_target" "$line_num"; then
          if plan_reopen_todo_by_format "$PLAN_PATH" "$plan_format" "$todo_target"; then
            ralph_run_plan_log "output artifact verification failed for line=$line_num; TODO reopened"
          fi
          read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
          _ralph_write_plan_usage_summary "$done_count" "$total_count"
          ralph_runtime_overlay_cleanup_if_needed
          exit 1
        fi
      fi
      if declare -F run_plan_validate_structured_final_output >/dev/null 2>&1; then
        if ! run_plan_validate_structured_final_output "$_inv_output_segment" "$PLAN_PATH" "$todo_target"; then
          if plan_reopen_todo_by_format "$PLAN_PATH" "$plan_format" "$todo_target"; then
            ralph_run_plan_log "structured final-output validation failed for line=$line_num; TODO reopened"
          fi
          read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
          _ralph_write_plan_usage_summary "$done_count" "$total_count"
          ralph_runtime_overlay_cleanup_if_needed
          exit 1
        fi
      fi
    fi

    if [[ "$exit_code" -eq 0 ]] && [[ "$_inv_todo_completed" != "1" ]] && [[ ! -f "$PENDING_HUMAN" ]]; then
      # Unified completion gate. A TODO is claimed done when the agent prints the
      # completion sentinel, OR (for runtimes/plans that emit no sentinel) when a
      # runnable verification command exists to act as the completion signal.
      # Either way we mark first and let the single verification gate below run;
      # that gate reopens the TODO on failure. This keeps behavior identical
      # whether or not the sentinel was emitted (previously the two cases used
      # separate verify-to-complete vs post-verification code paths).
      _claim_complete=0
      if [[ "$_inv_completion_sentinel_seen" == "1" ]]; then
        _claim_complete=1
      elif _ralph_should_verify_to_complete "$todo_text_for_verification"; then
        _claim_complete=1
      fi

      if [[ "$_claim_complete" == "1" ]]; then
        if [[ -n "${RALPH_GRAPH_NAMESPACE:-}" && -n "${RALPH_GRAPH_RUN_ID:-}" && -n "${RALPH_GRAPH_NODE_ID:-}" && -n "${RALPH_GRAPH_ATTEMPT_ID:-}" ]]; then
          _delegation_gate_dir="$RALPH_PLAN_WORKSPACE_ROOT/artifacts/${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-plan}}/delegations/${RALPH_GRAPH_NODE_ID}/${RALPH_GRAPH_ATTEMPT_ID}"
          if graph_delegation_completion_gate "$WORKSPACE" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" "$RALPH_GRAPH_NODE_ID" "$RALPH_GRAPH_ATTEMPT_ID" "$_delegation_gate_dir"; then
            _delegation_gate_rc=0
          else
            _delegation_gate_rc=$?
          fi
          case "$_delegation_gate_rc" in
            0)
              [[ -z "${GRAPH_DELEGATION_GATE_INPUT_ARTIFACTS:-}" ]] || export RALPH_DELEGATION_INPUT_ARTIFACTS="$GRAPH_DELEGATION_GATE_INPUT_ARTIFACTS"
              [[ -z "${GRAPH_DELEGATION_GATE_INTEGRATION_INPUTS:-}" ]] || export RALPH_DELEGATION_INTEGRATION_INPUTS="$GRAPH_DELEGATION_GATE_INTEGRATION_INPUTS"
              ;;
            10|11|12)
              _inv_todo_completed=0; _inv_plan_complete=0
              POST_VERIFICATION_FAILURE_REASON="delegation_completion_gate"
              POST_VERIFICATION_FAILURE_SUMMARY="${GRAPH_DELEGATION_GATE_EVIDENCE:-delegated child has not reached a completion-safe state}"
              if [[ "$_delegation_gate_rc" == "12" ]]; then
                ralph_write_human_action_file "Delegated child retry budget exhausted for graph node ${RALPH_GRAPH_NODE_ID}. ${POST_VERIFICATION_FAILURE_SUMMARY}" || true
                ralph_run_plan_log "delegation completion gate escalated to pending human for line=$line_num"
              else
                ralph_run_plan_log "delegation completion gate blocked line=$line_num: ${POST_VERIFICATION_FAILURE_SUMMARY}"
              fi
              continue
              ;;
            *) ralph_run_plan_log "ERROR: delegation completion gate failed rc=$_delegation_gate_rc"; ralph_runtime_overlay_cleanup_if_needed; exit 1 ;;
          esac
        fi
        if declare -F plan_pipeline_has_metadata >/dev/null 2>&1 && plan_pipeline_has_metadata "$PLAN_PATH"; then
          if ! ralph_run_plan_pipeline_output_artifacts_verify "$PLAN_PATH" "$todo_target" "$line_num"; then
            read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
            _ralph_write_plan_usage_summary "$done_count" "$total_count"
            ralph_runtime_overlay_cleanup_if_needed
            exit 1
          fi
        fi
        if declare -F run_plan_validate_structured_final_output >/dev/null 2>&1; then
          if ! run_plan_validate_structured_final_output "$_inv_output_segment" "$PLAN_PATH" "$todo_target"; then
            read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
            _ralph_write_plan_usage_summary "$done_count" "$total_count"
            ralph_runtime_overlay_cleanup_if_needed
            exit 1
          fi
        fi
        if ! ralph_graph_write_scope_verify_todo "${todo_id:-todo-$line_num}"; then
          read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
          _ralph_write_plan_usage_summary "$done_count" "$total_count"
          ralph_runtime_overlay_cleanup_if_needed
          exit 1
        fi
        if declare -F ralph_run_plan_gate_bg_job_before_completion >/dev/null 2>&1; then
          if ! ralph_run_plan_gate_bg_job_before_completion "$PLAN_PATH" "$plan_format" "$todo_target" "$line_num" "$task_ordinal" "$todo_id" "$todo_hash"; then
            _inv_todo_completed=0
            _inv_plan_complete=0
            if declare -F ralph_bg_invocation_try_schedule_continuation >/dev/null 2>&1 \
              && ralph_bg_invocation_try_schedule_continuation; then
              ralph_wait 1
              continue
            fi
            continue
          fi
        fi
        if run_plan_mark_and_confirm "$PLAN_PATH" "$plan_format" "$todo_target" "$line_num"; then
          ralph_run_plan_log "runner marked TODO complete for line=$line_num"
          if declare -F ralph_session_todo_retire_at_boundary >/dev/null 2>&1; then
            ralph_session_todo_retire_at_boundary || true
          fi
          _inv_todo_completed=1
          if ! _inv_next_after=$(get_next_todo "$PLAN_PATH"); then
            _inv_plan_complete=1
          else
            _inv_next_line="${_inv_next_after%%|*}"
          fi
        else
          _runner_mark_status=$?
          if [[ "$_runner_mark_status" -eq 5 ]]; then
            ralph_run_plan_log "ERROR: TODO id=${todo_id:-$todo_target} line=$line_num reported marked but is still open (plan integrity)"
            read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
            _ralph_write_plan_usage_summary "$done_count" "$total_count"
            ralph_runtime_overlay_cleanup_if_needed
            exit 1
          fi
          ralph_run_plan_log "runner could not mark TODO for line=$line_num"
        fi
      fi
    fi

    _validation_failed=0
    if [[ "$_inv_todo_completed" == "1" ]]; then
      if [[ "$_inv_completion_sentinel_seen" == "1" ]]; then
        ralph_run_plan_log "completion marker observed for line $line_num"
      else
        ralph_run_plan_log "completion marker missing for line $line_num (non-blocking)"
      fi
    fi
    : "${_prompt_bytes:=0}"
    : "${_todo_bytes:=0}"
    : "${_todo_continuation_lines:=0}"
    : "${_split_parent_id:=}"
    : "${_rate_limit_status:=}"
    : "${_inv_tool_turns:=0}"
    : "${_inv_tool_calls_total:=0}"
    : "${todo_class:=normal}"
    : "${todo_hash:=}"

    # Write consolidated per-invocation usage history JSON.
    _inv_usage_file="$RALPH_LOG_DIR/invocation-usage.json"
    _overlay_summary_for_usage="$(_ralph_runtime_overlay_summary_path_for_usage)"
    if [[ -n "$_overlay_summary_for_usage" ]]; then
      _overlay_summary_snapshot="$(_ralph_runtime_overlay_summary_snapshot_for_usage "$_overlay_summary_for_usage" "$iteration" "$_inv_effective_runtime" "$START_TIME")"
      if [[ -n "$_overlay_summary_snapshot" ]]; then
        _overlay_summary_for_usage="$_overlay_summary_snapshot"
      fi
    fi
    if [[ -f "${USAGE_FILE:-}" ]]; then
      if declare -F ralph_run_plan_log_tool_access_breakdown >/dev/null 2>&1; then
        if ! ralph_run_plan_log_tool_access_breakdown "$USAGE_FILE"; then
          exit_code=1
          _proxy_violation_flagged=1
          _inv_todo_completed=0
          _inv_plan_complete=0
          ralph_run_plan_log "ERROR: Tool access policy violation (RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=1)"
        fi
      fi
    fi
    _ralph_append_invocation_usage_history \
      "$_inv_usage_file" \
      "$iteration" \
      "${_inv_effective_model:-}" \
      "$_inv_effective_runtime" \
      "$_inv_elapsed" \
      "$_inv_input" \
      "$_inv_output" \
      "$_inv_cache_create" \
      "$_inv_cache_read" \
      "$_inv_max_turn" \
      "$_inv_cache_hit_ratio" \
      "$_inv_started_at" \
      "$_inv_ended_at" \
      "${RALPH_PLAN_KEY:-}" \
      "${RALPH_STAGE_ID:-}" \
      "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" \
      "$line_num" \
      "$task_ordinal" \
      "$_inv_todo_completed" \
      "$todo_class" \
      "$todo_hash" \
      "${_validation_failed:-0}" \
      "${RALPH_PLAN_ALLOW_UNVERIFIED_COMPLETION:-0}" \
      "$_prompt_bytes" \
      "$_todo_bytes" \
      "$_todo_continuation_lines" \
      "$_split_parent_id" \
      "0" \
      "$_rate_limit_status" \
      "${_inv_tool_turns:-0}" \
      "${USAGE_FILE:-}" \
      "$_overlay_summary_for_usage"
    _inv_usage_line="invocation $iteration usage: runtime=${_inv_effective_runtime} model=${_inv_effective_model} elapsed=${_inv_elapsed}s input=${_inv_input} output=${_inv_output} cache_create=${_inv_cache_create} cache_read=${_inv_cache_read} max_turn=${_inv_max_turn} cache_hit_ratio=${_inv_cache_hit_ratio} tool_calls=${_inv_tool_calls_total:-0} prompt_bytes=${_prompt_bytes} todo_bytes=${_todo_bytes} todo_continuation_lines=${_todo_continuation_lines} rate_limit_status=${_rate_limit_status:-none}"
    _inv_cache_hit_pct="$(printf '%.0f' "$(echo "$_inv_cache_hit_ratio * 100" | bc 2>/dev/null || echo 0)")"
    _inv_summary_common_args=(
      --elapsed "${_inv_elapsed:-0}"
      "$iteration"
      "$_inv_effective_runtime"
      "${_inv_effective_model:-}"
      "$_inv_input"
      "$_inv_output"
      "${_inv_tool_calls_total:-0}"
      "$_inv_cache_create"
      "$_inv_cache_read"
      "$_inv_cache_hit_pct"
      "$_prompt_bytes"
      "$_todo_bytes"
      "$_todo_continuation_lines"
      "${_rate_limit_status:-none}"
      "${_inv_usage_json:-}"
      "$task_ordinal"
      "$line_num"
      "$done_count"
      "$total_count"
    )
    _inv_usage_block_log="$(
      _inv_elapsed="${_inv_elapsed:-0}" \
        PYTHONPATH="$SCRIPT_DIR/python" \
        python3 "$SCRIPT_DIR/python/ralph-invocation-summary-text.py" \
        --ascii-only \
        "${_inv_summary_common_args[@]}" 2>/dev/null || true
    )"
    _inv_summary_terminal_color_args=()
    if [[ -n "${NO_COLOR:-}" || "${RALPH_PLAN_NO_COLOR:-0}" == "1" ]]; then
      _inv_summary_terminal_color_args+=(--no-color)
    else
      _inv_summary_terminal_color_args+=(--color)
    fi
    _inv_usage_block="$(
      _inv_elapsed="${_inv_elapsed:-0}" RALPH_INVOCATION_SUMMARY_COLOR=1 \
        PYTHONPATH="$SCRIPT_DIR/python" \
        python3 "$SCRIPT_DIR/python/ralph-invocation-summary-text.py" \
        "${_inv_summary_terminal_color_args[@]}" \
        "${_inv_summary_common_args[@]}" 2>/dev/null || true
    )"
    ralph_run_plan_log "$_inv_usage_line"
    printf '%s\n' "$_inv_usage_block_log" >> "$OUTPUT_LOG"
    if [[ -f "${USAGE_FILE:-}" ]]; then
      rm -f "$USAGE_FILE"
    fi

    if [[ "$_inv_effective_runtime" == "opencode" ]]; then
      if ! ralph_opencode_cache_warning_maybe_emit \
        "$_inv_usage_file" \
        "${_inv_effective_model:-}" \
        "${RALPH_OPENCODE_CONFIG_SOURCE_DESC:-unknown}" \
        "${RALPH_OPENCODE_AMBIENT_CACHE_SETTINGS:-0}" \
        "${RALPH_OPENCODE_FINAL_CACHE_SETTINGS:-0}"; then
        read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
        ralph_run_plan_log "opencode cache warning stop action triggered; stopping before next invocation"
        echo "" >&2
        echo -e "${C_R}${C_BOLD}OpenCode cache warning stop action triggered; stopping before next invocation.${C_RST}" >&2
        echo -e "${C_DIM}Plan: $PLAN_PATH  Line $line_num${C_RST}" >&2
        _ralph_write_plan_usage_summary "$done_count" "$total_count"
        ralph_runtime_overlay_cleanup_if_needed
        exit 4
      fi
    fi

    if [[ -n "$_rate_limit_status" && "$exit_code" -ne 0 ]]; then
      ralph_run_plan_log "hard rate-limit rejection detected status=$_rate_limit_status; stopping without retry"
      echo "" >&2
      echo -e "${C_R}${C_BOLD}Runtime rejected the request (${_rate_limit_status}); stopping without retrying this TODO.${C_RST}" >&2
      echo -e "${C_DIM}Plan: $PLAN_PATH  Line $line_num${C_RST}" >&2
      _ralph_write_plan_usage_summary "$done_count" "$total_count"
      ralph_runtime_overlay_cleanup_if_needed
      exit 4
    fi

    if [[ -n "${_inv_usage_block:-}" ]]; then
      printf '%s\n' "$_inv_usage_block" >&2
    fi

    # Bump session turn counter and maybe rotate to cap cache growth
    ralph_session_bump_turn_counter > /dev/null
    ralph_session_maybe_rotate "${RALPH_PLAN_SESSION_MAX_TURNS:-0}"

    echo "" >>"$OUTPUT_LOG"
    echo "--- End invocation $iteration ---" >>"$OUTPUT_LOG"

    # Report nonzero CLI exits before completion reporting. Only label the
    # stop a proxy policy violation when one was actually recorded this
    # invocation; a generic runtime failure (crash, MCP transport death,
    # auth problem) must be reported as what it is, with enough context in
    # the terminal to explain why the runner stopped.
    if [[ "$exit_code" -ne 0 ]] && [[ "${_permission_pause_pending:-0}" != "1" ]]; then
      read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
      _failure_headline="Runtime CLI failed; stopping plan run."
      _failure_log_marker="Runtime CLI failure"
      _failure_detail=""
      if [[ "${_proxy_violation_flagged:-0}" == "1" ]]; then
        _failure_headline="Strict proxy policy violation detected; stopping plan run."
        _failure_log_marker="Strict proxy policy violation detected"
        _failure_detail="The agent used native tools while RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=1."
      else
        _failure_class="$(ralph_run_plan_classify_cli_failure "$_inv_output_segment" 2>/dev/null || true)"
        case "$_failure_class" in
          mcp_transport)
            _failure_headline="Ralph MCP transport failed during the invocation; stopping plan run."
            _failure_log_marker="MCP transport failure"
            _failure_detail="The runtime lost the ralph MCP server mid-session (request timeout or connection closed), so proxy tools became unavailable to the agent."
            ;;
          auth)
            _failure_headline="Runtime CLI reported an authentication problem; stopping plan run."
            _failure_log_marker="Runtime authentication failure"
            _failure_detail="Log in to the runtime CLI and re-run the plan."
            ;;
        esac
      fi
      echo "" >&2
      echo -e "${C_R}${C_BOLD}${_failure_headline}${C_RST}" >&2
      if [[ "${_exit_code_synthetic:-0}" == "1" ]]; then
        echo -e "${C_DIM}Exit code: unknown (invocation wrapper never reported one; runner sentinel $exit_code)${C_RST}" >&2
      else
        echo -e "${C_DIM}Exit code: $exit_code (runtime=$_inv_effective_runtime)${C_RST}" >&2
      fi
      if [[ -n "$_failure_detail" ]]; then
        echo -e "${C_DIM}${_failure_detail}${C_RST}" >&2
      fi
      echo -e "${C_DIM}Plan: $PLAN_PATH  Line $line_num${C_RST}" >&2
      ralph_run_plan_print_failure_tail "$_inv_output_segment" 5
      _ralph_write_plan_usage_summary "$done_count" "$total_count"
      echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}" >&2
      ralph_run_plan_log "invocation failed: marker=${_failure_log_marker} exit=$exit_code synthetic=${_exit_code_synthetic:-0} runtime=$_inv_effective_runtime line=$line_num"
      {
        echo ""
        echo "################################################################################"
        echo "# ${_failure_log_marker} (exit=$exit_code) - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "################################################################################"
      } >>"$OUTPUT_LOG"
      if [[ -n "${GIT_STATUS_AT_END:-}" ]]; then
        ralph_run_plan_log "${_failure_log_marker} - git status snapshot:"
        while IFS= read -r git_line; do
          ralph_run_plan_log "  $git_line"
        done <<< "$GIT_STATUS_AT_END"
      fi
      ralph_runtime_overlay_cleanup_if_needed
      exit "$exit_code"
    fi

    next_after="$_inv_next_after"
    next_line="$_inv_next_line"

    if [[ "$_inv_todo_completed" == "1" ]]; then
      if [[ -n "${next_line:-}" && "$next_line" != "$line_num" ]]; then
        ralph_run_plan_log "TODO line $line_num completed; next open TODO is line $next_line"
      else
        ralph_run_plan_log "TODO line $line_num completed"
      fi

      # Unified verification gate:
      #  - Agent VERIFICATION STATUS / VERIFICATION_RESULT: PASS is accepted by
      #    default and skips any
      #    runner fallback, unless RALPH_VERIFY_TRUST_AGENT_PASS=0 and a strict
      #    runner command exists.
      #  - Agent VERIFICATION STATUS / VERIFICATION_RESULT: FAIL reopens
      #    immediately with the failure
      #    context; the runner does not re-run verification first.
      #  - Agent VERIFICATION STATUS / VERIFICATION_RESULT: SKIPPED means the
      #    TODO does not need a verification rerun and should continue.
      #  - Only when the agent omitted a verdict does the runner fall back to a
      #    strict verify command (plan-level verify, RALPH_VERIFY_AFTER_TODO, or
      #    TODO Verify: metadata). Verification: prose is never executed as shell.
      if [[ "${RALPH_POST_VERIFY:-1}" != "0" ]]; then
        _verify_tracking_file="$RALPH_LOG_DIR/post-verification-tracking.txt"
        _need_agent_verify=0
        _skip_runner_post_verify=0

        if [[ "$_has_verification_metadata" == "1" && "$_agent_verdict" == "pass" && "${RALPH_VERIFY_TRUST_AGENT_PASS:-1}" != "0" ]]; then
          ralph_run_plan_log "agent verification PASS for line $line_num; skipping runner fallback"
          POST_VERIFICATION_FAILURE_SUMMARY=""
          POST_VERIFICATION_FAILURE_REASON=""
          POST_VERIFICATION_FAILURE_ARTIFACT=""
          RALPH_VERIFY_REQUEST_MSG=""
          _skip_runner_post_verify=1
        elif [[ "$_agent_verdict" == "fail" ]]; then
          POST_VERIFICATION_FAILURE_REASON="agent_failed_verification"
          POST_VERIFICATION_FAILURE_SUMMARY="${_agent_verify_reason:-agent-reported verification failure}"
          POST_VERIFICATION_FAILURE_ARTIFACT=""
          ralph_run_plan_continuation_summary_record_error "$line_num" "${POST_VERIFICATION_FAILURE_SUMMARY}" "agent_verification"
          if [[ "$_has_verification_metadata" == "1" ]]; then
            ralph_run_plan_log "agent verification FAIL for line $line_num; reopening TODO"
          else
            ralph_run_plan_log "agent verification FAIL for line $line_num without verification metadata; reopening TODO"
          fi
          if plan_reopen_todo_by_format "$PLAN_PATH" "$plan_format" "$todo_target"; then
            _inv_todo_completed=0
            _inv_plan_complete=0
            attempts_on_line=$((attempts_on_line + 1))
            if [[ $attempts_on_line -ge $GUTTER_ITERATIONS ]]; then
              ralph_run_plan_log "GUTTER: line $line_num reopened by agent verification failure but retry budget exhausted (attempts_on_line=$attempts_on_line >= limit=$GUTTER_ITERATIONS); stopping"
              read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
              _ralph_write_plan_usage_summary "$done_count" "$total_count"
              ralph_runtime_overlay_cleanup_if_needed
              exit 1
            fi
            _post_verify_reopen_retry_active=1
            echo "" >&2
            echo -e "${C_Y}${C_BOLD}Agent-reported verification failed for TODO line $line_num${C_RST}" >&2
            echo -e "${C_DIM}TODO reopened; retry budget preserved (attempt $attempts_on_line/$GUTTER_ITERATIONS)${C_RST}" >&2
            continue
          fi
        elif [[ "$_has_verification_metadata" == "1" && "$_agent_verdict" == "skip" ]]; then
          ralph_run_plan_log "agent verification SKIPPED for line $line_num; continuing without runner fallback"
          POST_VERIFICATION_FAILURE_SUMMARY=""
          POST_VERIFICATION_FAILURE_REASON=""
          POST_VERIFICATION_FAILURE_ARTIFACT=""
          _skip_runner_post_verify=1
        elif [[ "$_has_verification_metadata" == "1" && "$_agent_verdict" == "pass" ]]; then
          ralph_run_plan_log "agent verification PASS for line $line_num but RALPH_VERIFY_TRUST_AGENT_PASS=0; evaluating strict runner fallback"
        fi

        if [[ "$_skip_runner_post_verify" != "1" ]] && _ralph_should_run_post_verification "$todo_text_for_verification" "$_PLAN_VERIFY_COMMAND"; then
          _verify_raw="$(_ralph_run_post_verification "$todo_text_for_verification" "$line_num" "$WORKSPACE" "${RALPH_PLAN_KEY:-}" "${RALPH_ARTIFACT_NS:-}" "$_verify_tracking_file" "$_PLAN_VERIFY_COMMAND")"
          IFS=$'\n' read -r _verify_result _verify_summary _verify_artifact <<< "$_verify_raw"
          _verify_summary="${_verify_summary:-}"
          _verify_artifact="${_verify_artifact:-}"
          if [[ "$_verify_result" == "failed" ]]; then
            POST_VERIFICATION_FAILURE_REASON="strict_verify_command_failed"
            POST_VERIFICATION_FAILURE_SUMMARY="${_verify_summary:-}"
            POST_VERIFICATION_FAILURE_ARTIFACT="${_verify_artifact:-}"
            ralph_run_plan_continuation_summary_record_error "$line_num" "${POST_VERIFICATION_FAILURE_SUMMARY}" "strict_verify"
            ralph_run_plan_log "post-verification failed for line $line_num; unmarking TODO"
            if plan_reopen_todo_by_format "$PLAN_PATH" "$plan_format" "$todo_target"; then
              _inv_todo_completed=0
              _inv_plan_complete=0
              # Count this completed-but-verification-failed invocation. This path
              # `continue`s the inner retry loop and never reaches the agent-incomplete
              # counter below, so without this increment attempts_on_line stays 0 and the
              # gutter budget never bounds a repeatedly failing post-verification.
              attempts_on_line=$((attempts_on_line + 1))
              # Check if retry budget is exhausted BEFORE another agent invocation.
              # The current attempt count already reflects completed invocations; once it
              # equals GUTTER_ITERATIONS the limit is reached and the runner must stop.
              if [[ $attempts_on_line -ge $GUTTER_ITERATIONS ]]; then
                ralph_run_plan_log "GUTTER: line $line_num reopened by post-verification but retry budget exhausted (attempts_on_line=$attempts_on_line >= limit=$GUTTER_ITERATIONS); stopping"
                _gutter_help_msg="Plan runner stopped (gutter): post-verification reopened this TODO but the retry budget was exhausted after $attempts_on_line attempts (limit is $GUTTER_ITERATIONS). Unblock by fixing the task, editing the plan line, or raising the limit (CURSOR_PLAN_GUTTER_ITER / CLAUDE_PLAN_GUTTER_ITER / CODEX_PLAN_GUTTER_ITER or --max-iterations). Verification failure: ${POST_VERIFICATION_FAILURE_SUMMARY:-(no summary)}. To ask you a question, the agent should write a structured human-request record to: $PENDING_ABS"
                if ralph_should_persist_human_files; then
                  ralph_write_human_action_file "$_gutter_help_msg"
                fi
                echo "" >&2
                echo -e "${C_R}${C_BOLD}Post-verification failed and retry budget exhausted for TODO line $line_num (attempt $attempts_on_line/$GUTTER_ITERATIONS).${C_RST}" >&2
                echo -e "  Plan: $PLAN_PATH  Line $line_num: $todo_text" >&2
                echo -e "${C_DIM}Verification failure: ${POST_VERIFICATION_FAILURE_SUMMARY:-(no summary)}${C_RST}" >&2
                if [[ -n "${POST_VERIFICATION_FAILURE_ARTIFACT:-}" ]]; then
                  echo -e "${C_DIM}Failure artifact: $POST_VERIFICATION_FAILURE_ARTIFACT${C_RST}" >&2
                fi
                echo -e "${C_DIM}Human help needed: address the verification failure or raise the limit, then re-run.${C_RST}" >&2
                read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
                _ralph_write_plan_usage_summary "$done_count" "$total_count"
                ralph_runtime_overlay_cleanup_if_needed
                exit 1
              fi
              _post_verify_reopen_retry_active=1
              ralph_run_plan_log "TODO line $line_num reopened by post-verification; preserving attempts_on_line=$attempts_on_line"
              if declare -F ralph_post_verify_repair_persist >/dev/null 2>&1; then
                ralph_post_verify_repair_persist \
                  "${POST_VERIFICATION_FAILURE_REASON:-strict_verify_command_failed}" \
                  "${POST_VERIFICATION_FAILURE_SUMMARY:-}" \
                  "${POST_VERIFICATION_FAILURE_ARTIFACT:-}" \
                  "${POST_VERIFICATION_FAILURE_COMMAND:-}" \
                  "$line_num" >/dev/null \
                  || ralph_run_plan_log "WARN: post-verification repair continuation not persisted"
              fi
              echo "" >&2
              echo -e "${C_Y}${C_BOLD}Post-verification failed for TODO line $line_num${C_RST}" >&2
              echo -e "${C_DIM}TODO reopened; retry budget preserved (attempt $attempts_on_line/$GUTTER_ITERATIONS); next retry will preserve prior context${C_RST}" >&2
              continue
            fi
          elif [[ "$_verify_result" == "invalid" ]]; then
            POST_VERIFICATION_FAILURE_REASON="strict_verify_command_invalid"
            POST_VERIFICATION_FAILURE_SUMMARY="${_verify_summary:-strict_verify_command_invalid}"
            POST_VERIFICATION_FAILURE_ARTIFACT=""
            _need_agent_verify=1
          elif [[ "$_verify_result" == "passed" ]]; then
            POST_VERIFICATION_FAILURE_SUMMARY=""
            POST_VERIFICATION_FAILURE_REASON=""
            POST_VERIFICATION_FAILURE_ARTIFACT=""
          else
            POST_VERIFICATION_FAILURE_SUMMARY=""
            POST_VERIFICATION_FAILURE_REASON=""
            POST_VERIFICATION_FAILURE_ARTIFACT=""
          fi
        elif [[ "$_has_verification_metadata" == "1" && "$_agent_verdict" == "none" && "$_inv_completion_sentinel_seen" == "1" ]]; then
          # Verification metadata declared but no agent verdict and no runnable
          # post-verification command to execute automatically; route to the
          # agent-verification loop.
          _need_agent_verify=1
        elif [[ "$_has_verification_metadata" == "1" && "$_has_strict_verify_metadata" == "1" ]]; then
          _need_agent_verify=1
        fi

        # Pipeline/orchestration plans verify through output artifacts and
        # loopback gates, not prose; do not insert a prose agent-verify round there.
        if [[ "$_need_agent_verify" == "1" ]] && declare -F plan_pipeline_has_metadata >/dev/null 2>&1 && plan_pipeline_has_metadata "$PLAN_PATH"; then
          _need_agent_verify=0
        fi

        if [[ "$_need_agent_verify" == "1" ]]; then
          _verify_attempt_file="$RALPH_LOG_DIR/agent-verify-attempts-${todo_hash}.count"
          if [[ "$_agent_verdict" == "pass" ]]; then
            ralph_run_plan_log "agent verification PASS for line $line_num"
            rm -f "$_verify_attempt_file" 2>/dev/null || true
            POST_VERIFICATION_FAILURE_SUMMARY=""
            POST_VERIFICATION_FAILURE_REASON=""
            POST_VERIFICATION_FAILURE_ARTIFACT=""
            RALPH_VERIFY_REQUEST_MSG=""
          else
            # Bound the prove-it loop: cap agent-verification rounds per TODO at
            # the gutter limit so an agent that never reports PASS cannot retry
            # up to MAX_ITERATIONS. Counter is keyed by TODO hash and cleared on PASS.
            _verify_attempts=0
            [[ -f "$_verify_attempt_file" ]] && _verify_attempts="$(cat "$_verify_attempt_file" 2>/dev/null || printf '0')"
            _verify_attempts=$((_verify_attempts + 1))
            printf '%s' "$_verify_attempts" > "$_verify_attempt_file"
            if (( _verify_attempts > GUTTER_ITERATIONS )); then
              ralph_run_plan_log "agent verification not confirmed for line $line_num after $_verify_attempts attempts (limit=$GUTTER_ITERATIONS); stopping"
              plan_reopen_todo_by_format "$PLAN_PATH" "$plan_format" "$todo_target" >/dev/null 2>&1 || true
              echo "" >&2
              echo -e "${C_R}${C_BOLD}Agent did not confirm verification for TODO line $line_num after $_verify_attempts attempts (limit $GUTTER_ITERATIONS).${C_RST}" >&2
              echo -e "${C_DIM}The TODO is reopened. Fix the work or make the verification step a runnable command, then re-run.${C_RST}" >&2
              read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
              _ralph_write_plan_usage_summary "$done_count" "$total_count"
              ralph_runtime_overlay_cleanup_if_needed
              exit 1
            fi
            _next_verify_attempt=$((_verify_attempts + 1))
            if [[ "$_agent_verdict" == "fail" ]]; then
              ralph_run_plan_log "agent verification FAIL for line $line_num; reopening TODO (next attempt $_next_verify_attempt of $GUTTER_ITERATIONS)"
              POST_VERIFICATION_FAILURE_REASON="agent_failed_verification"
              POST_VERIFICATION_FAILURE_SUMMARY="${_agent_verify_reason:-agent-reported verification failure}"
              RALPH_VERIFY_REQUEST_MSG="This is verification attempt $_next_verify_attempt of $GUTTER_ITERATIONS for this TODO; the previous $_verify_attempts attempt(s) reported FAILURE. You must fix the underlying issue now so verification passes -- do not just re-report the same failure. Diagnose and resolve the cause, then re-run every verification step listed for this TODO. End with a line \`VERIFICATION STATUS: PASS\` or \`VERIFICATION_RESULT: PASS\` if all steps pass (also print the same pass line if there were no steps or nothing required checking), or \`VERIFICATION STATUS: FAIL: <reason>\` or \`VERIFICATION_RESULT: FAIL: <reason>\` if any fail, followed by \`AGENT_INVOCATION_COMPLETE\`. Always print one verification verdict line; omitting it reopens this TODO."
            elif [[ "$_has_strict_verify_metadata" == "1" ]]; then
              ralph_run_plan_log "strict verify command unavailable for line $line_num; requesting agent verification verdict"
              POST_VERIFICATION_FAILURE_REASON="${POST_VERIFICATION_FAILURE_REASON:-strict_verify_command_invalid}"
              POST_VERIFICATION_FAILURE_SUMMARY="${POST_VERIFICATION_FAILURE_SUMMARY:-strict_verify_command_invalid: declared verify command could not run}"
              RALPH_VERIFY_REQUEST_MSG="The declared strict \`verify:\` command could not be used automatically. Run each verification step listed for this TODO yourself now, then end with \`VERIFICATION STATUS: PASS\` or \`VERIFICATION_RESULT: PASS\` if every step passes (also print the same pass line if there were no steps or nothing required checking), or \`VERIFICATION STATUS: FAIL: <reason>\` or \`VERIFICATION_RESULT: FAIL: <reason>\` if any fail, followed by \`AGENT_INVOCATION_COMPLETE\`. Always print one verification verdict line; omitting it reopens this TODO."
            else
              ralph_run_plan_log "verification verdict missing for line $line_num; reopening TODO"
              POST_VERIFICATION_FAILURE_REASON="missing_verification_verdict"
              POST_VERIFICATION_FAILURE_SUMMARY="missing_verification_verdict: this TODO declared verification metadata but the agent omitted VERIFICATION STATUS: PASS|FAIL or VERIFICATION_RESULT: PASS|FAIL"
              RALPH_VERIFY_REQUEST_MSG="This TODO declared verification metadata, but the previous attempt omitted \`VERIFICATION STATUS: PASS|FAIL\` or \`VERIFICATION_RESULT: PASS|FAIL\`. Re-run every verification step listed for this TODO yourself now. End with a line \`VERIFICATION STATUS: PASS\` or \`VERIFICATION_RESULT: PASS\` if every step passes (also print the same pass line if there were no steps or nothing required checking), or \`VERIFICATION STATUS: FAIL: <reason>\` or \`VERIFICATION_RESULT: FAIL: <reason>\` if any fail, followed by \`AGENT_INVOCATION_COMPLETE\`. Always print one verification verdict line; omitting it reopens this TODO."
            fi
            if plan_reopen_todo_by_format "$PLAN_PATH" "$plan_format" "$todo_target"; then
              _inv_todo_completed=0
              _inv_plan_complete=0
              echo "" >&2
              echo -e "${C_Y}${C_BOLD}Verification required for TODO line $line_num (attempt $_next_verify_attempt of $GUTTER_ITERATIONS)${C_RST}" >&2
              echo -e "${C_DIM}Asked agent to run verification and report PASS/FAIL; will retry${C_RST}" >&2
            fi
          fi
        fi
      fi

      # Check for loopback after successful TODO completion (pipeline orchestration only)
      _loopback_result=0
      if declare -F ralph_run_plan_loopback_check_and_handle >/dev/null 2>&1 && plan_format_is_yaml "$plan_format"; then
        if ralph_run_plan_loopback_check_and_handle "$PLAN_PATH" "$plan_format" "$todo_target" "$line_num"; then
          _loopback_result=0
        else
          _loopback_result=$?
        fi
        if [[ $_loopback_result -eq 2 ]]; then
          ralph_run_plan_log "loopback reopened TODOs; restarting from first reopened"
          rm -f "$(ralph_plan_manual_ack_path)" 2>/dev/null || true
          rm -f "$PENDING_HUMAN"
          continue 2
        elif [[ $_loopback_result -ne 0 ]]; then
          read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
          _ralph_write_plan_usage_summary "$done_count" "$total_count"
          ralph_runtime_overlay_cleanup_if_needed
          exit 1
        fi
      fi

      if [[ "$_inv_plan_complete" == "1" ]]; then
        read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
        ralph_run_plan_log "all complete (done=$done_count total=$total_count)"
        rm -f "$(ralph_plan_manual_ack_path)" 2>/dev/null || true
        {
          echo ""
          echo "################################################################################"
          echo "# All TODOs complete ($done_count/$total_count) - $(date '+%Y-%m-%d %H:%M:%S')"
          echo "################################################################################"
        } >>"$OUTPUT_LOG"
        echo ""
        echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done_count/$total_count)${C_RST}."
        _ralph_write_plan_usage_summary "$done_count" "$total_count"
        echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
        EXIT_STATUS="complete"
        exit 0
      fi

      _cont_completion_summary=""
      if [[ -n "${_inv_output_segment:-}" ]] && command -v python3 >/dev/null 2>&1; then
        _cont_completion_summary="$(PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
          python3 "$(ralph_run_plan_continuation_summary_py)" extract-summary <<<"$_inv_output_segment" 2>/dev/null || true)"
      fi
      _cont_verify_status="pass"
      if [[ "$_agent_verdict" == "skip" ]]; then
        _cont_verify_status="skip"
      elif [[ "$_agent_verdict" == "fail" ]]; then
        _cont_verify_status="fail"
      fi
      _cont_next_line=0
      _cont_next_ordinal=0
      _cont_next_id=""
      _cont_next_text=""
      if [[ -n "${next_after:-}" ]]; then
        _cont_next_line="${next_after%%|*}"
        _cont_next_target="$(printf '%s\n' "$next_after" | cut -d'|' -f2)"
        _cont_next_text="$(printf '%s\n' "$next_after" | cut -d'|' -f3-)"
        _cont_next_ordinal="$(plan_todo_ordinal_for_next "$PLAN_PATH" "$plan_format" "$_cont_next_line" 2>/dev/null || echo 0)"
        if plan_format_is_yaml "$plan_format"; then
          _cont_next_id="$(plan_yaml_frontmatter_op "$PLAN_PATH" "get_id" "$_cont_next_target" 2>/dev/null || true)"
        fi
      fi
      ralph_run_plan_continuation_summary_record_completion \
        "$line_num" \
        "$task_ordinal" \
        "$todo_id" \
        "$todo_hash" \
        "$todo_text" \
        "$_cont_completion_summary" \
        "$_cont_verify_status" \
        "${_agent_verify_reason:-}" \
        "${POST_VERIFICATION_FAILURE_ARTIFACT:-}" \
        "$_cont_next_line" \
        "$_cont_next_ordinal" \
        "$_cont_next_id" \
        "$_cont_next_text"

      # Clear the per-session manual-ack file after any successful TODO completion.
      rm -f "$(ralph_plan_manual_ack_path)" 2>/dev/null || true
      rm -f "$PENDING_HUMAN"
      if declare -F ralph_run_plan_revoke_workflow_operator_input_capability >/dev/null 2>&1; then
        ralph_run_plan_revoke_workflow_operator_input_capability
      fi
      if declare -F ralph_session_todo_identity_thaw >/dev/null 2>&1; then
        ralph_session_todo_identity_thaw
      fi
      break
    fi

    ralph_sync_human_action_file_state

    if [[ -f "$PENDING_HUMAN" ]]; then
      if [[ "$HUMAN_PROMPT_DISABLE_FLAG" == "1" ]]; then
        ralph_run_plan_log "ERROR: $PENDING_HUMAN exists but human prompt disable flag is active"
        echo -e "${C_R}Agent requested human input; prompts disabled. Remove pending file or unset CURSOR_PLAN_DISABLE_HUMAN_PROMPT or RALPH_PLAN_DISABLE_HUMAN_PROMPT.${C_RST}" >&2
        read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
        _ralph_write_plan_usage_summary "$done_count" "$total_count"
        ralph_runtime_overlay_cleanup_if_needed
        exit 4
      fi
      _saved_q="$(<"$PENDING_HUMAN")"
      human_block=""

      if [[ -t 0 ]] && [[ -t 1 ]]; then
        echo "" >&2
        echo -e "${C_Y}${C_BOLD}--- Agent question (TODO stays open until resolved) ---${C_RST}" >&2
        echo "$_saved_q" >&2
        echo "" >&2
        echo -e "${C_B}Your answer (finish with \".\", \":edit\" opens \$EDITOR, \":cancel\" aborts):${C_RST}" >&2
        while IFS= read -e -r _hl </dev/tty; do
          [[ "$_hl" == "." ]] && break
          if [[ "$_hl" == ":cancel" ]]; then
            rm -f "$PENDING_HUMAN"
            {
              echo ""
              echo "### $(date '+%Y-%m-%d %H:%M:%S')"
              echo "**Agent asked:**"
              echo "$_saved_q"
              echo "**Operator answered:**"
              echo "operator cancelled:"
            } >>"$HUMAN_CONTEXT"
            ralph_run_plan_log "human cancelled reply (TTY); exiting as stuck for line $line_num"
            echo -e "${C_Y}operator cancelled: aborting plan run.${C_RST}" >&2
            read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
            _ralph_write_plan_usage_summary "$done_count" "$total_count"
          ralph_runtime_overlay_cleanup_if_needed
            exit 4
          fi
          if [[ "$_hl" == ":edit" ]]; then
            # Create tmpfile for editing
            _edit_dir="$WORKSPACE/.ralph-workspace/human-reply"
            mkdir -p "$_edit_dir"
            _edit_file="$_edit_dir/edit-$(echo "$PLAN_PATH" | sha256sum | head -c 16)-${line_num}.txt"
            printf '%s' "$human_block" > "$_edit_file"
            _editor="${VISUAL:-${EDITOR:-nano}}"
            if $_editor "$_edit_file" </dev/tty >/dev/tty 2>&1; then
              human_block="$(cat "$_edit_file")"
              rm -f "$_edit_file"
              echo "- (edited via $_editor)" >&2
            else
              echo "- (edit cancelled)" >&2
            fi
            continue
          fi
          human_block+="${_hl}"$'\n'
        done
        if [[ -z "${human_block//[$' \t\n']/}" ]]; then
          human_block="(empty reply)"
        fi
        rm -f "$PENDING_HUMAN"
        {
          echo ""
          echo "### $(date '+%Y-%m-%d %H:%M:%S')"
          echo "**Agent asked:**"
          echo "$_saved_q"
          echo "**Operator answered:**"
          echo "$human_block"
        } >>"$HUMAN_CONTEXT"
        ralph_run_plan_log "human reply recorded (TTY); re-invoking agent for line $line_num"
        ralph_sync_human_action_file_state
        echo -e "${C_G}Answer recorded. Re-running agent for this TODO...${C_RST}" >&2
        human_gate_satisfied_for_line=1
        # Preserve attempts_on_line when post-verification reopen is active to enforce retry cap.
        if [[ "$_post_verify_reopen_retry_active" == "1" ]]; then
          _post_verify_reopen_retry_active=0
          ralph_run_plan_log "post-verification reopen retry: preserving attempts_on_line=$attempts_on_line after human reply"
        else
          attempts_on_line=0
        fi
        ralph_wait 1
        continue
      fi
      ralph_human_pause_for_operator_offline
      human_gate_satisfied_for_line=1
      # Preserve attempts_on_line when post-verification reopen is active to enforce retry cap.
      if [[ "$_post_verify_reopen_retry_active" == "1" ]]; then
        _post_verify_reopen_retry_active=0
        ralph_run_plan_log "post-verification reopen retry: preserving attempts_on_line=$attempts_on_line after human reply (offline)"
      else
        attempts_on_line=0
      fi
      ralph_wait 1
      continue
    fi

    if declare -F ralph_bg_invocation_try_schedule_continuation >/dev/null 2>&1 \
      && ralph_bg_invocation_try_schedule_continuation; then
      ralph_run_plan_log "tier2 invocation-boundary: continuation invocation for line=$line_num (gutter budget preserved)"
      ralph_wait 1
      continue
    fi

    attempts_on_line=$((attempts_on_line + 1))
    if [[ $attempts_on_line -gt $_todo_retry_limit ]]; then
      ralph_run_plan_log "GUTTER: line $line_num unchanged after $attempts_on_line attempts (per-TODO limit=$_todo_retry_limit)"
      _gutter_help_msg="Plan runner stopped (gutter): this TODO stayed open after $attempts_on_line attempts (per-TODO limit is $_todo_retry_limit). Unblock by fixing the task, editing the plan line, or raising the limit (CURSOR_PLAN_GUTTER_ITER / CLAUDE_PLAN_GUTTER_ITER / CODEX_PLAN_GUTTER_ITER or --max-iterations). To ask you a question, the agent should write a structured human-request record to: $PENDING_ABS"
      if ralph_should_persist_human_files; then
        ralph_write_human_action_file "$_gutter_help_msg"
      fi
      echo "" >&2
      echo -e "${C_R}${C_BOLD}Agent did not complete this TODO after $attempts_on_line tries (gutter limit $_todo_retry_limit).${C_RST}" >&2
      echo -e "  Plan: $PLAN_PATH  Line $line_num: $todo_text" >&2
      echo -e "${C_DIM}Human help needed: adjust the plan or complete the work, then re-run.${C_RST}" >&2
      echo -e "${C_DIM}To ask you a question instead of retrying blindly, the agent should write a structured human-request record to:${C_RST}" >&2
      echo "  $PENDING_ABS" >&2
      read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
      _ralph_write_plan_usage_summary "$done_count" "$total_count"
      ralph_runtime_overlay_cleanup_if_needed
      exit 1
    fi
    ralph_run_plan_log "TODO line $line_num still open (attempt $attempts_on_line/$_todo_retry_limit); retrying"
    ralph_wait 2
  done
done
