#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_ANTIGRAVITY_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_ANTIGRAVITY_LOADED=1

# Public interface:
#   ralph_run_plan_invoke_antigravity -- run the antigravity CLI (agy) for a TODO.
#   run_plan_invoke_antigravity_session_resume_args / run_plan_invoke_antigravity_bare_resume_args -- argv helpers for resume.
#   run_plan_invoke_antigravity_bare_resume_warn -- stderr when bare resume is disallowed.
#   run_plan_invoke_antigravity_capture_conversation -- record agy's conversation id for the next TODO.
#
# Antigravity model contract:
#   Available models come from `agy models` and the chosen exact display string
#   is passed unchanged to `agy --model "<exact model string from agy models>" ...`.
#   The model id is never normalized or remapped.
#
# agy invocation contract (verified against agy 1.1.9):
#   - Headless prompt:   `agy --print "<prompt>"`.
#   - Streaming output:  `agy --output-format stream-json`.
#   - Resume by id:      `agy --conversation "<id>"`.
#   - Resume most recent:`agy --continue`.
#   - Model:             `agy --model "<display string>"`.
#   - Print wait budget: `agy --print-timeout "<duration>"` (default 5m; we widen it
#                        to Ralph's per-invocation timeout so long TODOs are not cut off).
#   - Auto-approve:      `agy --dangerously-skip-permissions` (required for non-interactive
#                        runs; otherwise agy blocks on tool-permission prompts).
#   agy mints its own conversation id; it cannot be preset. We capture it after each run
#   from agy's store so the next TODO resumes the same conversation, keeping agy's
#   session-tied prompt cache warm.

_run_plan_invoke_antigravity_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_run_plan_invoke_antigravity_dir/run-plan-cli-helpers.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_antigravity_dir/run-plan-invoke-common.sh"
unset _run_plan_invoke_antigravity_dir

# Antigravity is a native runtime (`agy`) which reads MCP server catalogs from
# a config file. In Ralph mode we must pass a merged, temporary per-run
# config via ANTIGRAVITY_CONFIG without persisting overlays.
if ! declare -F ralph_runtime_config_mcp_resolve >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  # runtime-config-mcp.sh lives alongside other bash-lib runtime helpers.
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../runtime-config" && pwd)/runtime-config-mcp.sh"
fi

run_plan_invoke_antigravity_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--conversation \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_antigravity_session_new_args() {
  # agy cannot be told to use a specific new conversation id; it mints its own.
  # Start fresh (no resume flag) and capture the real id afterward.
  :
}

run_plan_invoke_antigravity_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--continue)"
}

run_plan_invoke_antigravity_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare agy --continue." >&2
}

# Look up agy's recorded conversation id for a workspace from last_conversations.json.
# agy keys the map by project dir; pick the longest key that is a prefix of the
# workspace path (the project dir agy resolved the run to). Prints the id, if any.
run_plan_invoke_antigravity_lookup_conversation() {
  local store="$1"
  local workspace="$2"

  if command -v python3 >/dev/null 2>&1; then
    RALPH_AGY_STORE="$store" RALPH_AGY_WS="$workspace" python3 - <<'PY'
import json, os, sys
store = os.environ.get("RALPH_AGY_STORE", "")
ws = os.environ.get("RALPH_AGY_WS", "")
try:
    with open(store, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
best_key = None
for key in data:
    if ws == key or ws.startswith(key.rstrip("/") + "/"):
        if best_key is None or len(key) > len(best_key):
            best_key = key
if best_key is None and len(data) == 1:
    best_key = next(iter(data))
if best_key is not None:
    val = data.get(best_key)
    if isinstance(val, str) and val:
        print(val)
PY
    return 0
  fi

  # awk fallback: parse the flat "key": "value" JSON map and longest-prefix match.
  awk -v ws="$workspace" '
    {
      while (match($0, /"[^"]*"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
        pair = substr($0, RSTART, RLENGTH)
        $0 = substr($0, RSTART + RLENGTH)
        n = split(pair, parts, "\"")
        # parts: 1="" 2=key 3=":" 4=value 5=""
        key = parts[2]; val = parts[4]
        prefix = key; sub(/\/$/, "", prefix)
        if (ws == key || index(ws, prefix "/") == 1) {
          if (length(key) > bestlen) { bestlen = length(key); bestval = val }
        }
        count++; lastval = val
      }
    }
    END {
      if (bestval != "") print bestval
      else if (count == 1) print lastval
    }
  ' "$store"
}

run_plan_invoke_antigravity_capture_conversation() {
  local session_file="${SESSION_ID_FILE:-}"
  [[ -n "$session_file" ]] || return 0

  local gemini_home="${RALPH_GEMINI_HOME:-$HOME/.gemini}"
  local store="$gemini_home/antigravity-cli/cache/last_conversations.json"
  [[ -f "$store" ]] || return 0

  local workspace="${WORKSPACE:-${RALPH_PROJECT_ROOT:-$PWD}}"
  local cid
  cid="$(run_plan_invoke_antigravity_lookup_conversation "$store" "$workspace")" || return 0
  [[ -n "$cid" ]] || return 0
  printf '%s\n' "$cid" >"$session_file"
}

ralph_run_plan_invoke_antigravity() {
  ralph_run_plan_sync_mode_knobs
  local project_root="${RALPH_PROJECT_ROOT:-${WORKSPACE:-$PWD}}"

  # Create and export ANTIGRAVITY_CONFIG only when the effective MCP catalog
  # requires ambient+agent+Ralph merging. Always restore/remove temp artifacts.
  local antigravity_config_path=""
  cleanup_antigravity_config() {
    if [[ -n "${antigravity_config_path:-}" ]]; then
      # ralph_runtime_config_mcp_cleanup removes RALPH_RUNTIME_MCP_RESOLVE_PATH;
      # keep this unlink as a defensive fallback for any partial failures.
      rm -f "$antigravity_config_path" 2>/dev/null || true
    fi
    antigravity_config_path=""
    unset ANTIGRAVITY_CONFIG
    ralph_runtime_config_mcp_cleanup >/dev/null 2>&1 || true
  }
  trap cleanup_antigravity_config EXIT

  ralph_runtime_config_mcp_resolve "antigravity" "$project_root" "${PREBUILT_AGENT:-}" "${WORKSPACE:-$project_root}" || {
    # Ensure cleanup runs via trap.
    return 1
  }
  if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "${RALPH_RUNTIME_MCP_RESOLVE_PATH}" ]]; then
    antigravity_config_path="$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    # Only export ANTIGRAVITY_CONFIG when the run is in Ralph-mode
    # (ralph/hybrid). Native-only runs may still resolve MCP overlays,
    # but they must not be forced to use Ralph's merged catalog.
    if [[ "${RALPH_MODE:-no}" != "no" ]]; then
      export ANTIGRAVITY_CONFIG="$antigravity_config_path"
    fi
  fi

  # Log path, exit-code sidecar, and session-id file for resume capture.
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  local cli="${ANTIGRAVITY_PLAN_CLI:-}"
  if [[ -z "$cli" ]]; then
    if ! cli="$(ralph_resolve_antigravity_cli)"; then
      echo "Error: Antigravity CLI not found (set ANTIGRAVITY_PLAN_CLI or install agy)." >&2
      return 1
    fi
  fi

  if ! command -v "$cli" &>/dev/null; then
    echo "Error: Antigravity CLI not found at '$cli'." >&2
    return 1
  fi

  # shellcheck disable=SC2034
  ANTIGRAVITY_CLI="$cli"

  local -a args=()
  run_plan_invoke_common_add_model_flag args --model
  run_plan_invoke_common_add_reasoning_effort_flag args antigravity "${ANTIGRAVITY_PLAN_CLI:-agy}"
  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_antigravity_session_resume_args \
    run_plan_invoke_antigravity_session_new_args \
    run_plan_invoke_antigravity_bare_resume_args \
    run_plan_invoke_antigravity_bare_resume_warn

  # Auto-approve tool permissions for non-interactive runs (opt out with
  # ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=0). Without this agy blocks on prompts.
  if [[ "${ANTIGRAVITY_PLAN_SKIP_PERMISSIONS:-1}" == "1" ]]; then
    args+=(--dangerously-skip-permissions)
  fi

  # Widen agy's print-mode wait budget to Ralph's per-invocation timeout so long
  # TODOs are not truncated by agy's 5m default.
  if [[ -n "${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS:-}" ]]; then
    args+=(--print-timeout "${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s")
  fi

  # Text output is held until the final response, which makes a long-running
  # headless run appear idle. agy 1.1.9 emits live step events in stream-json
  # mode; the common demuxer renders those events and captures its session and
  # usage data as they arrive.
  args+=(--output-format stream-json --print "$PROMPT")

  run_plan_invoke_antigravity_cli() {
    run_plan_invoke_common_launch_cli antigravity "$cli" "${args[@]}"
  }

  run_plan_invoke_common_execute \
    run_plan_invoke_antigravity_cli \
    antigravity \
    ""

  # Record the conversation id agy used so the next TODO can resume it.
  run_plan_invoke_antigravity_capture_conversation
}
