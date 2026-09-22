#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_MANIFEST_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_MANIFEST_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if ! declare -F ralph_state_layout_version >/dev/null 2>&1; then
  _RALPH_RUN_PLAN_MANIFEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=../state-paths.sh
  source "$_RALPH_RUN_PLAN_MANIFEST_DIR/state-paths.sh"
  unset _RALPH_RUN_PLAN_MANIFEST_DIR
fi

ralph_run_plan_manifest_relative_path() {
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}" path="${1:-}"
  [[ -n "$state_root" && -n "$path" ]] || return 1
  state_root="${state_root%/}"
  case "$path" in
    "$state_root") printf '.' ;;
    "$state_root"/*) printf '%s' "${path#"$state_root"/}" ;;
    *)
      # state-paths resolves through pwd -P (macOS /var -> /private/var). Re-express
      # against the physical state root so relative paths still succeed.
      local physical
      physical="$(cd "$state_root" 2>/dev/null && pwd -P)" || return 1
      case "$path" in
        "$physical") printf '.' ;;
        "$physical"/*) printf '%s' "${path#"$physical"/}" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

# ralph_run_plan_write_manifest [status-override]
# Layout 1 writes logs/<plan-key>/runs/<run-id>/ plus the append-only run
# index. Layout 2 writes the attempt directory owned by the run that this plan
# execution belongs to, and keeps that run's catalog in step. A status
# override is how admission records "running" before the plan loop starts.
ralph_run_plan_write_manifest() {
  [[ -z "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]] || return 0
  local status="${1:-${EXIT_STATUS:-incomplete}}"
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}" run_id="${RALPH_PROCESS_RUN_ID:-}"
  local plan_key="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}"
  [[ -n "$state_root" && -n "$run_id" && -n "$plan_key" ]] || return 0

  # A workflow child attempt is owned by the outer run; a standalone plan run
  # owns itself and uses the implicit "plan" stage.
  local owner_run="${RALPH_WORKFLOW_RUN_ID:-$run_id}"
  local stage_id="${RALPH_STAGE_ID:-plan}" attempt_id="$run_id"
  local runs_dir run_dir layout
  mkdir -p "$state_root" || return 1
  # Decide the layout once per process so the admission and exit writes agree.
  # A workflow child follows the layout its outer run recorded (no catalog
  # means the outer run is layout 1); only a standalone run consults the
  # new-run default, and only when it has no catalog of its own yet.
  if [[ "${_RALPH_RUN_PLAN_MANIFEST_LAYOUT_RUN:-}" != "$run_id" ]]; then
    if [[ "$owner_run" != "$run_id" ]]; then
      _RALPH_RUN_PLAN_MANIFEST_LAYOUT="$(ralph_state_run_layout "$state_root" "$owner_run")" || return 1
    else
      # Catalog first, then an existing layout-1 run directory, then the
      # new-run default: a run that already has v1 state never moves.
      _RALPH_RUN_PLAN_MANIFEST_LAYOUT="$(_ralph_state_effective_layout "$state_root" "$run_id" "logs/$plan_key/runs/$run_id")" || return 1
    fi
    _RALPH_RUN_PLAN_MANIFEST_LAYOUT_RUN="$run_id"
  fi
  layout="$_RALPH_RUN_PLAN_MANIFEST_LAYOUT"
  # Layout 1 is the pre-plan contract: one manifest written at exit and one
  # index row. It has no admission write.
  if [[ "$layout" != 2 && -n "${1:-}" && "$1" == "running" ]]; then
    return 0
  fi
  if [[ "$layout" == 2 ]]; then
    # Outer workflow run owns child attempts; standalone plans own themselves.
    run_dir="$(ralph_state_attempt_dir "$state_root" "$owner_run" "$stage_id" "$attempt_id")" || return 1
  else
    # The layout is already decided; build the v1 path directly rather than
    # letting a helper re-derive it from the environment default.
    ralph_state_path_segment "$plan_key" "plan key" >/dev/null || return 1
    ralph_state_path_segment "$run_id" "run id" >/dev/null || return 1
    run_dir="$(ralph_state_path_resolve "$state_root" "logs/$plan_key/runs/$run_id")" || return 1
    runs_dir="$(dirname -- "$run_dir")"
  fi
  local manifest="$run_dir/run-manifest.json" tmp files='[]'
  [[ "$layout" != 2 && -f "$manifest" ]] && return 0
  mkdir -p "$run_dir" || return 1
  if [[ "$layout" == 2 ]]; then
    # Attempt-owned subtrees live beside the manifest so later writers resolve
    # them through the same attempt directory.
    mkdir -p "$run_dir/handoffs" "$run_dir/manual-verification" || return 1
  fi

  local log_dir_rel run_dir_rel session_dir_rel tool_results_dir_rel runtime_config_dir_rel artifacts_dir_rel process_run_dir_rel
  log_dir_rel="$(ralph_run_plan_manifest_relative_path "${RALPH_LOG_DIR:-$state_root/logs/$plan_key}")" || return 1
  run_dir_rel="$(ralph_run_plan_manifest_relative_path "$run_dir")" || return 1
  session_dir_rel="$(ralph_run_plan_manifest_relative_path "${RALPH_SESSION_DIR:-$(ralph_state_sessions_dir "$state_root" "$plan_key")}")" || session_dir_rel=""
  tool_results_dir_rel="$(ralph_run_plan_manifest_relative_path "$(ralph_state_shared_dir "$state_root" tool-results)/$plan_key")" || tool_results_dir_rel=""
  runtime_config_dir_rel="$(ralph_run_plan_manifest_relative_path "$(ralph_state_runtime_config_dir "$state_root" "$plan_key")")" || runtime_config_dir_rel=""
  artifacts_dir_rel="$(ralph_run_plan_manifest_relative_path "$state_root/artifacts/${RALPH_ARTIFACT_NS:-$plan_key}")" || artifacts_dir_rel=""
  process_run_dir_rel="$(ralph_run_plan_manifest_relative_path "${RALPH_PROCESS_RUN_DIR:-}")" || process_run_dir_rel=""

  local path rel
  for path in "$RALPH_LOG_DIR/plan-usage-summary.json" "$RALPH_LOG_DIR/invocation-usage.json"; do
    [[ -f "$path" ]] || continue
    rel="$(ralph_run_plan_manifest_relative_path "$path")" || continue
    files="$(jq -c --arg path "$rel" --arg role usage --arg tier plan '. + [{path:$path,role:$role,tier:$tier}]' <<<"$files")"
  done

  tmp="$(mktemp "$run_dir/.run-manifest.XXXXXX")" || return 1
  jq -n \
    --arg run_id "$run_id" --arg plan_key "$plan_key" --arg artifact_ns "${RALPH_ARTIFACT_NS:-$plan_key}" \
    --arg plan_path "${PLAN_PATH:-}" --arg runtime "${RUNTIME:-}" --arg model "${SELECTED_MODEL:-}" \
    --arg ralph_mode "${RALPH_MODE:-}" \
    --arg reasoning_effort "${RALPH_PLAN_REASONING_EFFORT_RESOLVED:-${SELECTED_REASONING_EFFORT:-}}" \
    --arg status "$status" --arg started_at "${_plan_started_at:-}" --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workflow_run_id "${RALPH_WORKFLOW_RUN_ID:-}" --arg graph_run_id "${RALPH_GRAPH_RUN_ID:-}" --arg graph_namespace "${RALPH_GRAPH_NAMESPACE:-}" --arg stage_id "${RALPH_STAGE_ID:-}" \
    --arg log_dir "$log_dir_rel" --arg run_dir "$run_dir_rel" --arg session_dir "$session_dir_rel" --arg tool_results_dir "$tool_results_dir_rel" --arg runtime_config_dir "$runtime_config_dir_rel" --arg artifacts_dir "$artifacts_dir_rel" --arg process_run_dir "$process_run_dir_rel" \
    --argjson iterations "${total_invocations:-0}" --argjson files "$files" \
    '{schema_version:1,kind:"ralph_run_manifest",run_kind:"plan",run_id:$run_id,plan_key:$plan_key,artifact_ns:$artifact_ns,plan_path:$plan_path,runtime:$runtime,model:$model,ralph_mode:$ralph_mode,reasoning_effort:$reasoning_effort,status:$status,started_at:$started_at,ended_at:$ended_at,iterations:$iterations,parent:{workflow_run_id:($workflow_run_id|if .=="" then null else . end),graph_run_id:($graph_run_id|if .=="" then null else . end),graph_namespace:($graph_namespace|if .=="" then null else . end),stage_id:($stage_id|if .=="" then null else . end)},paths:{log_dir:$log_dir,run_dir:$run_dir,session_dir:$session_dir,tool_results_dir:$tool_results_dir,runtime_config_dir:$runtime_config_dir,artifacts_dir:$artifacts_dir,process_run_dir:$process_run_dir},files:$files}' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }

  if [[ "$layout" != 2 ]]; then
    jq -cn --arg run_id "$run_id" --arg path "$run_dir_rel/run-manifest.json" --arg status "$status" '{run_id:$run_id,path:$path,status:$status}' >>"$runs_dir/index.jsonl"
    return 0
  fi

  ralph_state_catalog_record_stage "$state_root" "$owner_run" "$stage_id" "$attempt_id" "$status" || return 1
  # Only a standalone plan run owns its catalog header; a workflow child must
  # not overwrite the outer run's kind, task, or terminal status.
  [[ "$owner_run" == "$run_id" ]] || return 0
  ralph_state_catalog_update "$state_root" "$run_id" \
    '.runKind = "plan"
     | .parent = null
     | .status = $status
     | .artifactNamespace = $artifactNs
     | .task = null
     | .inputs = {planPath: (if $planPath == "" then null else $planPath end), planKey: $planKey}
     | .engine = {kind: "plan", runtime: (if $runtime == "" then null else $runtime end)}
     | .endedAt = (if $status == "running" then null else $endedAt end)' \
    --arg status "$status" \
    --arg artifactNs "${RALPH_ARTIFACT_NS:-$plan_key}" \
    --arg planPath "${PLAN_PATH:-}" \
    --arg planKey "$plan_key" \
    --arg runtime "${RUNTIME:-}" \
    --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
