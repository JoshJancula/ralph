#!/usr/bin/env bash
##
## Invokes `codex exec` with the full plan prompt as a single argv element.
## Used by `.ralph/run-plan.sh` when `--runtime codex`.
##
## Env:
##   CODEX_PLAN_CLI (default: codex)
##   CODEX_PLAN_SANDBOX (upstream codex exec --help values: read-only, workspace-write, danger-full-access; default: workspace-write)
##     danger-full-access removes the sandbox and is high risk
##   CODEX_PLAN_MODEL, CURSOR_PLAN_MODEL
##   CODEX_PLAN_EXEC_EXTRA (space-separated extra args before prompt)
##   CODEX_PLAN_NO_ADD_AGENTS_DIR (default unset): set to 1 to omit --add-dir <workspace>/.ralph-workspace on non-resume runs (default adds it so session and orchestration files under .ralph-workspace/ are visible to Codex; name is historical)
##   RALPH_PLAN_CLI_RESUME=1: pass --json so session id can be captured (python in invoke)
##   RALPH_PLAN_CAPTURE_USAGE=1 (default 1): also pass --json so the demux can collect token usage counters
##   RALPH_RUN_PLAN_RESUME_SESSION_ID: when set, use `codex exec resume <id> ...` instead of one-shot exec
##   RALPH_RUN_PLAN_RESUME_BARE=1 with RALPH_PLAN_ALLOW_UNSAFE_RESUME=1: `codex exec resume --last ...` when no id (unsafe locally)
##   RALPH_PLAN_SESSION_STRATEGY=checkpoint: always use plain `codex exec` (never `codex exec resume`); prompt file
##     is still the first argv to this wrapper; --json and usage parsing behave like non-resume runs.
##   CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX (default 0): When 1, appends
##     --dangerously-bypass-approvals-and-sandbox (alias --yolo) to codex exec calls.
##     Use only in isolated, trusted environments; this removes all sandbox and approval controls.
##     See openai/codex#9144 for resume path caveats.

set -euo pipefail

prompt_file="${1:-}"
workspace="${2:-}"

if [[ -z "$prompt_file" || -z "$workspace" ]]; then
  echo 'Usage: run-plan-invoke-codex-exec.sh <prompt-file> <workspace>' >&2
  exit 2
fi

prompt="$(<"$prompt_file")"

cli="${CODEX_PLAN_CLI:-${CURSOR_PLAN_CLI:-codex}}"
sandbox="${CODEX_PLAN_SANDBOX:-workspace-write}"
case "$sandbox" in
  read-only|workspace-write|danger-full-access)
    ;;
  *)
    echo "Error: CODEX_PLAN_SANDBOX must be one of read-only, workspace-write, or danger-full-access." >&2
    exit 2
    ;;
esac

# `codex exec resume` only accepts options documented under `resume` (no --sandbox/--add-dir);
# flags must come before [SESSION_ID] [PROMPT]. Sandbox overrides go through `-c sandbox_mode="..."`
# before the session id/prompt. Plain `codex exec` supports --sandbox and --add-dir.
resume_bare=0
resume_session=0
if [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
  resume_bare=1
elif [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
  resume_session=1
fi

if [[ "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" == "checkpoint" ]]; then
  resume_bare=0
  resume_session=0
fi

if [[ "$resume_bare" == "1" ]]; then
  args=(exec resume --last -c "sandbox_mode=\"$sandbox\"")
elif [[ "$resume_session" == "1" ]]; then
  args=(exec resume -c "sandbox_mode=\"$sandbox\"")
else
  args=(exec --sandbox "$sandbox")
fi

codex_toml_string() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

codex_add_budgeted_config_args() {
  [[ "${RALPH_PLAN_TOKEN_MODE:-legacy}" == "budgeted" ]] || return 0

  local mcp_server="$workspace/.ralph/mcp-server.sh"
  local plan_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
  local artifact_ns="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-manual}}"
  local artifact_dir="${RALPH_ARTIFACT_DIR:-$plan_root/artifacts/$artifact_ns}"
  local ledger_file="${RALPH_MCP_LEDGER_FILE:-$plan_root/logs/$artifact_ns/mcp-budgeted-tools.jsonl}"
  local allowlist="${RALPH_MCP_ALLOWLIST:-$workspace:$plan_root}"
  local bash_allowlist="${RALPH_BUDGETED_BASH_ALLOWLIST:-git,npm,pnpm,yarn,bun,cargo,go,python,python3,node,bash,sh,rg,grep,sed,awk,find,ls,cat,tail,head,wc,make,bats}"
  local enabled="${RALPH_BUDGETED_CODEX_ENABLED_TOOLS:-[\"mcp.ralph.ralph_read\",\"mcp.ralph.ralph_search\",\"mcp.ralph.ralph_bash\",\"mcp.ralph.ralph_diff\",\"mcp.ralph.ralph_patch\",\"mcp.ralph.ralph_artifact_summary\"]}"
  local disabled="${RALPH_BUDGETED_CODEX_DISABLED_TOOLS:-[\"shell\",\"exec\",\"exec_command\",\"unified_exec\",\"apply_patch\",\"view_image\",\"web_search\"]}"
  local env_inline
  env_inline="{PATH=$(codex_toml_string "${PATH:-/usr/bin:/bin}"),RALPH_MCP_WORKSPACE=$(codex_toml_string "$workspace"),RALPH_MCP_ALLOWLIST=$(codex_toml_string "$allowlist"),RALPH_TOOL_RESULT_MAX_BYTES=$(codex_toml_string "${RALPH_TOOL_RESULT_MAX_BYTES:-32768}"),RALPH_MCP_LEDGER_FILE=$(codex_toml_string "$ledger_file"),RALPH_ARTIFACT_DIR=$(codex_toml_string "$artifact_dir"),RALPH_PLAN_WORKSPACE_ROOT=$(codex_toml_string "$plan_root"),RALPH_ARTIFACT_NS=$(codex_toml_string "$artifact_ns"),RALPH_PLAN_KEY=$(codex_toml_string "${RALPH_PLAN_KEY:-manual}"),RALPH_BUDGETED_BASH_ALLOWLIST=$(codex_toml_string "$bash_allowlist")}"

  args+=(--ignore-user-config --ignore-rules)
  args+=(--config 'approval_policy="never"')
  args+=(--config 'sandbox_mode="read-only"')
  args+=(--config "enabled_tools=$enabled")
  args+=(--config "disabled_tools=$disabled")
  args+=(--config 'mcp_servers.ralph.command="bash"')
  args+=(--config "mcp_servers.ralph.args=[$(codex_toml_string "$mcp_server")]")
  args+=(--config "mcp_servers.ralph.env=$env_inline")
}

codex_add_budgeted_config_args

model="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
if [[ -n "$model" && "$model" != "auto" ]]; then
  args+=(--model "$model")
fi

if [[ "$resume_bare" != "1" && "$resume_session" != "1" ]]; then
  if [[ "${CODEX_PLAN_NO_ADD_AGENTS_DIR:-0}" != "1" ]]; then
    _ws_abs="$(cd "$workspace" && pwd)"
    mkdir -p "$_ws_abs/.ralph-workspace"
    args+=(--add-dir "$_ws_abs/.ralph-workspace")
  fi
  if [[ -n "${CODEX_GLOBAL_RUNTIME_ROOT:-}" ]]; then
    args+=(--add-dir "$CODEX_GLOBAL_RUNTIME_ROOT")
  fi
fi

# Append bypass flag after sandbox/model/add-dir logic, before --json or prompt.
if [[ "${CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX:-0}" == "1" ]]; then
  args+=(--dangerously-bypass-approvals-and-sandbox)
fi

if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" || "${RALPH_PLAN_CAPTURE_USAGE:-1}" == "1" ]]; then
  args+=(--json)
fi

if [[ -n "${CODEX_PLAN_EXEC_EXTRA:-}" ]]; then
  read -r -a extra_args <<< "${CODEX_PLAN_EXEC_EXTRA}"
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    args+=("${extra_args[@]}")
  fi
fi

if [[ "$resume_session" == "1" ]]; then
  args+=("${RALPH_RUN_PLAN_RESUME_SESSION_ID}")
fi

args+=("$prompt")

(
  cd "$workspace"
  exec "$cli" "${args[@]}"
)
