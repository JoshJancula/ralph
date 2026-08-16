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
#   run_plan_invoke_antigravity_graph_enabled -- true when this invoke is a graph node.
#   run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized -- graph bypass gate.
#   run_plan_invoke_antigravity_graph_approval_live_supported -- graph help-only native-control proof (no model call).
#   run_plan_invoke_antigravity_graph_approval_capabilities -- advertise only enforceable Antigravity lifetimes.
#   run_plan_invoke_antigravity_graph_approval_apply / restore -- common resumable overlay fallback.
#   run_plan_invoke_antigravity_graph_approval_await_operator -- noninteractive wait without hanging.
#   run_plan_invoke_antigravity_graph_approval_start_or_fallback -- live path only after nonbillable proof.
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
#   - Auto-approve:      `agy --dangerously-skip-permissions` for ordinary non-graph
#                        non-interactive runs (opt out with ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=0).
#                        Graph nodes omit this flag unless an explicit trusted
#                        isolated-sandbox policy authorizes it.
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

run_plan_invoke_antigravity_graph_enabled() {
  case "${RALPH_GRAPH_APPROVAL:-}" in
    1|true|yes|on)
      return 0
      ;;
  esac
  [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]
}

_run_plan_invoke_antigravity_explicit_true() {
  case "${1:-}" in
    1|true|True|TRUE)
      return 0
      ;;
  esac
  return 1
}

_run_plan_invoke_antigravity_node_policy_field() {
  local key="${1:-}"
  local policy="${RALPH_GRAPH_NODE_POLICY:-}"
  [[ -n "$key" && -n "$policy" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$policy" | jq -r --arg k "$key" '
    if type != "object" then empty
    elif has($k) then (.[$k] | tostring)
    else empty
    end
  ' 2>/dev/null || true
}

# Isolated sandbox: snapshot, or worktree with a proved runtime sandbox.
# Shared, omitted, and unproved worktree modes are not isolated sandboxes.
run_plan_invoke_antigravity_isolated_sandbox() {
  local mode="${RALPH_GRAPH_WORKSPACE_MODE:-}"
  if [[ -z "$mode" ]]; then
    mode="$(_run_plan_invoke_antigravity_node_policy_field parentWorkspaceMode)"
  fi
  if [[ -z "$mode" ]]; then
    mode="$(_run_plan_invoke_antigravity_node_policy_field workspaceMode)"
  fi
  case "$mode" in
    snapshot)
      return 0
      ;;
    worktree)
      [[ "${RALPH_GRAPH_GIT_SANDBOX_PROVEN:-}" == "1" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# Explicit trusted isolated-sandbox policy. The non-graph
# ANTIGRAVITY_PLAN_SKIP_PERMISSIONS default is not authorization.
run_plan_invoke_antigravity_trusted_isolated_sandbox_policy() {
  if _run_plan_invoke_antigravity_explicit_true "${RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX:-}"; then
    return 0
  fi
  if [[ "${RALPH_GRAPH_PERMISSION_BYPASS:-}" == "trusted-isolated-sandbox" ]]; then
    return 0
  fi
  if _run_plan_invoke_antigravity_explicit_true \
    "$(_run_plan_invoke_antigravity_node_policy_field trustedIsolatedSandbox)"; then
    return 0
  fi
  [[ "$(_run_plan_invoke_antigravity_node_policy_field permissionBypass)" == "trusted-isolated-sandbox" ]]
}

# Graph nodes add --dangerously-skip-permissions only when an explicit
# trusted isolated-sandbox policy authorizes an isolated snapshot/worktree.
# Non-graph runs keep the existing ANTIGRAVITY_PLAN_SKIP_PERMISSIONS default.
run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized() {
  if ! run_plan_invoke_antigravity_graph_enabled; then
    return 1
  fi
  run_plan_invoke_antigravity_isolated_sandbox || return 1
  run_plan_invoke_antigravity_trusted_isolated_sandbox_policy
}

run_plan_invoke_antigravity_should_skip_permissions() {
  if [[ "${ANTIGRAVITY_PLAN_SKIP_PERMISSIONS:-1}" != "1" ]]; then
    return 1
  fi
  if run_plan_invoke_antigravity_graph_enabled; then
    run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized
    return
  fi
  return 0
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
  ralph_run_plan_subagents_log_contract antigravity || return 1
  ralph_run_plan_subagents_require_runtime_capability antigravity || return 1
  ralph_run_plan_native_subagent_verify_runtime antigravity || return 1
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
    if run_plan_invoke_antigravity_graph_enabled; then
      run_plan_invoke_antigravity_graph_approval_restore success >/dev/null 2>&1 || true
    fi
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

  # Auto-approve tool permissions for ordinary non-graph non-interactive runs
  # (opt out with ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=0). Graph nodes omit the
  # bypass unless an explicit trusted isolated-sandbox policy authorizes it.
  if run_plan_invoke_antigravity_should_skip_permissions; then
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

# Graph-only Antigravity approval transport.
# A live structured channel is used only after nonbillable `--help` proof of
# `--permission-prompt-tool`. `--dangerously-skip-permissions`, `--mode
# accept-edits`, and `--sandbox` are not a same-operation response protocol.
# Otherwise the common resumable overlay writes project `.agents/settings.json`
# only. Advertised lifetimes are only those enforceable without ambient user
# writes: once and run. always-policy is Ralph project policy reapplied through
# future temporary overlays, never a native Antigravity lifetime and never
# `~/.agents` or `~/.gemini`. When live controls are unproved and no decision
# is present, emit actionable awaiting-operator state instead of hanging on an
# interactive permission prompt. Temporary ANTIGRAVITY_CONFIG and approval
# overlays are restored on every invoke exit.
# Normal non-graph `ralph_run_plan_invoke_antigravity` does not call these
# helpers except for overlay restore during cleanup.

run_plan_invoke_antigravity_graph_approval_graph_enabled() {
  run_plan_invoke_antigravity_graph_enabled
}

_run_plan_invoke_antigravity_graph_approval_ensure_adapter() {
  if declare -F ralph_approval_adapter_capabilities >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-approval-adapter.sh"
}

_run_plan_invoke_antigravity_graph_approval_live_capability_missing() {
  local cli_name="${1:-agy}"
  local help_text
  local -a missing=()

  if ! command -v "$cli_name" >/dev/null 2>&1; then
    printf '%s\n' "antigravity cli"
    return 0
  fi

  if ! help_text="$("$cli_name" --help 2>/dev/null)"; then
    missing+=("antigravity permission-prompt-tool")
    printf '%s\n' "${missing[@]}"
    return 0
  fi

  if [[ "$help_text" != *"--permission-prompt-tool"* && "$help_text" != *"permission-prompt-tool"* ]]; then
    missing+=("antigravity permission-prompt-tool")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
  fi
}

# run_plan_invoke_antigravity_graph_approval_live_supported [cli]
# Help-only. Never starts a session or sends a prompt.
# --dangerously-skip-permissions is a bypass, not a live control.
run_plan_invoke_antigravity_graph_approval_live_supported() {
  local cli_name="${1:-${ANTIGRAVITY_PLAN_CLI:-agy}}"
  local missing
  missing="$(_run_plan_invoke_antigravity_graph_approval_live_capability_missing "$cli_name")"
  [[ -z "$missing" ]]
}

# run_plan_invoke_antigravity_graph_approval_capabilities [cli]
# Overlay can enforce once and run. Live streaming is true only after help proof.
# always-policy stays unsupported: it must not edit ambient user files.
run_plan_invoke_antigravity_graph_approval_capabilities() {
  local cli_name="${1:-${ANTIGRAVITY_PLAN_CLI:-agy}}"
  local live="false"
  local proof

  _run_plan_invoke_antigravity_graph_approval_ensure_adapter || return 1
  if run_plan_invoke_antigravity_graph_approval_live_supported "$cli_name"; then
    live="true"
  fi
  proof="$(jq -nc --argjson live "$live" '{
    liveRequestStreaming: $live,
    sameOperationResponse: $live,
    sessionContinuation: true,
    lifetimes: {once: true, run: true, "always-policy": false}
  }')"
  ralph_approval_adapter_capabilities antigravity "$proof"
}

# run_plan_invoke_antigravity_graph_approval_fallback [reason]
run_plan_invoke_antigravity_graph_approval_fallback() {
  local reason="${1:-unsupported}"
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "{\"schemaVersion\":1,\"runtime\":\"antigravity\",\"fallback\":true,\"reason\":\"${reason}\",\"path\":\"overlay\"}"
    return 0
  fi
  jq -nc --arg reason "$reason" '{
    schemaVersion: 1,
    runtime: "antigravity",
    fallback: true,
    reason: $reason,
    path: "overlay",
    liveRequestStreaming: false
  }'
}

run_plan_invoke_antigravity_graph_approval_settings_target() {
  local root="${WORKSPACE:-${RALPH_PROJECT_ROOT:-}}"
  if [[ -z "$root" ]]; then
    echo "Error: Antigravity graph approval overlay requires WORKSPACE or RALPH_PROJECT_ROOT" >&2
    return 1
  fi
  printf '%s/.agents/settings.json' "$root"
}

_run_plan_invoke_antigravity_graph_approval_is_ambient() {
  local target="$1" home="${HOME:-}"
  if ralph_approval_adapter_is_ambient_user_path "$target"; then
    return 0
  fi
  [[ -n "$home" ]] || return 1
  case "$target" in
    "$home/.gemini"|"$home/.gemini"/*)
      return 0
      ;;
  esac
  return 1
}

_run_plan_invoke_antigravity_graph_approval_reject_bypass() {
  local raw
  raw="$(ralph_approval_adapter_trim "${1-}")"
  ralph_approval_adapter_reject_dangerous_fallback "$raw" || return 1
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    *accept-edits*|*dangerously-skip-permissions*)
      echo "Error: approval adapter rejects ${raw} as a permission fallback" >&2
      return 1
      ;;
  esac
  return 0
}

# run_plan_invoke_antigravity_graph_approval_permission_rule <action> <resource> <effect>
run_plan_invoke_antigravity_graph_approval_permission_rule() {
  local action="$1" resource="$2" effect="$3"
  action="$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')"
  effect="$(printf '%s' "$effect" | tr '[:upper:]' '[:lower:]')"
  resource="${resource#"${resource%%[![:space:]]*}"}"
  resource="${resource%"${resource##*[![:space:]]}"}"
  if [[ -z "$resource" || "$resource" == *$'\n'* || "$resource" == *')'* ]]; then
    echo "Error: Antigravity graph approval resource must be a non-empty single line without ')'" >&2
    return 1
  fi
  case "$effect" in
    network)
      printf 'WebFetch(domain:%s)' "$resource"
      ;;
    read)
      case "$action" in
        bash|shell) printf 'Bash(%s)' "$resource" ;;
        *) printf 'Read(%s)' "$resource" ;;
      esac
      ;;
    write)
      case "$action" in
        bash|shell) printf 'Bash(%s)' "$resource" ;;
        write) printf 'Write(%s)' "$resource" ;;
        *) printf 'Edit(%s)' "$resource" ;;
      esac
      ;;
    *)
      echo "Error: Antigravity graph approval effect is unsupported: ${effect:-<empty>}" >&2
      return 1
      ;;
  esac
}

# Merge an Antigravity settings object with an exact allow or deny rule. Deny wins.
_run_plan_invoke_antigravity_graph_approval_merge_settings() {
  local existing="$1"
  local rule="$2"
  local kind="$3"
  if [[ -z "$existing" ]] || ! printf '%s' "$existing" | jq -e 'type == "object"' >/dev/null 2>&1; then
    existing='{}'
  fi
  printf '%s' "$existing" | jq -c --arg rule "$rule" --arg kind "$kind" '
    . as $src
    | (($src.permissions // {}) | type == "object") as $ok
    | (if $ok then ($src.permissions.allow // []) else [] end) as $allow0
    | (if $ok then ($src.permissions.deny // []) else [] end) as $deny0
    | (if ($allow0 | type) == "array" then $allow0 else [] end) as $allow
    | (if ($deny0 | type) == "array" then $deny0 else [] end) as $deny
    | (if $kind == "deny" then ($deny + [$rule] | unique) else $deny end) as $deny1
    | (if $kind == "deny" then [$allow[] | select(. != $rule)]
       elif ($deny1 | index($rule)) == null then ($allow + [$rule] | unique)
       else $allow end) as $allow1
    | ($src + {
        permissions: ((($src.permissions // {}) | if type == "object" then . else {} end) + {
          allow: $allow1,
          deny: $deny1
        })
      })
  '
}

_run_plan_invoke_antigravity_graph_approval_write_target() {
  local target="$1" overlay_text="$2"
  local existed=0 backup="" tmp_path
  _run_plan_invoke_antigravity_graph_approval_ensure_adapter || return 1
  ralph_approval_adapter_ensure_overlay_state antigravity || return 1
  if declare -F _runtime_overlay_abs_path >/dev/null 2>&1; then
    target="$(_runtime_overlay_abs_path "$target")"
  fi
  if _run_plan_invoke_antigravity_graph_approval_is_ambient "$target"; then
    echo "Error: Antigravity graph approval refuses ambient user path: $target" >&2
    return 1
  fi
  ralph_approval_adapter_overlay_load_state || true
  if [[ -f "$target" ]]; then
    existed=1
  fi
  runtime_overlay_record_original_file "$target" "" 1 || return 1
  if [[ ${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]} -gt 0 ]]; then
    backup="${RUNTIME_OVERLAY_MUTATED_BACKUPS[${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]}-1]}"
  fi
  mkdir -p "$(dirname "$target")"
  tmp_path="${target}.ralph-approval.tmp"
  if ! printf '%s\n' "$overlay_text" >"$tmp_path"; then
    runtime_overlay_restore_file "$target" "$backup" "$existed" || true
    echo "Error: Antigravity graph approval failed to write $target" >&2
    return 1
  fi
  mv "$tmp_path" "$target"
  RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS+=("$target")
  RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS+=("$backup")
  RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED+=("$existed")
  ralph_approval_adapter_overlay_install_traps
  ralph_approval_adapter_overlay_save_state || true
  jq -nc --arg target "$target" --arg backup "$backup" '{target:$target,backup:(if $backup == "" then null else $backup end)}'
}

# run_plan_invoke_antigravity_graph_approval_apply <request-json>
# Graph-only. Builds an equal-or-narrower project settings overlay, journals
# the original, and resumes the same session when continuation is supported.
run_plan_invoke_antigravity_graph_approval_apply() {
  local input="${1:-}"
  local caps translated decision lifetime grant_json
  local action resource effect rule kind
  local target existing overlay_text session_id tmp_dir

  if ! run_plan_invoke_antigravity_graph_approval_graph_enabled; then
    echo "Error: Antigravity graph approval apply is graph-only" >&2
    return 1
  fi
  _run_plan_invoke_antigravity_graph_approval_ensure_adapter || return 1
  if [[ -z "$input" ]] || ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: Antigravity graph approval apply requires a JSON object" >&2
    return 1
  fi
  _run_plan_invoke_antigravity_graph_approval_reject_bypass "$(printf '%s' "$input" | jq -r '.fallback // empty')" || return 1
  _run_plan_invoke_antigravity_graph_approval_reject_bypass "$(printf '%s' "$input" | jq -r '.permissionMode // .permission_mode // .approvalMode // .approval_mode // .mode // empty')" || return 1

  caps="$(run_plan_invoke_antigravity_graph_approval_capabilities "${ANTIGRAVITY_PLAN_CLI:-agy}")"
  translated="$(ralph_approval_adapter_translate_decision "$input" "$caps")" || return 1
  decision="$(printf '%s' "$translated" | jq -r '.decision')"
  lifetime="$(printf '%s' "$translated" | jq -r '.lifetime')"
  grant_json="$(printf '%s' "$translated" | jq -c '.grant')"
  session_id="$(printf '%s' "$input" | jq -r '.sessionId // .session_id // empty')"
  target="$(printf '%s' "$input" | jq -r '.target // empty')"
  if [[ -z "$target" ]]; then
    target="$(run_plan_invoke_antigravity_graph_approval_settings_target)" || return 1
  fi
  if declare -F _runtime_overlay_abs_path >/dev/null 2>&1; then
    target="$(_runtime_overlay_abs_path "$target")"
  fi
  if _run_plan_invoke_antigravity_graph_approval_is_ambient "$target"; then
    echo "Error: Antigravity graph approval refuses ambient user path: $target" >&2
    return 1
  fi

  if [[ "$decision" == "deny" ]]; then
    action="$(printf '%s' "$input" | jq -r '.request.action // .action // "Bash"')"
    resource="$(printf '%s' "$input" | jq -r '.request.resource // .resource // empty')"
    effect="$(printf '%s' "$input" | jq -r '.request.effect // .effect // "write"')"
    kind="deny"
  else
    action="$(printf '%s' "$grant_json" | jq -r '.action')"
    resource="$(printf '%s' "$grant_json" | jq -r '.resource')"
    effect="$(printf '%s' "$grant_json" | jq -r '.effect')"
    kind="allow"
  fi
  rule="$(run_plan_invoke_antigravity_graph_approval_permission_rule "$action" "$resource" "$effect")" || return 1

  existing="{}"
  if [[ -f "$target" ]]; then
    existing="$(cat "$target")"
  fi
  overlay_text="$(_run_plan_invoke_antigravity_graph_approval_merge_settings "$existing" "$rule" "$kind")" || return 1

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-antigravity-approval.XXXXXX")" || return 1

  if [[ "$decision" == "deny" ]]; then
    if ! _run_plan_invoke_antigravity_graph_approval_write_target "$target" "$overlay_text" >"$tmp_dir/write.json"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! ralph_approval_adapter_overlay_fallback "$(jq -nc --arg runtime antigravity '{decision:"deny",runtime:$runtime}')" "$caps" >"$tmp_dir/fallback.json"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    jq -nc \
      --argjson applied "$(cat "$tmp_dir/fallback.json")" \
      --argjson write "$(cat "$tmp_dir/write.json")" \
      --argjson grant "$grant_json" \
      --arg lifetime "$lifetime" \
      --arg decision "$decision" \
      --arg session "$session_id" \
      --arg overlay "$overlay_text" \
      '{
        schemaVersion: 1,
        runtime: "antigravity",
        path: "overlay",
        fallback: "overlay",
        applied: true,
        decision: $decision,
        lifetime: $lifetime,
        grant: $grant,
        equalOrNarrower: true,
        continuation: $applied.continuation,
        sessionStrategy: $applied.sessionStrategy,
        sessionId: (if $session == "" then null else $session end),
        target: $write.target,
        backup: $write.backup,
        restored: false,
        overlay: ($overlay | fromjson)
      }'
    rm -rf "$tmp_dir"
    return 0
  fi

  if ! ralph_approval_adapter_overlay_fallback "$(jq -nc \
    --arg runtime antigravity \
    --arg decision "$decision" \
    --arg target "$target" \
    --arg session "$session_id" \
    --argjson grant "$grant_json" \
    --argjson overlay "$overlay_text" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    '{
      decision: $decision,
      runtime: $runtime,
      action: $action,
      resource: $resource,
      effect: $effect,
      grant: $grant,
      target: $target,
      overlay: $overlay,
      sessionId: $session
    }')" "$caps" >"$tmp_dir/applied.json"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  jq -c \
    --argjson overlay "$overlay_text" \
    '. + {runtime:"antigravity", path:"overlay", overlay:$overlay}' \
    "$tmp_dir/applied.json"
  rm -rf "$tmp_dir"
}

# run_plan_invoke_antigravity_graph_approval_restore [reason]
run_plan_invoke_antigravity_graph_approval_restore() {
  _run_plan_invoke_antigravity_graph_approval_ensure_adapter || return 1
  ralph_approval_adapter_overlay_restore "${1:-success}"
}

# run_plan_invoke_antigravity_graph_approval_await_operator [request-json]
# Noninteractive graph wait. Prints actionable awaiting-operator state and
# returns 4. Never starts agy or waits on a TTY prompt.
run_plan_invoke_antigravity_graph_approval_await_operator() {
  local input="${1:-}"
  local action="unknown" resource="pending" effect="write" rule="" reason

  if ! run_plan_invoke_antigravity_graph_approval_graph_enabled; then
    echo "Error: Antigravity graph approval is graph-only" >&2
    return 1
  fi
  _run_plan_invoke_antigravity_graph_approval_ensure_adapter || return 1

  if [[ -n "$input" ]] && printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _run_plan_invoke_antigravity_graph_approval_reject_bypass "$(printf '%s' "$input" | jq -r '.fallback // empty')" || return 1
    action="$(printf '%s' "$input" | jq -r '.request.action // .action // "unknown"')"
    resource="$(printf '%s' "$input" | jq -r '.request.resource // .resource // "pending"')"
    effect="$(printf '%s' "$input" | jq -r '.request.effect // .effect // "write"')"
    rule="$(run_plan_invoke_antigravity_graph_approval_permission_rule "$action" "$resource" "$effect" 2>/dev/null || true)"
  fi
  reason="Antigravity graph node is awaiting operator permission; refusing to hang in noninteractive mode."

  jq -nc \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    --arg rule "$rule" \
    --arg reason "$reason" \
    '{
      schemaVersion: 1,
      runtime: "antigravity",
      fallback: true,
      path: "awaiting-operator",
      status: "awaiting-operator",
      classification: "operator-permission",
      operatorAction: "await-operator",
      outcome: "awaiting-operator",
      exitCode: 4,
      permissionRequest: {
        tool: $action,
        resource: $resource,
        effect: $effect,
        rule: (if $rule == "" then null else $rule end),
        decision: "pending"
      },
      reason: $reason,
      liveRequestStreaming: false
    }'
  return 4
}

# run_plan_invoke_antigravity_graph_approval_start_or_fallback [cli] [request-json]
# Live channel only after nonbillable help proof. A decision uses the common
# overlay. Missing live controls and no decision surface awaiting-operator
# instead of hanging on an interactive agy prompt.
run_plan_invoke_antigravity_graph_approval_start_or_fallback() {
  local cli="${1:-${ANTIGRAVITY_PLAN_CLI:-agy}}"
  local request="${2:-}"
  local caps

  if ! run_plan_invoke_antigravity_graph_approval_graph_enabled; then
    echo "Error: Antigravity graph approval is graph-only" >&2
    return 1
  fi
  _run_plan_invoke_antigravity_graph_approval_ensure_adapter || return 1

  if run_plan_invoke_antigravity_graph_approval_live_supported "$cli"; then
    caps="$(run_plan_invoke_antigravity_graph_approval_capabilities "$cli")"
    jq -nc --argjson caps "$caps" '{
      schemaVersion: 1,
      runtime: "antigravity",
      fallback: false,
      path: "live",
      channel: "permission-prompt-tool",
      liveRequestStreaming: $caps.liveRequestStreaming,
      sameOperationResponse: $caps.sameOperationResponse,
      sessionContinuation: $caps.sessionContinuation,
      lifetimes: $caps.lifetimes
    }'
    return 0
  fi

  if [[ -n "$request" ]]; then
    run_plan_invoke_antigravity_graph_approval_apply "$request" || return 1
    return 2
  fi
  run_plan_invoke_antigravity_graph_approval_await_operator
}
